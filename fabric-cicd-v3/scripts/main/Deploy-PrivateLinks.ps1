#Requires -Version 7.0

<#
.SYNOPSIS
    Deploys Private Link Services (PLS) and Private Endpoints (PE) for Fabric workspaces,
    then applies the inbound network communication policy for each workspace.

.DESCRIPTION
    Phase 1 — PLS/PE (existing):
      For each workspace that has private link configuration defined, builds a
      deployment parameter set and deploys the specified Bicep template via
      New-AzResourceGroupDeployment.

    Phase 2 — Network communication policy (new):
      For each workspace with 'privateLink.denyPublicAccess' configured, reads the
      current network communication policy via the Fabric REST API, then issues a
      PUT to set inbound.publicAccessRules.defaultAction to Deny or Allow.

      The PUT overwrites the entire policy object — the GET is always performed first
      to preserve existing outbound settings. If 'defaultAction' is omitted from any
      section in a PUT body, Fabric silently defaults it to 'Allow', so both inbound
      and outbound are always written explicitly.

      Note: Deny enforcement can take up to 30 minutes to propagate after PUT succeeds.

    Expects an active Azure context — designed to run inside an AzurePowerShell@5
    pipeline task which provides the Az context automatically via service connection.

.PARAMETER ConfigFile
    Path to the environment YAML config file.

.PARAMETER WorkspaceMapFile
    Path to the workspace-map JSON file exported by Deploy-FabricEnvironment.ps1.

.PARAMETER TemplateFile
    Path to the Bicep template for PLS and PE deployment.

.PARAMETER ResourceGroupName
    Azure resource group where PLS/PE resources will be deployed.

.PARAMETER WhatIfMode
    When specified, runs New-AzResourceGroupDeployment with -WhatIf and skips
    the network policy PUT (logs what would be changed instead).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ }, ErrorMessage = "Config path not found: {0}")]
    [string]$ConfigFile,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf }, ErrorMessage = "Workspace map file not found: {0}")]
    [string]$WorkspaceMapFile,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf }, ErrorMessage = "Bicep template not found: {0}")]
    [string]$TemplateFile,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter()]
    [switch]$WhatIfMode,

    # ── Service principal auth ─────────────────────────────────────────────────
    [Parameter(Mandatory, ParameterSetName = 'ServicePrincipal')]
    [ValidateNotNullOrEmpty()]
    [string]$ClientId,

    [Parameter(Mandatory, ParameterSetName = 'ServicePrincipal')]
    [ValidateNotNullOrEmpty()]
    [string]$ClientSecret,

    [Parameter(Mandatory, ParameterSetName = 'ServicePrincipal')]
    [ValidateNotNullOrEmpty()]
    [string]$TenantId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

# ── Verify Azure context (provided by AzurePowerShell@5 task) ──────────────────
$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx) {
    throw "No Azure context found. This script must run inside an AzurePowerShell@5 pipeline task."
}
Write-Host "  Using Az context: $($ctx.Account.Id) (Subscription: $($ctx.Subscription.Id))"

# ── Load helpers & inputs ──────────────────────────────────────────────────────
$helpersRoot = Join-Path $PSScriptRoot '../helpers'

. (Join-Path $helpersRoot 'Read-EnvironmentConfig.ps1')

. (Join-Path $helpersRoot 'Invoke-FabCli.ps1')

$Config = Read-EnvironmentConfig -ConfigPath $ConfigFile
$WorkspaceMap = Get-Content $WorkspaceMapFile -Raw | ConvertFrom-Json -AsHashtable

# ── Validate privateLinks config exists ────────────────────────────────────────
if (-not $Config.PSObject.Properties.Name -contains 'privateLinks') {
    Write-Host "  No 'privateLinks' section in config - skipping."
    return
}
$plConfig = $Config.privateLinks

# ── Build workspace configs array ──────────────────────────────────────────────
$workspaceConfigs = [System.Collections.ArrayList]::new()

