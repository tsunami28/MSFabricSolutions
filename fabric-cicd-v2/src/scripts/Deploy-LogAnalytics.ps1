#Requires -Version 7.0

<#
.SYNOPSIS
    Connects (or disconnects) Fabric workspaces to the environment's Azure Log
    Analytics Workspace via the Microsoft Fabric REST API.

.DESCRIPTION
    For each workspace that has 'logAnalytics: true' in the environment config,
    calls the Fabric REST API to assign the environment-level Log Analytics Workspace:
      PUT /v1/workspaces/{id}/azureLogAnalyticsConnections

    For workspaces with 'logAnalytics: false', the connection is removed:
      DELETE /v1/workspaces/{id}/azureLogAnalyticsConnections

    Workspaces without a 'logAnalytics' property are skipped (no change).

    Safe to re-run — current state is checked before each API call (idempotent).

    Prerequisites:
      - 'fab auth login' must have been called before invoking this script.
      - The service principal must be a workspace Admin on each target workspace.
      - The Fabric workspace must be on a Fabric (F SKU) or Power BI Premium capacity.
      - Tenant setting "Azure Log Analytics connections for workspace administrators"
        must be enabled in the Fabric Admin portal.

.PARAMETER Config
    The parsed environment config object (PSCustomObject from Read-EnvironmentConfig).

.PARAMETER WorkspaceMap
    Hashtable mapping workspace name → Fabric workspace ID.
    Produced by Deploy-Workspaces.ps1 and exported by Deploy-FabricEnvironment.ps1.

.NOTES
    Called by Deploy-FabricEnvironment.ps1. Assumes 'fab auth login' has
    already been called in the same shell session.

    The Fabric REST API rate limit is 200 requests/hour on the workspace endpoints.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [PSCustomObject]$Config,

    [Parameter(Mandatory)]
    [hashtable]$WorkspaceMap,

    [Parameter(Mandatory)]
    [ValidateSet('dev', 'tst', 'prd')]
    [string]$Environment
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Dot-source helpers ─────────────────────────────────────────────────────────
$helpersRoot = Join-Path $PSScriptRoot '../helpers'
. (Join-Path $helpersRoot 'Invoke-FabCli.ps1')

# ── Helper: extract actual body + status code from fab api JSON envelope ───────
# fab api --output_format json wraps every response as:
#   { result: { data: [{ status_code: int, text: <actual body> }] } }
function Get-FabApiResponse {
    param([Parameter(Mandatory = $false)] $FabOutput)
    if ($null -eq $FabOutput) { return [PSCustomObject]@{ StatusCode = 0; Body = $null } }

    if ($FabOutput.PSObject.Properties.Name -contains 'result' -and
        $FabOutput.result.PSObject.Properties.Name -contains 'data' -and
        $FabOutput.result.data.Count -gt 0) {
        $entry = $FabOutput.result.data[0]
        $body  = if ($entry.text -is [string] -and $entry.text -eq '(Empty)') { $null } else { $entry.text }
        return [PSCustomObject]@{ StatusCode = [int]$entry.status_code; Body = $body }
    }
    return [PSCustomObject]@{ StatusCode = 0; Body = $FabOutput }
}

# ── Validate logAnalytics environment config ───────────────────────────────────
if (-not ($Config.PSObject.Properties.Name -contains 'logAnalytics') -or
    -not $Config.logAnalytics) {
    Write-Host "  No 'logAnalytics' section in environment config — skipping workspace connections."
    return
}

$lawConfig = $Config.logAnalytics
foreach ($field in @('subscriptionId', 'resourceGroupName', 'workspaceName')) {
    if (-not ($lawConfig.PSObject.Properties.Name -contains $field) -or -not $lawConfig.$field) {
        throw "logAnalytics.$field is required but not set in config."
    }
}

Write-Host "  Target LAW : $($lawConfig.workspaceName) (RG: $($lawConfig.resourceGroupName))"

# ── Process each workspace ─────────────────────────────────────────────────────
$connected    = 0
$disconnected = 0
$skipped      = 0

