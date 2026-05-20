#Requires -Version 7.0

<#
.SYNOPSIS
    Connects (or disconnects) Fabric workspaces to the environment's Azure Log
    Analytics Workspace via the Power BI REST API (myorg/resources + resourceLinks).

.DESCRIPTION
    For each workspace that has 'logAnalytics: true' in the environment config,
    uses the 2-step Power BI API flow to connect the Log Analytics Workspace:
      1. POST /v1.0/myorg/resources?resourceType=LogAnalytics  (register LAW)
      2. POST /v1.0/myorg/resourceLinks?resourceType=LogAnalytics (link to workspace)

    For workspaces with 'logAnalytics: false', the link is removed via:
      DELETE /v1.0/myorg/resourceLinks/{linkId}?resourceType=LogAnalytics

    Workspaces without a 'logAnalytics' property are skipped (no change).

    Safe to re-run — existing links are checked before each API call (idempotent).

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

    API flow validated against HAR capture of the Fabric portal (app.fabric.microsoft.com).
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
foreach ($field in @('tenantId', 'subscriptionId', 'resourceGroupName', 'workspaceName')) {
    if (-not ($lawConfig.PSObject.Properties.Name -contains $field) -or -not $lawConfig.$field) {
        throw "logAnalytics.$field is required but not set in config."
    }
}

Write-Host "  Target LAW : $($lawConfig.workspaceName) (RG: $($lawConfig.resourceGroupName))"

# ── Step 1: Register the LAW resource at org level ─────────────────────────────
# POST /v1.0/myorg/resources?resourceType=LogAnalytics
# This is idempotent — returns the existing resource if already registered.
$registerBody = @{
    azureTenantObjectId = $lawConfig.tenantId
    isCertified         = $false
    region              = 'N/A'
    resourceGroup       = $lawConfig.resourceGroupName
    subscriptionId      = $lawConfig.subscriptionId
    resourceName        = $lawConfig.workspaceName
} | ConvertTo-Json -Compress

Write-Host "  Registering LAW resource '$($lawConfig.workspaceName)' in Power BI..."
$registerResult = Invoke-FabCli -Arguments @(
    'api', '-A', 'powerbi', '-X', 'post',
    'resources?resourceType=LogAnalytics',
    '-i', $registerBody
) -JsonOutput -MaxRetries 2

$registerResp = Get-FabApiResponse -FabOutput $registerResult.Output
if ($registerResp.StatusCode -ge 400) {
    throw ("Failed to register LAW resource '$($lawConfig.workspaceName)'. " +
        "HTTP $($registerResp.StatusCode). Response: $($registerResp.Body | ConvertTo-Json -Compress -Depth 5)")
}

# Extract the resource object ID returned by the registration
$resourceObjectId = $registerResp.Body.id
if (-not $resourceObjectId) {
    throw ("LAW resource registration succeeded but no 'id' in response. " +
        "Response: $($registerResp.Body | ConvertTo-Json -Compress -Depth 5)")
}
Write-Host "  LAW resource registered. Resource ID: $resourceObjectId"

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

    if ($ws.logAnalytics -eq $true) {
        # ── Link LAW to workspace ──────────────────────────────────────────────
        # POST /v1.0/myorg/resourceLinks?resourceType=LogAnalytics
        $linkBody = @{
            resourceObjectId = $resourceObjectId
            folderObjectId   = $wsId
        } | ConvertTo-Json -Compress

        Write-Host "  [$wsName] Linking LAW '$($lawConfig.workspaceName)' to workspace..."
        $linkResult = Invoke-FabCli -Arguments @(
            'api', '-A', 'powerbi', '-X', 'post',
            'resourceLinks?resourceType=LogAnalytics',
            '-i', $linkBody
        ) -JsonOutput -AllowNonZeroExit -MaxRetries 2

        $linkResp = Get-FabApiResponse -FabOutput $linkResult.Output

        if ($linkResp.StatusCode -eq 201 -or $linkResp.StatusCode -eq 200) {
            Write-Host "  [$wsName] Connected → $($lawConfig.workspaceName)"
            $connected++
        }
        elseif ($linkResp.StatusCode -eq 409) {
            # 409 Conflict = already linked
            Write-Host "  [$wsName] Already connected to LAW — skipping."
            $skipped++
        }
        else {
            throw ("Failed to link LAW to workspace '$wsName' (workspaceId: $wsId). " +
                "HTTP $($linkResp.StatusCode). Response: $($linkResp.Body | ConvertTo-Json -Compress -Depth 5)")
        }
    }
    elseif ($ws.logAnalytics -eq $false) {
        # ── Unlink LAW from workspace ──────────────────────────────────────────
        # DELETE /v1.0/myorg/resourceLinks/{linkId}?resourceType=LogAnalytics
        # First we need to find the link ID for this workspace.
        Write-Host "  [$wsName] Checking for existing LAW link to disconnect..."

        # Query resource links for this workspace (folderObjectId)
        $getLinksResult = Invoke-FabCli -Arguments @(
            'api', '-A', 'powerbi',
            "resourceLinks?resourceType=LogAnalytics&folderObjectId=$wsId"
        ) -JsonOutput -AllowNonZeroExit -MaxRetries 2

        $linksResp = Get-FabApiResponse -FabOutput $getLinksResult.Output
        $linkId = $null

        if ($linksResp.StatusCode -lt 400 -and $linksResp.Body) {
            # Response may be a single link or an array
            $links = if ($linksResp.Body -is [array]) { $linksResp.Body } else { @($linksResp.Body) }
            $matchingLink = $links | Where-Object { $_.folderObjectId -eq $wsId } | Select-Object -First 1
            if ($matchingLink) { $linkId = $matchingLink.id }
        }

        if (-not $linkId) {
            Write-Host "  [$wsName] No LAW link found — already disconnected."
            $skipped++
            continue
        }

        # Delete the link
        Write-Host "  [$wsName] Removing LAW link (linkId: $linkId)..."
        $deleteResult = Invoke-FabCli -Arguments @(
            'api', '-A', 'powerbi', '-X', 'delete',
            "resourceLinks/$($linkId)?resourceType=LogAnalytics"
        ) -JsonOutput -AllowNonZeroExit -MaxRetries 2

        $deleteResp = Get-FabApiResponse -FabOutput $deleteResult.Output
        if ($deleteResp.StatusCode -ge 400 -and $deleteResp.StatusCode -ne 404) {
            throw ("Failed to remove LAW link from workspace '$wsName'. " +
                "HTTP $($deleteResp.StatusCode). Response: $($deleteResp.Body | ConvertTo-Json -Compress -Depth 5)")
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
