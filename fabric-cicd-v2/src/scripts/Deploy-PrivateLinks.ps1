#Requires -Version 7.0

<#
.SYNOPSIS
    Deploys Private Link Services (PLS) and Private Endpoints (PE) for Fabric workspaces.

.DESCRIPTION
    For each workspace that has private link configuration defined, builds a
    deployment parameter set and deploys the specified Bicep template via
    New-AzResourceGroupDeployment.

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
    When specified, runs New-AzResourceGroupDeployment with -WhatIf.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf }, ErrorMessage = "Config file not found: {0}")]
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
    [switch]$WhatIfMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Verify Azure context (provided by AzurePowerShell@5 task) ──────────────────
$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx) {
    throw "No Azure context found. This script must run inside an AzurePowerShell@5 pipeline task."
}
Write-Host "  Using Az context: $($ctx.Account.Id) (Subscription: $($ctx.Subscription.Id))"

# ── Load helpers & inputs ──────────────────────────────────────────────────────
$helpersRoot = Join-Path $PSScriptRoot '../helpers'
. (Join-Path $helpersRoot 'Read-EnvironmentConfig.ps1')

$Config       = Read-EnvironmentConfig -ConfigPath $ConfigFile
$WorkspaceMap = Get-Content $WorkspaceMapFile -Raw | ConvertFrom-Json -AsHashtable

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
        name           = $pl.plsName
        peResourceName = if ($pl.PSObject.Properties.Name -contains 'peResourceName') { $pl.peResourceName } else { '' }
    }

    Write-Host "  Workspace '$($ws.name)' (ID: $wsId)"
    Write-Host "    PLS Name : $($entry.name)"
    if ($entry.peResourceName) {
        Write-Host "    PE  Name : $($entry.peResourceName)"
    }

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
    $deploymentName = "pls-$($wsConfig.name)-$(Get-Date -Format 'yyyyMMddHHmmss')"
    $deploymentParams = @{
        name        = $wsConfig.name
        workspaceId = $wsConfig.workspaceId
    }
    # tenantId defaults to subscription().tenantId in the template; pass only if explicitly set
    if ($plConfig.PSObject.Properties.Name -contains 'tenantId' -and $plConfig.tenantId) {
        $deploymentParams['tenantId'] = $plConfig.tenantId
    }
    # Private Endpoint parameters — only passed when peResourceName is configured
    if ($wsConfig.peResourceName) {
        $deploymentParams['peResourceName'] = $wsConfig.peResourceName
        if ($plConfig.PSObject.Properties.Name -contains 'subnetId' -and $plConfig.subnetId) {
            $deploymentParams['subnetId'] = $plConfig.subnetId
        }
        if ($plConfig.PSObject.Properties.Name -contains 'privateDnsZoneId' -and $plConfig.privateDnsZoneId) {
            $deploymentParams['privateDnsZoneId'] = $plConfig.privateDnsZoneId
        }
        if ($plConfig.PSObject.Properties.Name -contains 'location' -and $plConfig.location) {
            $deploymentParams['location'] = $plConfig.location
        }
    }

    Write-Host "  Deploying PLS for workspace $($wsConfig.workspaceId) ($($wsConfig.name))..."

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

        Write-Host "    Deployment completed: $deploymentName"
        if ($deployment.Outputs -and $deployment.Outputs.Count -gt 0) {
            foreach ($key in $deployment.Outputs.Keys) {
                Write-Host "      Output — $key : $($deployment.Outputs[$key].Value)"
            }
        }
    }
}

Write-Host "  Private link deployment complete for $($workspaceConfigs.Count) workspace(s)."
