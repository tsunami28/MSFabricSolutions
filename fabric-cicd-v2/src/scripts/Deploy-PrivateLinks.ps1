#Requires -Version 7.0

<#
.SYNOPSIS
    Deploys Private Link Services (PLS) and Private Endpoints (PE) for Fabric workspaces.

.DESCRIPTION
    For each workspace that has private link configuration defined, builds a
    deployment parameter set and deploys the specified Bicep template via
    New-AzResourceGroupDeployment.

    Requires an active Azure context (Connect-AzAccount / Az PowerShell module).

    Called by Deploy-FabricEnvironment.ps1. Not a standalone script.

.PARAMETER Config
    The parsed environment config PSCustomObject (from Read-EnvironmentConfig).

.PARAMETER WorkspaceMap
    Hashtable of workspace name → workspace GUID (from Deploy-Workspaces.ps1).

.PARAMETER TemplateFile
    Path to the Bicep template for PLS and PE deployment.

.PARAMETER ResourceGroupName
    Azure resource group where PLS/PE resources will be deployed.

.PARAMETER ClientId
    Entra application (client) ID for Connect-AzAccount (service principal auth).

.PARAMETER ClientSecret
    Client secret for service principal authentication.

.PARAMETER TenantId
    Azure AD Tenant ID.

.PARAMETER UseManagedIdentity
    Authenticate using the managed identity of the build agent.

.PARAMETER ManagedIdentityClientId
    Client ID for user-assigned managed identity. Omit for system-assigned.

.PARAMETER WhatIfMode
    When specified, runs New-AzResourceGroupDeployment with -WhatIf.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [PSCustomObject]$Config,

    [Parameter(Mandatory)]
    [hashtable]$WorkspaceMap,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf }, ErrorMessage = "Bicep template not found: {0}")]
    [string]$TemplateFile,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    # ── Azure auth (pass-through from orchestrator) ────────────────────────────
    [Parameter()]
    [string]$ClientId = '',

    [Parameter()]
    [string]$ClientSecret = '',

    [Parameter()]
    [string]$TenantId = '',

    [Parameter()]
    [switch]$UseManagedIdentity,

    [Parameter()]
    [string]$ManagedIdentityClientId = '',

    [Parameter()]
    [switch]$WhatIfMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Connect to Azure ───────────────────────────────────────────────────────────
Write-Host "  Connecting to Azure (Connect-AzAccount)..."
try {
    if ($UseManagedIdentity) {
        $connectArgs = @{ Identity = $true }
        if ($ManagedIdentityClientId) {
            $connectArgs['AccountId'] = $ManagedIdentityClientId
        }
        Connect-AzAccount @connectArgs | Out-Null
    } elseif ($ClientId -and $ClientSecret -and $TenantId) {
        $secSecret = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
        $credential = [System.Management.Automation.PSCredential]::new($ClientId, $secSecret)
        Connect-AzAccount -ServicePrincipal -Credential $credential -Tenant $TenantId | Out-Null
    } else {
        # Assume an existing Az context is already available (e.g. AzurePowerShell task)
        $ctx = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $ctx) {
            throw "No Azure context found. Provide -ClientId/-ClientSecret/-TenantId or -UseManagedIdentity."
        }
        Write-Host "  Using existing Az context: $($ctx.Account.Id)"
    }
    Write-Host "  Azure connection established."
} catch {
    Write-Host "##vso[task.logissue type=error]Connect-AzAccount failed: $_"
    throw
}

# ── Validate privateLinks config exists ────────────────────────────────────────
if (-not $Config.PSObject.Properties.Name -contains 'privateLinks') {
    Write-Host "  No 'privateLinks' section in config — skipping."
    return
}
$plConfig = $Config.privateLinks

# ── Build workspace configs array ──────────────────────────────────────────────
$workspaceConfigs = [System.Collections.ArrayList]::new()

foreach ($ws in $Config.workspaces) {
    if (-not ($ws.PSObject.Properties.Name -contains 'privateLink')) {
        Write-Host "  Workspace '$($ws.name)' — no privateLink config, skipping."
        continue
    }
    $pl = $ws.privateLink

    $wsId = $WorkspaceMap[$ws.name]
    if (-not $wsId) {
        Write-Warning "  Workspace '$($ws.name)' has privateLink config but no resolved ID — skipping."
        continue
    }

    $entry = @{
        workspaceId    = $wsId
        plsName        = $pl.plsName
        peResourceName = $pl.peResourceName
        peType         = if ($pl.PSObject.Properties.Name -contains 'peType') { $pl.peType } else { 'Microsoft.Fabric/workspaces' }
    }

    Write-Host "  Workspace '$($ws.name)' (ID: $wsId)"
    Write-Host "    PLS Name : $($entry.plsName)"
    Write-Host "    PE Name  : $($entry.peResourceName)"
    Write-Host "    PE Type  : $($entry.peType)"

    [void]$workspaceConfigs.Add($entry)
}

if ($workspaceConfigs.Count -eq 0) {
    Write-Host "  No workspaces with privateLink config found — nothing to deploy."
    return
}

Write-Host "  Resource Group : $ResourceGroupName"
Write-Host "  Template       : $TemplateFile"
Write-Host "  Workspace(s)   : $($workspaceConfigs.Count)"

# ── Deploy per workspace ───────────────────────────────────────────────────────
foreach ($wsConfig in $workspaceConfigs) {
    $deploymentName = "pls-pe-$($wsConfig.plsName)-$(Get-Date -Format 'yyyyMMddHHmmss')"
    $deploymentParams = @{
        workspaceId      = $wsConfig.workspaceId
        plsName          = $wsConfig.plsName
        peResourceName   = $wsConfig.peResourceName
        peType           = $wsConfig.peType
        tenantId         = $plConfig.tenantId
        subnetId         = $plConfig.subnetId
        privateDnsZoneId = $plConfig.privateDnsZoneId
        location         = $plConfig.location
    }

    Write-Host "  Deploying PLS/PE for workspace $($wsConfig.workspaceId) ($($wsConfig.plsName))..."

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
    } else {
        $deployment = New-AzResourceGroupDeployment `
            -Name                    $deploymentName `
            -ResourceGroupName       $ResourceGroupName `
            -TemplateFile            $TemplateFile `
            -TemplateParameterObject $deploymentParams `
            -ErrorAction Stop

        Write-Host "    Deployment completed. ID: $($deployment.DeploymentId)"
        if ($deployment.Outputs -and $deployment.Outputs.Count -gt 0) {
            foreach ($key in $deployment.Outputs.Keys) {
                Write-Host "      Output — $key : $($deployment.Outputs[$key].Value)"
            }
        }
    }
}

Write-Host "  Private link deployment complete for $($workspaceConfigs.Count) workspace(s)."
