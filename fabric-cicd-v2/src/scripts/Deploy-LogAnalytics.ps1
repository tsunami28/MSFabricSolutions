#Requires -Version 7.0

<#
.SYNOPSIS
    Connects (or disconnects) Fabric workspaces to the environment's Azure Log
    Analytics Workspace via the Power BI Admin REST API.

.DESCRIPTION
    For each workspace that has 'logAnalytics: true' in the environment config,
    this script calls the Power BI Admin API (PATCH /admin/groups/{id}) to assign
    the environment-level Log Analytics Workspace.

    For workspaces with 'logAnalytics: false', the LAW connection is removed.
    Workspaces without a 'logAnalytics' property are skipped (no change).

    Safe to re-run — current state is checked before each API call to avoid
    redundant requests (idempotent).

    Prerequisites:
      - The caller must have authenticated with 'fab auth login' (Fabric admin).
      - The Log Analytics Workspace must already exist in Azure (see
        Deploy-LogAnalyticsInfra.ps1).
      - The Fabric/Power BI tenant setting
        "Azure Log Analytics connections for workspace administrators" must be enabled.
      - The service principal must have the Fabric Administrator role (tenant-level)
        to call PATCH /admin/groups/{id}.

.PARAMETER Config
    The parsed environment config object (PSCustomObject from Read-EnvironmentConfig).

.PARAMETER WorkspaceMap
    Hashtable mapping workspace name → Fabric workspace ID.
    Produced by Deploy-Workspaces.ps1 and exported by Deploy-FabricEnvironment.ps1.

.NOTES
    Dot-sourced helpers (Invoke-FabCli) must already be loaded by the caller.
    The Power BI Admin API rate limit is 200 requests/hour; with many workspaces,
    consider adding a delay or batching strategy.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [PSCustomObject]$Config,

    [Parameter(Mandatory)]
    [hashtable]$WorkspaceMap
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Validate logAnalytics environment config ───────────────────────────────────
if (-not ($Config.PSObject.Properties.Name -contains 'logAnalytics') -or
    -not $Config.logAnalytics) {
    Write-Host "  No 'logAnalytics' section in environment config — skipping workspace connections."
    return
}

$lawConfig = $Config.logAnalytics
$requiredFields = @('subscriptionId', 'resourceGroupName', 'workspaceName')
foreach ($field in $requiredFields) {
    if (-not ($lawConfig.PSObject.Properties.Name -contains $field) -or
        -not $lawConfig.$field) {
        throw "logAnalytics.$field is required but not set in config."
    }
}

$desiredLaw = @{
    subscriptionId = $lawConfig.subscriptionId
    resourceGroup  = $lawConfig.resourceGroupName
    resourceName   = $lawConfig.workspaceName
}

Write-Host "  Target LAW : $($desiredLaw.resourceName) (RG: $($desiredLaw.resourceGroup))"

# ── Process each workspace ─────────────────────────────────────────────────────
$connected    = 0
$disconnected = 0
$skipped      = 0

foreach ($ws in $Config.workspaces) {
    $wsName = $ws.name

    # Skip workspaces without a logAnalytics property
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

    if ($ws.logAnalytics -eq $true) {
        # ── Check current state ────────────────────────────────────────────────
        Write-Host "  [$wsName] Checking current Log Analytics connection..."
        try {
            $currentResult = Invoke-FabCli -Arguments @(
                'api', '-A', 'powerbi',
                "admin/groups/$wsId"
            ) -JsonOutput -MaxRetries 2

            $currentLaw = if ($currentResult.Output -and
                              $currentResult.Output.PSObject.Properties.Name -contains 'logAnalyticsWorkspace' -and
                              $currentResult.Output.logAnalyticsWorkspace) {
                $currentResult.Output.logAnalyticsWorkspace
            } else {
                $null
            }

            $alreadyConnected = $currentLaw -and
                $currentLaw.resourceName   -eq $desiredLaw.resourceName -and
                $currentLaw.resourceGroup  -eq $desiredLaw.resourceGroup -and
                $currentLaw.subscriptionId -eq $desiredLaw.subscriptionId

            if ($alreadyConnected) {
                Write-Host "  [$wsName] Already connected to '$($desiredLaw.resourceName)' — skipping."
                $skipped++
                continue
            }
        }
        catch {
            Write-Warning "  [$wsName] Failed to read current LAW state: $_. Proceeding with assignment."
        }

        # ── Assign LAW ─────────────────────────────────────────────────────────
        $body = @{
            logAnalyticsWorkspace = $desiredLaw
        } | ConvertTo-Json -Compress -Depth 5

        Write-Host "  [$wsName] Connecting to '$($desiredLaw.resourceName)'..."
        Invoke-FabCli -Arguments @(
            'api', '-X', 'patch', '-A', 'powerbi',
            "admin/groups/$wsId",
            '-i', $body
        ) -MaxRetries 2 | Out-Null

        Write-Host "  [$wsName] Connected → $($desiredLaw.resourceName)"
        $connected++
    }
    elseif ($ws.logAnalytics -eq $false) {
        # ── Check current state ────────────────────────────────────────────────
        Write-Host "  [$wsName] Checking current Log Analytics connection (to disconnect)..."
        try {
            $currentResult = Invoke-FabCli -Arguments @(
                'api', '-A', 'powerbi',
                "admin/groups/$wsId"
            ) -JsonOutput -MaxRetries 2

            $currentLaw = if ($currentResult.Output -and
                              $currentResult.Output.PSObject.Properties.Name -contains 'logAnalyticsWorkspace' -and
                              $currentResult.Output.logAnalyticsWorkspace) {
                $currentResult.Output.logAnalyticsWorkspace
            } else {
                $null
            }

            if (-not $currentLaw) {
                Write-Host "  [$wsName] Already disconnected — skipping."
                $skipped++
                continue
            }
        }
        catch {
            Write-Warning "  [$wsName] Failed to read current LAW state: $_. Proceeding with disconnection."
        }

        # ── Disconnect LAW ─────────────────────────────────────────────────────
        Write-Host "  [$wsName] Disconnecting Log Analytics..."
        Invoke-FabCli -Arguments @(
            'api', '-X', 'patch', '-A', 'powerbi',
            "admin/groups/$wsId",
            '-i', '{"logAnalyticsWorkspace":null}'
        ) -MaxRetries 2 | Out-Null

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