foreach ($ws in $Config.workspaces) {
    if (-not ($ws.PSObject.Properties.Name -contains 'privateLink')) {
        Write-Host "  Workspace '$($ws.name)' - no privateLink config, skipping."
        continue
    }
    $pl = $ws.privateLink

    $wsId = $WorkspaceMap[$ws.name]
    if (-not $wsId) {
        Write-Warning "  Workspace '$($ws.name)' has privateLink config but no resolved ID - skipping."
        continue
    }

    $entry = @{
        workspaceId    = $wsId
        plsName        = $pl.plsName
        peResourceName = if ($pl.PSObject.Properties.Name -contains 'peResourceName') { $pl.peResourceName } else { '' }
        peType         = if ($pl.PSObject.Properties.Name -contains 'peType') { $pl.peType } else { 'workspace' }
    }

    Write-Host "  Workspace '$($ws.name)' (ID: $wsId)"
    Write-Host "    PLS Name : $($entry.plsName)"
    if ($entry.peResourceName) {
        Write-Host "    PE  Name : $($entry.peResourceName)"
        Write-Host "    PE  Type : $($entry.peType)"
    }

    [void]$workspaceConfigs.Add($entry)
}

if ($workspaceConfigs.Count -eq 0) {
    Write-Host "  No workspaces with privateLink config found - nothing to deploy."
    return
}

# ── Validate required top-level privateLinks settings ──────────────────────────
$subnetId = if ($plConfig.PSObject.Properties.Name -contains 'subnetId') { $plConfig.subnetId } else { '' }
$privateDnsZoneId = if ($plConfig.PSObject.Properties.Name -contains 'privateDnsZoneId') { $plConfig.privateDnsZoneId } else { '' }

if (-not $subnetId) {
    throw "privateLinks.subnetId is required but not set in config."
}
if (-not $privateDnsZoneId) {
    throw "privateLinks.privateDnsZoneId is required but not set in config."
}

Write-Host "  Resource Group   : $ResourceGroupName"
Write-Host "  Template         : $TemplateFile"
Write-Host "  Subnet ID        : $subnetId"
Write-Host "  DNS Zone ID      : $privateDnsZoneId"
Write-Host "  Workspace(s)     : $($workspaceConfigs.Count)"

# ── Deploy all workspaces in a single deployment ───────────────────────────────
$deploymentName = "fabric-pls-pe-$(Get-Date -Format 'yyyyMMddHHmmss')"
$deploymentParams = @{
    workspaceConfigs = [array]$workspaceConfigs
    subnetId         = $subnetId
    privateDnsZoneId = $privateDnsZoneId
}

# Optional parameters — only pass if explicitly set in config
if ($plConfig.PSObject.Properties.Name -contains 'tenantId' -and $plConfig.tenantId) {
    $deploymentParams['tenantId'] = $plConfig.tenantId
}
if ($plConfig.PSObject.Properties.Name -contains 'location' -and $plConfig.location) {
    $deploymentParams['location'] = $plConfig.location
}

Write-Host "  Deploying PLS + PE for $($workspaceConfigs.Count) workspace(s)..."

