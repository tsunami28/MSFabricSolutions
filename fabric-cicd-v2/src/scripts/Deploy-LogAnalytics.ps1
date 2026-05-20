#Requires -Version 7.0

<#
.SYNOPSIS
    Connects (or disconnects) Fabric workspaces to the environment's Azure Log
    Analytics Workspace via the Power BI Admin REST API.

.DESCRIPTION
    For each workspace that has 'logAnalytics: true' in the environment config,
    uses the Power BI Admin API to connect the Log Analytics Workspace:
      PATCH /v1.0/myorg/admin/groups/{workspaceId}
      Body: { "logAnalyticsWorkspace": { subscriptionId, resourceGroup, resourceName } }

    For workspaces with 'logAnalytics: false', the connection is removed:
      PATCH /v1.0/myorg/admin/groups/{workspaceId}
      Body: { "logAnalyticsWorkspace": null }

    Workspaces without a 'logAnalytics' property are skipped (no change).

    Safe to re-run — current state is checked before each API call (idempotent).

    Prerequisites:
      - 'fab auth login' must have been called before invoking this script.
      - The service principal must be a Fabric Administrator (tenant-level).
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

    Uses 'fab api -A powerbi' which acquires a Power BI-scoped token using the
    same SPN credentials established by 'fab auth login'.
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
        # If body is a JSON string, parse it
        if ($body -is [string] -and $body.StartsWith('{')) {
            try { $body = $body | ConvertFrom-Json -Depth 20 } catch { }
        }
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

    $adminEndpoint = "admin/groups/$wsId"

    if ($ws.logAnalytics -eq $true) {
        # ── Check current state via Admin API GET ──────────────────────────────
        Write-Host "  [$wsName] Checking current Log Analytics connection..."
        $getResult = Invoke-FabCli -Arguments @(
            'api', '-A', 'powerbi', $adminEndpoint
        ) -JsonOutput -AllowNonZeroExit -MaxRetries 2

        $alreadyConnected = $false
        if ($getResult.ExitCode -eq 0) {
            $resp = Get-FabApiResponse -FabOutput $getResult.Output
            if ($resp.StatusCode -lt 400 -and $resp.Body -and
                $resp.Body.PSObject.Properties.Name -contains 'logAnalyticsWorkspace' -and
                $resp.Body.logAnalyticsWorkspace) {
                $current = $resp.Body.logAnalyticsWorkspace
                $alreadyConnected =
                    $current.resourceName  -eq $lawConfig.workspaceName -and
                    $current.resourceGroup -eq $lawConfig.resourceGroupName -and
                    $current.subscriptionId -eq $lawConfig.subscriptionId
            }
        }

        if ($alreadyConnected) {
            Write-Host "  [$wsName] Already connected to '$($lawConfig.workspaceName)' — skipping."
            $skipped++
            continue
        }

        # ── Connect via Admin API PATCH ────────────────────────────────────────
        # Requires Tenant.ReadWrite.All on Power BI Service API (00000009-...).
        # Field names from HAR: subscriptionId, resourceGroup, resourceName
        $body = @{
            logAnalyticsWorkspace = @{
                subscriptionId = $lawConfig.subscriptionId
                resourceGroup  = $lawConfig.resourceGroupName
                resourceName   = $lawConfig.workspaceName
            }
        } | ConvertTo-Json -Compress -Depth 3

        Write-Host "  [$wsName] Connecting to '$($lawConfig.workspaceName)'..."
        $patchResult = Invoke-FabCli -Arguments @(
            'api', '-A', 'powerbi', '-X', 'patch', $adminEndpoint, '-i', $body
        ) -JsonOutput -MaxRetries 2

        $patchResp = Get-FabApiResponse -FabOutput $patchResult.Output
        if ($patchResp.StatusCode -ge 400) {
            throw ("Power BI Admin API returned HTTP $($patchResp.StatusCode) connecting '$wsName' " +
                "(workspaceId: $wsId) to LAW '$($lawConfig.workspaceName)'. " +
                "Ensure SPN has Tenant.ReadWrite.All on Power BI Service API " +
                "(az ad app permission add --id <SPN> --api 00000009-0000-0000-c000-000000000000 " +
                "--api-permissions 01944dba-21df-426f-bb8c-796488be1e60=Role). " +
                "Response: $($patchResp.Body | ConvertTo-Json -Compress -Depth 5)")
        }

        # ── Verify the connection was actually applied ────────────────────────
        $verifyResult = Invoke-FabCli -Arguments @(
            'api', '-A', 'powerbi', $adminEndpoint
        ) -JsonOutput -AllowNonZeroExit -MaxRetries 2

        $verified = $false
        if ($verifyResult.ExitCode -eq 0) {
            $vResp = Get-FabApiResponse -FabOutput $verifyResult.Output
            if ($vResp.StatusCode -lt 400 -and $vResp.Body -and
                $vResp.Body.PSObject.Properties.Name -contains 'logAnalyticsWorkspace' -and
                $vResp.Body.logAnalyticsWorkspace -and
                $vResp.Body.logAnalyticsWorkspace.resourceName -eq $lawConfig.workspaceName) {
                $verified = $true
            }
        }

        if ($verified) {
            Write-Host "  [$wsName] Verified — Connected → $($lawConfig.workspaceName)"
            $connected++
        } else {
            throw ("PATCH returned success but verification GET shows LAW is NOT connected " +
                "for workspace '$wsName' (workspaceId: $wsId). " +
                "The admin endpoint likely requires Tenant.ReadWrite.All permission. " +
                "Run: az ad app permission add --id <SPN_CLIENT_ID> --api 00000009-0000-0000-c000-000000000000 " +
                "--api-permissions 01944dba-21df-426f-bb8c-796488be1e60=Role && " +
                "az ad app permission admin-consent --id <SPN_CLIENT_ID>")
        }
    }
    elseif ($ws.logAnalytics -eq $false) {
        # ── Check if currently connected ───────────────────────────────────────
        Write-Host "  [$wsName] Checking current Log Analytics connection (to disconnect)..."
        $getResult = Invoke-FabCli -Arguments @(
            'api', '-A', 'powerbi', $adminEndpoint
        ) -JsonOutput -AllowNonZeroExit -MaxRetries 2

        $isConnected = $false
        if ($getResult.ExitCode -eq 0) {
            $resp = Get-FabApiResponse -FabOutput $getResult.Output
            if ($resp.StatusCode -lt 400 -and $resp.Body -and
                $resp.Body.PSObject.Properties.Name -contains 'logAnalyticsWorkspace' -and
                $resp.Body.logAnalyticsWorkspace) {
                $isConnected = $true
            }
        }

        if (-not $isConnected) {
            Write-Host "  [$wsName] Already disconnected — skipping."
            $skipped++
            continue
        }

        # ── Disconnect via Admin API PATCH ─────────────────────────────────────
        $body = '{"logAnalyticsWorkspace":null}'

        Write-Host "  [$wsName] Disconnecting Log Analytics..."
        $patchResult = Invoke-FabCli -Arguments @(
            'api', '-A', 'powerbi', '-X', 'patch', $adminEndpoint, '-i', $body
        ) -JsonOutput -AllowNonZeroExit -MaxRetries 2

        $patchResp = Get-FabApiResponse -FabOutput $patchResult.Output
        if ($patchResp.StatusCode -ge 400) {
            throw ("Power BI Admin API returned HTTP $($patchResp.StatusCode) disconnecting '$wsName'. " +
                "Response: $($patchResp.Body | ConvertTo-Json -Compress -Depth 5)")
        }

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
