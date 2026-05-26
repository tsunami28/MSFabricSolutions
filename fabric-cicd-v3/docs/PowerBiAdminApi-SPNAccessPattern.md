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

    Uses the Power BI Admin REST API directly via Invoke-RestMethod.
    The deploying SPN must have Fabric Administrator role at tenant level
    and be in the security group allowed by the 'Service principals can
    access read-only/write admin APIs' tenant settings.

    Called by Deploy-FabricEnvironment.ps1.

.PARAMETER Config
    Validated PSCustomObject from Read-EnvironmentConfig.

.PARAMETER WorkspaceMap
    Hashtable of workspace name → workspace GUID produced by Deploy-Workspaces.ps1.

.PARAMETER Environment
    Target environment (dev | tst | prd).

.PARAMETER ClientId
    SPN application (client) ID. Passed through from Deploy-FabricEnvironment.ps1.

.PARAMETER ClientSecret
    SPN client secret. Passed through from Deploy-FabricEnvironment.ps1.

.PARAMETER TenantId
    Entra ID tenant ID. Passed through from Deploy-FabricEnvironment.ps1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [PSCustomObject]$Config,

    [Parameter(Mandatory)]
    [hashtable]$WorkspaceMap,

    [Parameter(Mandatory)]
    [ValidateSet('dev', 'tst', 'prd')]
    [string]$Environment,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ClientId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ClientSecret,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TenantId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$helpersRoot = Join-Path $PSScriptRoot '../helpers'
. (Join-Path $helpersRoot 'Invoke-FabCli.ps1')

# ── Acquire SPN token for Power BI Admin API ──────────────────────────────────
# api.powerbi.com does not correctly route SPN requests to the regional backend.
# We acquire a token directly and resolve the tenant's regional endpoint via a
# user-agent-agnostic discovery call, then use that endpoint for all admin calls.
function Get-PowerBIAdminToken {
    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret
    )

    $response = Invoke-RestMethod -Method Post `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -Body @{
            grant_type    = 'client_credentials'
            client_id     = $ClientId
            client_secret = $ClientSecret
            scope         = 'https://analysis.windows.net/powerbi/api/.default'
        }

    return $response.access_token
}

function Get-PowerBIRegionalBaseUrl {
    param([string]$BearerToken)

    # Hit the global endpoint with a minimal call; extract regional host from odata.context
    try {
        $result = Invoke-RestMethod `
            -Uri 'https://api.powerbi.com/v1.0/myorg/admin/groups?$top=1' `
            -Headers @{ Authorization = "Bearer $BearerToken" }

        $uri = [uri]$result.'@odata.context'
        return "https://$($uri.Host)/v1.0/myorg"
    }
    catch {
        # Fall back to known West Europe regional endpoint if discovery fails
        Write-Warning "  Regional endpoint discovery failed, using West Europe fallback: $_"
        return 'https://wabi-west-europe-g-primary-redirect.analysis.windows.net/v1.0/myorg'
    }
}

# Credentials are passed directly from the orchestrator — no env var or config lookup needed.
Write-Host "  Acquiring Power BI Admin API token..."
$pbiToken = Get-PowerBIAdminToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret

Write-Host "  Resolving regional Power BI endpoint..."
$pbiBaseUrl = Get-PowerBIRegionalBaseUrl -BearerToken $pbiToken
Write-Host "  Regional endpoint: $pbiBaseUrl"

$pbiHeaders = @{ Authorization = "Bearer $pbiToken" }

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
            $rawBody = $entry.text | ConvertTo-Json -Compress -Depth 5 -ErrorAction SilentlyContinue
            throw "Power BI Admin API returned 401 Unauthorized. API response body: $rawBody. " +
            "The SPN requires Fabric Administrator role (tenant-level) and " +
            "Tenant.ReadWrite.All application permission (admin-consented) in Entra ID."
        }

        if ($statusCode -eq 403) {
            $rawBody = $entry.text | ConvertTo-Json -Compress -Depth 5 -ErrorAction SilentlyContinue
            throw "Power BI Admin API returned 403 Forbidden. API response body: $rawBody. " +
            "Verify the tenant setting 'Azure Log Analytics connections for workspace administrators' " +
            "is enabled and the SPN is in the allowed security group."
        }

        if ($statusCode -notin @(200, 204)) {
            $rawBody = $entry.text | ConvertTo-Json -Compress -Depth 5 -ErrorAction SilentlyContinue
            throw "Power BI Admin API returned unexpected status $statusCode. API response body: $rawBody"
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
        $getResult = Invoke-RestMethod `
            -Uri "$pbiBaseUrl/admin/groups/$wsId" `
            -Headers $pbiHeaders

        $currentLaw = if ($getResult.PSObject.Properties.Name -contains 'logAnalyticsWorkspace') {
            $getResult.logAnalyticsWorkspace
        } else { $null }

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

        Invoke-RestMethod `
            -Method Patch `
            -Uri "$pbiBaseUrl/admin/groups/$wsId" `
            -Headers $pbiHeaders `
            -ContentType 'application/json' `
            -Body $disconnectBody | Out-Null

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

    $connectBody = @{ logAnalyticsWorkspace = $desiredLaw } | ConvertTo-Json -Compress -Depth 5
    Write-Host "    PATCH body: $connectBody"

    $patchResult = $null   # declare before try so catch can always reference it
    try {
        $patchResult = Invoke-RestMethod `
            -Method Patch `
            -Uri "$pbiBaseUrl/admin/groups/$wsId" `
            -Headers $pbiHeaders `
            -ContentType 'application/json' `
            -Body $connectBody

        Write-Host "    PATCH accepted."
        Write-Host "    PATCH response payload: $($patchResult | ConvertTo-Json -Depth 5 -Compress -ErrorAction SilentlyContinue)"

        # ── Verify the connection was actually applied ──────────────────────────
        Write-Host "    Verifying state (waiting 5s for API consistency)..."
        Start-Sleep -Seconds 5

        $verifyResult = Invoke-RestMethod `
            -Uri "$pbiBaseUrl/admin/groups/$wsId" `
            -Headers $pbiHeaders

        $verifiedLaw = if ($verifyResult.PSObject.Properties.Name -contains 'logAnalyticsWorkspace') {
            $verifyResult.logAnalyticsWorkspace
        } else { $null }

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
        }
    }
    catch {
        $rawOut = if ($null -ne $patchResult) {
            $patchResult | ConvertTo-Json -Depth 10 -Compress -ErrorAction SilentlyContinue
        } else { '(patchResult not set — Invoke-RestMethod threw before assignment)' }

        Write-Host "##[error]Failed to connect LAW for workspace '$wsName'."
        Write-Host "    Error   : $_"
        Write-Host "    Raw out : $rawOut"
        throw
    }

    $processedCount++
}

Write-Host ""
Write-Host "  Log Analytics complete. Processed: $processedCount, Skipped (no setting): $skippedCount"