foreach ($ws in $Config.workspaces) {
    $wsName = $ws.name

    if (-not ($ws.PSObject.Properties.Name -contains 'logAnalytics') -or
        $null -eq $ws.logAnalytics) {
        Write-Host "  [$wsName] logAnalytics not set — skipping."
        $skipped++
        continue
    }

    $wsId = $WorkspaceMap[$wsName]
    if (-not $wsId) {
        Write-Warning "  [$wsName] No workspace ID found in workspace map — skipping."
        $skipped++
        continue
    }

    $endpoint = "workspaces/$wsId/azureLogAnalyticsConnections"

    if ($ws.logAnalytics -eq $true) {
        # ── Check current state ────────────────────────────────────────────────
        Write-Host "  [$wsName] Checking current Log Analytics connection..."
        $getResult = Invoke-FabCli -Arguments @('api', $endpoint) `
            -JsonOutput -AllowNonZeroExit -MaxRetries 2

        $currentConn = $null
        if ($getResult.ExitCode -eq 0) {
            $resp = Get-FabApiResponse -FabOutput $getResult.Output
            if ($resp.StatusCode -ne 404 -and $resp.Body) {
                $currentConn = $resp.Body
            }
        }

        $alreadyConnected = $currentConn -and
            $currentConn.workspaceName     -eq $lawConfig.workspaceName -and
            $currentConn.resourceGroupName -eq $lawConfig.resourceGroupName -and
            $currentConn.subscriptionId    -eq $lawConfig.subscriptionId

        if ($alreadyConnected) {
            Write-Host "  [$wsName] Already connected to '$($lawConfig.workspaceName)' — skipping."
            $skipped++
            continue
        }

        # ── Assign LAW via PUT ─────────────────────────────────────────────────
        $body = @{
            subscriptionId    = $lawConfig.subscriptionId
            resourceGroupName = $lawConfig.resourceGroupName
            workspaceName     = $lawConfig.workspaceName
        } | ConvertTo-Json -Compress

        Write-Host "  [$wsName] Connecting to '$($lawConfig.workspaceName)'..."
        $putResult = Invoke-FabCli -Arguments @('api', '-X', 'put', $endpoint, '-i', $body) `
            -JsonOutput -MaxRetries 2

        $putResp = Get-FabApiResponse -FabOutput $putResult.Output
        if ($putResp.StatusCode -ge 400) {
            throw "Fabric API returned HTTP $($putResp.StatusCode) connecting '$wsName': $($putResp.Body | ConvertTo-Json -Compress)"
        }

        Write-Host "  [$wsName] Connected → $($lawConfig.workspaceName)"
        $connected++
    }
    elseif ($ws.logAnalytics -eq $false) {
        # ── Check current state ────────────────────────────────────────────────
        Write-Host "  [$wsName] Checking current Log Analytics connection (to disconnect)..."
        $getResult = Invoke-FabCli -Arguments @('api', $endpoint) `
            -JsonOutput -AllowNonZeroExit -MaxRetries 2

        $isConnected = $false
        if ($getResult.ExitCode -eq 0) {
            $resp        = Get-FabApiResponse -FabOutput $getResult.Output
            $isConnected = $resp.StatusCode -ne 404 -and $null -ne $resp.Body
        }

        if (-not $isConnected) {
            Write-Host "  [$wsName] Already disconnected — skipping."
            $skipped++
            continue
        }

        # ── Disconnect via DELETE ──────────────────────────────────────────────
        Write-Host "  [$wsName] Disconnecting Log Analytics..."
        Invoke-FabCli -Arguments @('api', '-X', 'delete', $endpoint) -MaxRetries 2 | Out-Null

        Write-Host "  [$wsName] Disconnected."
        $disconnected++
    }
    else {
        Write-Warning "  [$wsName] Unexpected logAnalytics value '$($ws.logAnalytics)' — expected true or false. Skipping."
        $skipped++
    }
}

Write-Host ""
Write-Host "  Log Analytics connections complete:"
Write-Host "    Connected    : $connected"
Write-Host "    Disconnected : $disconnected"
Write-Host "    Skipped      : $skipped"
