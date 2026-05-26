#Requires -Version 7.0

<#
.SYNOPSIS
    Idempotently connects Fabric workspaces to the shared Log Analytics Workspace.

.DESCRIPTION
    For each workspace in the config with 'logAnalytics: true':
      - Retrieves current LAW connection state via Power BI Admin API
      - Connects if not connected or connected to a different LAW
      - Skips if already connected to the correct LAW (idempotent)

    For workspaces with 'logAnalytics: false':
      - Disconnects if currently connected
      - Skips if already disconnected

    For workspaces without a 'logAnalytics' key:
      - No action taken (preserves current state)

    The LAW is pre-deployed in the Landing Zone. This script only manages
    the connection between Fabric workspaces and the existing LAW.

    Uses 'fab api -A powerbi' (Power BI Admin REST API).
    The deploying SPN must have Fabric Administrator role at tenant level.

    Called by Deploy-FabricEnvironment.ps1. Assumes 'fab auth login' has
    already been called in the same shell session.

.PARAMETER Config
    Validated PSCustomObject from Read-EnvironmentConfig.

.PARAMETER WorkspaceMap
    Hashtable of workspace name → workspace GUID produced by Deploy-Workspaces.ps1.

.PARAMETER Environment
    Target environment (dev | tst | prd).
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

$helpersRoot = Join-Path $PSScriptRoot '../helpers'
. (Join-Path $helpersRoot 'Invoke-FabCli.ps1')

# ── Validate top-level logAnalytics block ──────────────────────────────────────
$hasLaw = $Config.PSObject.Properties.Name -contains 'logAnalytics'
if (-not $hasLaw -or $null -eq $Config.logAnalytics) {
    Write-Host "  No 'logAnalytics' block in config - skipping."
    return
}

$lawConfig = $Config.logAnalytics

# Power BI Admin API asymmetry:
#   PATCH body field : resourceGroup      (NOT resourceGroupName)
#   GET response field: resourceGroup     (same — both use resourceGroup)
#
# The field 'resourceGroupName' is what the Fabric REST API uses, but the
# Power BI Admin API (api.powerbi.com) uses 'resourceGroup' for both read and write.
$desiredLaw = [ordered]@{
    subscriptionId = $lawConfig.subscriptionId
    resourceGroup  = $lawConfig.resourceGroupName   # config uses resourceGroupName; API uses resourceGroup
    resourceName   = $lawConfig.workspaceName
}

Write-Host "  Shared LAW  : $($desiredLaw.resourceGroup)/$($desiredLaw.resourceName)"
Write-Host "  Subscription: $($desiredLaw.subscriptionId)"

# ── Helper: unwrap the fab api JSON envelope ───────────────────────────────────
# fab api responses can be wrapped or unwrapped depending on fab version:
#   Wrapped:   { timestamp, status, command, result: { data: [ { status_code, text: <payload> } ] } }
#   Unwrapped: { status_code, text: <payload> }
# This helper handles both formats.
function Get-FabApiResponseText {
    param($FabOutput)

    if ($null -eq $FabOutput) { return $null }

    # ── Try unwrapped format first (newer fab versions) ────────────────────────
    if ($FabOutput.PSObject.Properties.Name -contains 'status_code') {
        $statusCode = $FabOutput.status_code

        if ($statusCode -eq 401) {
            throw "Power BI Admin API returned 401 Unauthorized. " +
            "The SPN requires Fabric Administrator role (tenant-level) and " +
            "Tenant.ReadWrite.All application permission (admin-consented) in Entra ID."
        }

        if ($statusCode -eq 403) {
            throw "Power BI Admin API returned 403 Forbidden. " +
            "Verify the tenant setting 'Azure Log Analytics connections for workspace administrators' " +
            "is enabled and the SPN is in the allowed security group."
        }

        if ($statusCode -notin @(200, 204)) {
            throw "Power BI Admin API returned unexpected status $statusCode. Response: $($FabOutput.text | ConvertTo-Json -Compress -Depth 5 -ErrorAction SilentlyContinue)"
        }

        $text = $FabOutput.text
        if ($text -is [string] -and $text -eq '(Empty)') { return $null }
        return $text
    }

    # ── Try wrapped format (older fab versions) ────────────────────────────────
    if ($FabOutput.PSObject.Properties.Name -contains 'result' -and
        $null -ne $FabOutput.result -and
        $FabOutput.result.PSObject.Properties.Name -contains 'data' -and
        $FabOutput.result.data.Count -gt 0) {

        $entry = $FabOutput.result.data[0]

        if ($entry.PSObject.Properties.Name -contains 'status_code') {
            $statusCode = $entry.status_code

            if ($statusCode -eq 401) {
                throw "Power BI Admin API returned 401 Unauthorized. " +
                "The SPN requires Fabric Administrator role (tenant-level) and " +
                "Tenant.ReadWrite.All application permission (admin-consented) in Entra ID."
            }

            if ($statusCode -eq 403) {
                throw "Power BI Admin API returned 403 Forbidden. " +
                "Verify the tenant setting 'Azure Log Analytics connections for workspace administrators' " +
                "is enabled and the SPN is in the allowed security group."
            }

            if ($statusCode -notin @(200, 204)) {
                throw "Power BI Admin API returned unexpected status $statusCode. Response: $($entry.text | ConvertTo-Json -Compress -Depth 5 -ErrorAction SilentlyContinue)"
            }
        }

        $text = $entry.text
        if ($text -is [string] -and $text -eq '(Empty)') { return $null }
        return $text
    }

    return $FabOutput
}