if ($WhatIfMode) {
    Write-Host "    [WhatIf] Validating Bicep deployment..."
    New-AzResourceGroupDeployment `
        -Name                    $deploymentName `
        -ResourceGroupName       $ResourceGroupName `
        -TemplateFile            $TemplateFile `
        -TemplateParameterObject $deploymentParams `
        -WhatIf `
        -ErrorAction Stop
    Write-Host "    Deployment validation passed (WhatIf)."
}
else {
    $deployment = New-AzResourceGroupDeployment `
        -Name                    $deploymentName `
        -ResourceGroupName       $ResourceGroupName `
        -TemplateFile            $TemplateFile `
        -TemplateParameterObject $deploymentParams `
        -ErrorAction Stop

    Write-Host "    Deployment completed: $deploymentName"
    if ($deployment.Outputs -and $deployment.Outputs.Count -gt 0) {
        foreach ($key in $deployment.Outputs.Keys) {
            Write-Host "      Output - $key : $($deployment.Outputs[$key].Value)"
        }
    }
}

Write-Host "  Private link deployment complete for $($workspaceConfigs.Count) workspace(s)."

# ══════════════════════════════════════════════════════════════════════════════
# Phase 2 — Workspace network communication policy
# ══════════════════════════════════════════════════════════════════════════════
# API ref: PUT /v1/workspaces/{wsId}/networking/communicationPolicy
# https://learn.microsoft.com/en-us/rest/api/fabric/core/workspaces/set-network-communication-policy
#
# IMPORTANT: PUT overwrites ALL settings. Always GET first and preserve the full
# policy body. Omitting 'defaultAction' from any section silently defaults to 'Allow'.
# Deny enforcement propagates within 30 minutes of a successful PUT.

$wsWithNetworkPolicy = @($Config.workspaces | Where-Object {
        $_.PSObject.Properties.Name -contains 'privateLink' -and
        $null -ne $_.privateLink -and
        $_.privateLink.PSObject.Properties.Name -contains 'denyPublicAccess' -and
        $null -ne $_.privateLink.denyPublicAccess
    })

if ($wsWithNetworkPolicy.Count -eq 0) {
    Write-Host "  No workspaces with denyPublicAccess configured - skipping network policy step."
    return
}

Write-Host ""
Write-Host "  ── Network Communication Policy ($($wsWithNetworkPolicy.Count) workspace(s)) ──────────────"

# ── 1. Authenticate ────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Authenticating to Microsoft Fabric..."

try {
    # Clear any cached auth state from prior pipeline stages to prevent
    # "Client ID already set to...overwriting with..." errors on re-login.
    #Invoke-FabCli -Arguments @('auth', 'logout') -AllowNonZeroExit -MaxRetries 0 #| Out-Null

    # ADO agents lack a keyring/DPAPI backend - enable plaintext token cache fallback
    Invoke-FabCli -Arguments @('config', 'set', 'encryption_fallback_enabled', 'true') -MaxRetries 0 | Out-Null

    $loginArgs = @('auth', 'login', '-u', $ClientId, '-p', $ClientSecret, '--tenant', $TenantId)
    
    Invoke-FabCli -Arguments $loginArgs -MaxRetries 0 #| Out-Null
    Write-Host "  Authentication successful."
}
catch {
    Write-Host "##vso[task.logissue type=error]Fabric CLI authentication failed: $_"
    throw
}
# Acquire a Fabric-scoped token from the existing FAB context.
# The service connection SPN is a workspace Admin (required by this API).
Write-Host "  Acquiring Fabric API token via FAB context..."

Write-Host "  Acquiring Power BI Admin API token..."
$pbiToken = Get-PowerBIAdminToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret

try {
    $fabricToken = $pbiToken
    $fabricHeaders = @{
        Authorization  = "Bearer $fabricToken"
        'Content-Type' = 'application/json'
    }
}
catch {
    throw "Failed to acquire Fabric API token from FAB context: $_"
}

$fabricApiBase = 'https://api.fabric.microsoft.com/v1'

# ── Resolve firewall rules from top-level privateLinks config ──────────────────
# Rules apply to all workspaces with denyPublicAccess: true in this environment.
# Define per-environment in privateLinks.inboundFirewallRules (e.g. Azure Firewall
# egress IP, developer IPs for dev env). Omit in prod if no IP exceptions are needed.
$firewallRules = @()
if ($plConfig.PSObject.Properties.Name -contains 'inboundFirewallRules' -and
    $null -ne $plConfig.inboundFirewallRules -and
    $plConfig.inboundFirewallRules.Count -gt 0) {
    $firewallRules = @($plConfig.inboundFirewallRules | ForEach-Object {
            [ordered]@{
                displayName = $_.displayName
                value       = $_.value
            }
        })
    Write-Host "  Firewall rules loaded: $($firewallRules.Count) rule(s)"
    $firewallRules | ForEach-Object { Write-Host "    $($_.displayName) : $($_.value)" }
}
else {
    Write-Host "  No inboundFirewallRules configured in privateLinks."
}

foreach ($ws in $wsWithNetworkPolicy) {
    $wsName = $ws.name
    $desiredDeny = [bool]$ws.privateLink.denyPublicAccess
    $desiredAction = if ($desiredDeny) { 'Deny' } else { 'Allow' }

    if (-not $WorkspaceMap.ContainsKey($wsName)) {
        Write-Warning "  [$wsName] Not in workspace map - skipping network policy."
        continue
    }

    $wsId = $WorkspaceMap[$wsName]
    $policyUri = "$fabricApiBase/workspaces/$wsId/networking/communicationPolicy"

    Write-Host "  [$wsName] Target inbound public access: $desiredAction"

    # ── GET current policy — required to preserve outbound settings ────────────
    $currentPolicy = $null
    try {
        $currentPolicy = Invoke-RestMethod `
            -Uri         $policyUri `
            -Headers     $fabricHeaders `
            -Method      Get `
            -ErrorAction Stop
    }
    catch {
        $sc = $_.Exception.Response.StatusCode.value__
        if ($sc -eq 404) {
            # No policy set yet — Fabric default is Allow/Allow; proceed to apply from scratch
            Write-Verbose "  [$wsName] No existing policy (HTTP 404). Will write from scratch."
        }
        else {
            throw "Failed to GET network policy for '$wsName' (HTTP $sc): $_"
        }
    }

    Write-Host "Current inbound public policy: $($currentPolicy | ConvertTo-Json -Depth 5 -Compress)"

    # ── Step A: communicationPolicy (inbound defaultAction) ─────────────────────
    # Idempotency: only PUT if the current state differs from desired.
    # This check is intentionally scoped to the policy PUT only — it does NOT
    # short-circuit the firewall rules step below.
    $currentInboundAction = if ($currentPolicy -and
        $currentPolicy.PSObject.Properties.Name -contains 'inbound' -and
        $null -ne $currentPolicy.inbound -and
        $currentPolicy.inbound.PSObject.Properties.Name -contains 'publicAccessRules' -and
        $null -ne $currentPolicy.inbound.publicAccessRules -and
        $currentPolicy.inbound.publicAccessRules.PSObject.Properties.Name -contains 'defaultAction') {
        $currentPolicy.inbound.publicAccessRules.defaultAction
    }
    else { 'Allow' }   # Fabric default when no policy is set

    if ($currentInboundAction -ne $desiredAction) {
        Write-Host "    Policy: $currentInboundAction → $desiredAction"

        if ($WhatIfMode) {
            Write-Host "    [WhatIf] Would PUT inbound.publicAccessRules.defaultAction = '$desiredAction'"
        }
        else {
            # Preserve existing outbound; always write it explicitly — omitting
            # defaultAction silently resets it to 'Allow'.
            $outboundForPut = if ($currentPolicy -and
                $currentPolicy.PSObject.Properties.Name -contains 'outbound' -and
                $null -ne $currentPolicy.outbound) {
                $currentPolicy.outbound
            }
            else {
                [PSCustomObject]@{ publicAccessRules = [PSCustomObject]@{ defaultAction = 'Allow' } }
            }

            $putBody = [ordered]@{
                inbound  = [ordered]@{
                    publicAccessRules = [ordered]@{ defaultAction = $desiredAction }
                }
                outbound = $outboundForPut
            } | ConvertTo-Json -Depth 20 -Compress

            try {
                Invoke-RestMethod `
                    -Method      Put `
                    -Uri         $policyUri `
                    -Headers     $fabricHeaders `
                    -Body        $putBody `
                    -ErrorAction Stop | Out-Null

                Write-Host "    Policy updated: inbound = $desiredAction"
                if ($desiredDeny) {
                    Write-Host "    Note: Deny enforcement propagates within 30 minutes."
                }
            }
            catch {
                throw "Failed to PUT network policy for '$wsName': $_"
            }
        }
    }
    else {
        Write-Host "    Policy: already '$desiredAction'. No changes required."
    }

    # ── Step B: firewall rules ────────────────────────────────────────────────
    # Runs independently of Step A — always applied when denyPublicAccess: true
    # and inboundFirewallRules are configured. This ensures rule changes in config
    # are pushed even when the deny state itself has not changed.
    if ($desiredDeny -and $firewallRules.Count -gt 0) {
        if ($WhatIfMode) {
            Write-Host "    [WhatIf] Would PUT $($firewallRules.Count) firewall rule(s)"
        }
        else {
            $firewallBody = [ordered]@{ rules = $firewallRules } | ConvertTo-Json -Depth 10 -Compress
            try {
                $firewallUri = "$fabricApiBase/workspaces/$wsId/networking/communicationPolicy/inbound/firewall"
                Invoke-RestMethod `
                    -Method      Put `
                    -Uri         $firewallUri `
                    -Headers     $fabricHeaders `
                    -Body        $firewallBody `
                    -ErrorAction Stop | Out-Null

                Write-Host "    Firewall rules updated: $($firewallRules.Count) rule(s)"
            }
            catch {
                throw "Failed to PUT firewall rules for '$wsName': $_"
            }
        }
    }
    elseif ($desiredDeny -and $firewallRules.Count -eq 0) {
        Write-Verbose "    No inboundFirewallRules in config - skipping firewall PUT."
    }
}

Write-Host "  Network policy step complete for $($wsWithNetworkPolicy.Count) workspace(s)."