# ── Helper: extract logAnalyticsWorkspace from unwrapped API response ──────────
function Get-LawDetails {
    param($FabOutput)

    $payload = Get-FabApiResponseText -FabOutput $FabOutput
    if ($null -eq $payload) { return $null }
    if ($payload.PSObject.Properties.Name -notcontains 'logAnalyticsWorkspace') { return $null }
    return $payload.logAnalyticsWorkspace   # may itself be $null
}

# ── Helper: compare current LAW state against desired ─────────────────────────
# GET response field: resourceGroup (not resourceGroupName)
function Test-LawMatches {
    param($Current, $Desired)

    if ($null -eq $Current) { return $false }
    if ($null -eq $Desired) { return $false }

    $props = $Current.PSObject.Properties.Name

    $subMatch = ($props -contains 'subscriptionId') -and ($Current.subscriptionId -eq $Desired.subscriptionId)
    $rgMatch = ($props -contains 'resourceGroup') -and ($Current.resourceGroup -eq $Desired.resourceGroup)
    $nameMatch = ($props -contains 'resourceName') -and ($Current.resourceName -eq $Desired.resourceName)

    return ($subMatch -and $rgMatch -and $nameMatch)
}

# ── Process each workspace ─────────────────────────────────────────────────────
$processedCount = 0
$skippedCount = 0

foreach ($workspaceConfig in $Config.workspaces) {
    $wsName = $workspaceConfig.name

    $hasWsLaw = $workspaceConfig.PSObject.Properties.Name -contains 'logAnalytics'
    if (-not $hasWsLaw) {
        Write-Verbose "  [$wsName] No logAnalytics setting - skipping (current state preserved)."
        $skippedCount++
        continue
    }

    $wsLawSetting = $workspaceConfig.logAnalytics   # $true | $false

    if (-not $WorkspaceMap.ContainsKey($wsName)) {
        Write-Warning "  [$wsName] Not in workspace map - skipping Log Analytics step."
        continue
    }

    $wsId = $WorkspaceMap[$wsName]
    Write-Host ""
    Write-Host "  [$wsName] (ID: $wsId) logAnalytics=$wsLawSetting"

    # ── GET current state ──────────────────────────────────────────────────────
    $currentLaw = $null
    try {
        $getResult = Invoke-FabCli -Arguments @(
            'api', '-A', 'powerbi', "admin/groups/$wsId"
        ) -MaxRetries 2 -JsonOutput

        $currentLaw = Get-LawDetails -FabOutput $getResult.Output

        if ($null -ne $currentLaw) {
            Write-Host "    Current LAW resourceGroup : $($currentLaw.resourceGroup)"
            Write-Host "    Current LAW resourceName  : $($currentLaw.resourceName)"
        }
        else {
            Write-Host "    Current LAW : (none)"
        }
    }
    catch {
        Write-Warning "  [$wsName] Failed to retrieve current LAW state: $_"
        continue
    }

    # ── Disconnect ─────────────────────────────────────────────────────────────
    if ($wsLawSetting -eq $false) {
        if ($null -eq $currentLaw) {
            Write-Host "    Already disconnected. No action required."
            $processedCount++
            continue
        }

        Write-Host "    Disconnecting from LAW: $($currentLaw.resourceName)..."
        $disconnectBody = '{"logAnalyticsWorkspace":null}'

        Invoke-FabCli -Arguments @(
            'api', '-X', 'patch', '-A', 'powerbi',
            "admin/groups/$wsId",
            '-i', "'$disconnectBody'"
        ) -MaxRetries 2 | Out-Null

        Write-Host "    Disconnected."
        $processedCount++
        continue
    }

    # ── Connect / idempotency check ────────────────────────────────────────────
    if (Test-LawMatches -Current $currentLaw -Desired $desiredLaw) {
        Write-Host "    Already connected to correct LAW. No action required."
        $processedCount++
        continue
    }

    if ($null -ne $currentLaw) {
        Write-Host "    Updating LAW connection: $($currentLaw.resourceName) → $($desiredLaw.resourceName)"
    }
    else {
        Write-Host "    Connecting to LAW: $($desiredLaw.resourceName)..."
    }

    # PATCH body uses resourceGroup — matching the Power BI Admin API field name
    $connectBody = @{ logAnalyticsWorkspace = $desiredLaw } | ConvertTo-Json -Compress -Depth 5
    Write-Host "    PATCH body: $connectBody"

    try {
        $patchResult = Invoke-FabCli -Arguments @(
            'api', '-X', 'patch', '-A', 'powerbi',
            "admin/groups/$wsId",
            '-i', "'$connectBody'"
        ) -MaxRetries 0 -JsonOutput

        # This throws on 401/403/non-200 — no silent continuation
        $patchPayload = Get-FabApiResponseText -FabOutput $patchResult.Output
        Write-Host "    PATCH accepted (status 200/204)."
        Write-Host "    PATCH response payload: $($patchPayload | ConvertTo-Json -Depth 5 -Compress -ErrorAction SilentlyContinue)"

        # ── Verify the connection was actually applied ──────────────────────────
        Write-Host "    Verifying state (waiting 5s for API consistency)..."
        Start-Sleep -Seconds 5

        $verifyResult = Invoke-FabCli -Arguments @(
            'api', '-A', 'powerbi', "admin/groups/$wsId"
        ) -MaxRetries 2 -JsonOutput

        $verifiedLaw = Get-LawDetails -FabOutput $verifyResult.Output

        if (Test-LawMatches -Current $verifiedLaw -Desired $desiredLaw) {
            Write-Host "    Verified: $wsName → $($desiredLaw.resourceName)"
        }
        else {
            $actual = if ($null -ne $verifiedLaw) {
                "resourceName=$($verifiedLaw.resourceName), resourceGroup=$($verifiedLaw.resourceGroup)"
            }
            else { '(none)' }

            Write-Host "##vso[task.logissue type=warning]LAW connection not confirmed for '$wsName' after PATCH."
            Write-Host "    Expected : resourceName=$($desiredLaw.resourceName), resourceGroup=$($desiredLaw.resourceGroup)"
            Write-Host "    Actual   : $actual"
            Write-Host "    Possible causes:"
            Write-Host "      - SPN is not Fabric Administrator (tenant-level, not workspace Admin)"
            Write-Host "      - Workspace is not on Fabric (F SKU) or Premium (P/A4+) capacity"
            Write-Host "      - Tenant setting 'Azure Log Analytics connections for workspace administrators' is disabled"
            Write-Host "      - microsoft.insights provider not registered in subscription: $($desiredLaw.subscriptionId)"
        }
    }
    catch {
        Write-Host "##vso[task.logissue type=error]Failed to connect LAW for workspace '$wsName': $_"
        throw
    }

    $processedCount++
}

Write-Host ""
Write-Host "  Log Analytics complete. Processed: $processedCount, Skipped (no setting): $skippedCount"