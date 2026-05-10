<#
.SYNOPSIS
    Orchestrates the deployment of Fabric Workspace infrastructure including Private Link Service and Private Endpoints.
    
.DESCRIPTION
    This script manages the complete deployment flow for a Fabric Workspace:
    1. Creates/updates the Fabric workspace using MicrosoftFabricMgmt module
    2. Deploys the Workspace Private Link Service using Bicep
    3. Creates Private Endpoints connected to the PLS using Bicep
    
    The script supports WhatIf mode for validation and uses service principal authentication.
    
.PARAMETER Environment
    The environment name (dev, tst, prd)
    
.PARAMETER ParamFilePath
    Path to the parameter JSONC file containing workspace and infrastructure configurations
    
.PARAMETER TemplateFile
    Path to the Bicep template file for PLS and PE deployment
    
.PARAMETER ResourceGroupName
    Name of the resource group where resources will be deployed
    
.PARAMETER WhatIf
    When specified, only validates what would happen without making actual changes
    
.EXAMPLE
    .\Deploy-FabricWorkspaceInfra.ps1 -Environment dev `
        -ParamFilePath "parameters/necp01/weu/dev/deployFabricWorkspace.param.jsonc" `
        -TemplateFile "sources/infrastructure-as-code/mainTemplates/deployFabricWorkspaceInfra.bicep" `
        -ResourceGroupName "ndpl-necp01-weu-fdev-rsg"
    
.EXAMPLE
    .\Deploy-FabricWorkspaceInfra.ps1 -Environment dev `
        -ParamFilePath "parameters/necp01/weu/dev/deployFabricWorkspace.param.jsonc" `
        -TemplateFile "sources/infrastructure-as-code/mainTemplates/deployFabricWorkspaceInfra.bicep" `
        -ResourceGroupName "ndpl-necp01-weu-fdev-rsg" `
        -WhatIf
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('dev', 'tst', 'prd')]
    [string]$Environment,

    [Parameter(Mandatory = $true)]
    [string]$ParamFilePath,

    [Parameter(Mandatory = $true)]
    [string]$TemplateFile,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [string]$ServicePrincipalId,

    [Parameter(Mandatory = $false)]
    [string]$ServicePrincipalSecret,

    [Parameter(Mandatory = $false)]
    [string]$ManagedIdentityClientId = "4f0a503a-0b95-49b4-8970-ddebb7471586",

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

# ==================== SECTION 1: Setup ====================

Write-Output "=================================================" 
Write-Output "Fabric Workspace Infrastructure Deployment" 
Write-Output "Environment: $Environment | WhatIf: $WhatIf" 
Write-Output "=================================================" 

# ==================== SECTION 2: Authentication ====================

Write-Output "`n[2/5] Authenticating to Fabric API..."

try {
    if ($ServicePrincipalId -and $ServicePrincipalSecret) {
        # Local/manual run — get token using SPN credentials directly
        Write-Output "  Authenticating with Service Principal..."
        $body = "grant_type=client_credentials" +
        "&client_id=$ServicePrincipalId" +
        "&client_secret=$([Uri]::EscapeDataString($ServicePrincipalSecret))" +
        "&scope=https://api.fabric.microsoft.com/.default"
        $tokenResponse = Invoke-RestMethod `
            -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
            -Method POST `
            -Body $body `
            -ContentType "application/x-www-form-urlencoded"
        $fabricToken = $tokenResponse.access_token
        Write-Output "✓ Successfully authenticated with Service Principal"
    }
    else {
        # ADO run — use existing Az PowerShell context
        Write-Output "  Acquiring Fabric-scoped token via Az PowerShell context..."
        $tokenObj = Get-AzAccessToken -ResourceUrl "https://api.fabric.microsoft.com"
        $fabricToken = [System.Net.NetworkCredential]::new("", $tokenObj.Token).Password
        Write-Output "  Token acquired. Expires: $($tokenObj.ExpiresOn)"
        Write-Output "✓ Successfully authenticated with Managed Identity"
    }

    $fabricHeaders = @{
        'Authorization' = "Bearer $fabricToken"
        'Content-Type'  = 'application/json'
    }
}
catch {
    Write-Output "✗ Failed to authenticate to Fabric API: $($_.Exception.Message)"
    throw
}
# ==================== SECTION 3: Parse Parameter File ====================

Write-Output "`n[3/5] Parsing parameter file..." 

if (-not (Test-Path $ParamFilePath)) {
    throw "Parameter file not found: $ParamFilePath"
}

$paramContent = Get-Content -Path $ParamFilePath -Raw

# Remove JSONC comments and parse
$paramJson = $paramContent -replace '(?m)^\s*//.*$', '' -replace '(?s)/\*.*?\*/', ''
$config = $paramJson | ConvertFrom-Json

Write-Output "✓ Parameter file parsed successfully"

# ==================== SECTION 4: Create/Update Fabric Workspaces ====================

Write-Output "`n[4/5] Processing Fabric Workspaces (create/update)..." 

$workspacesConfig = $config.parameters.workspaces.value
Write-Output "  Found $($workspacesConfig.Count) workspace(s) to process" 

# Get existing workspaces once and build a hashtable for fast lookup
$fabricHeaders = @{
    'Authorization' = "Bearer $fabricToken"
    'Content-Type'  = 'application/json'
}
$existingWorkspaces = (Invoke-RestMethod `
        -Uri "https://api.fabric.microsoft.com/v1/workspaces" `
        -Headers $fabricHeaders `
        -Method GET).value
$workspaceByName = @{}
foreach ($ws in $existingWorkspaces) {
    $workspaceByName[$ws.displayName] = $ws
}
$workspaceConfigsWithIds = [System.Collections.ArrayList]::new()

foreach ($workspace in $workspacesConfig) {
    $workspaceName = $workspace.name
    $workspaceDescription = $workspace.description
    $capacityId = $workspace.capacityId
    
    Write-Output "`n  Workspace: $workspaceName" 
    Write-Output "    Description: $workspaceDescription" 
    Write-Output "    Capacity ID: $capacityId" 
    Write-Output "    PLS Name: $($workspace.plsName)" 
    Write-Output "    PE Name: $($workspace.peResourceName)" 
    # Check if workspace exists using hashtable for fast lookup
    $existingWorkspace = $workspaceByName[$workspaceName]
    $workspaceId = $null
    
    if ($existingWorkspace) {
        $workspaceId = $existingWorkspace.id
        Write-Output "    Status: Found existing workspace (ID: $workspaceId)" 
        
        if ($WhatIf) {
            Write-Output "    [WhatIf] Would update workspace description" 
        }
        else {
            try {
                # Update-FabricWorkspace
                Invoke-RestMethod `
                    -Uri "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId" `
                    -Headers $fabricHeaders `
                    -Method PATCH `
                    -Body (@{ description = $workspaceDescription } | ConvertTo-Json)
                Write-Output "    ✓ Workspace updated successfully" 
            }
            catch {
                Write-Output "    ✗ Failed to update workspace: $($_.Exception.Message)" 
                throw
            }
        }
    }
    else {
        Write-Output "    Status: Creating new workspace..." 
        
        if ($WhatIf) {
            Write-Output "    [WhatIf] Would create workspace" 
            # Use placeholder ID for WhatIf
            $workspaceId = "00000000-0000-0000-0000-000000000000"
        }
        else {
            try {
                $body = @{
                    displayName = $workspaceName
                    description = $workspaceDescription
                    capacityId  = $capacityId
                } | ConvertTo-Json
                $newWs = Invoke-RestMethod `
                    -Uri "https://api.fabric.microsoft.com/v1/workspaces" `
                    -Headers $fabricHeaders `
                    -Method POST `
                    -Body $body
                
                $workspaceId = $newWs.id
                Write-Output "    ✓ Workspace created successfully (ID: $workspaceId)" 
            }
            catch {
                if ($_.Exception.Response.StatusCode -eq 409) {
                    # Workspace already exists but not visible to this identity - look it up by name
                    Write-Output "    ℹ Workspace already exists, retrieving ID..."
                    $allWorkspaces = (Invoke-RestMethod `
                            -Uri "https://api.fabric.microsoft.com/v1/admin/workspaces?name=$([Uri]::EscapeDataString($workspaceName))" `
                            -Headers $fabricHeaders `
                            -Method GET).workspaces
                    $workspaceId = $allWorkspaces | Where-Object { $_.name -eq $workspaceName } | Select-Object -ExpandProperty id
                    if ($workspaceId) {
                        Write-Output "    ✓ Found existing workspace (ID: $workspaceId)"
                    }
                    else {
                        Write-Output "    ✗ Could not retrieve existing workspace ID"
                        throw
                    }
                }
                else {
                    Write-Output "    ✗ Failed to create workspace: $($_.Exception.Message)"
                    throw
                }
            }
        }
    }
    
    if (-not $workspaceId) {
        throw "Failed to obtain workspace ID for: $workspaceName"
    }
    
    # ===== Process Role Assignments for this workspace =====
    if ($workspace.roleAssignments -and $workspace.roleAssignments.Count -gt 0) {
        Write-Output "    Processing $($workspace.roleAssignments.Count) role assignment(s)..." 
        
        foreach ($roleAssignment in $workspace.roleAssignments) {
            $principalId = $roleAssignment.principalId
            $principalType = $roleAssignment.principalType
            $workspaceRole = $roleAssignment.workspaceRole
            
            Write-Output "      - Principal: $principalId | Type: $principalType | Role: $workspaceRole" 
            
            if ($WhatIf) {
                Write-Output "        [WhatIf] Would assign role to principal" 
            }
            else {
                try {
                    # First, check if a role assignment already exists for this principal
                    $existingAssignment = (Invoke-RestMethod `
                            -Uri "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/roleAssignments" `
                            -Headers $fabricHeaders `
                            -Method GET).value | 
                    Where-Object { $_.principal.id -in $principalId }
                    
                    if ($existingAssignment) {
                        # Update existing role assignment
                        Write-Output "        Found existing assignment, updating role..." 
                        Invoke-RestMethod `
                            -Uri "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/roleAssignments/$($existingAssignment.id)" `
                            -Headers $fabricHeaders `
                            -Method PUT `
                            -Body (@{ role = $workspaceRole } | ConvertTo-Json)
                        Write-Output "        ✓ Role assignment updated successfully" 
                    }
                    else {
                        # Create new role assignment
                        Write-Output "        Creating new role assignment..." 
                        Invoke-RestMethod `
                            -Uri "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/roleAssignments" `
                            -Headers $fabricHeaders `
                            -Method POST `
                            -Body (@{
                                principal = @{ id = $principalId; type = $principalType }
                                role      = $workspaceRole
                            } | ConvertTo-Json)
                        Write-Output "        ✓ Role assignment created successfully" 
                    }
                }
                catch {
                    Write-Output "        ✗ Failed to assign role: $($_.Exception.Message)" 
                    throw
                }
            }
        }
    }
    
    # Build workspace config object with injected workspace ID
    $wsConfigWithId = @{
        workspaceId    = $workspaceId
        plsName        = $workspace.plsName
        peResourceName = $workspace.peResourceName
        peType         = $workspace.peType
    }
    
    [void]$workspaceConfigsWithIds.Add($wsConfigWithId)
}

Write-Output "`n  ✓ Workspace processing complete. $($workspaceConfigsWithIds.Count) workspace(s) ready for infrastructure deployment" 

# Convert ArrayList to array for downstream compatibility
$workspaceConfigsWithIds = $workspaceConfigsWithIds.ToArray()

# ==================== SECTION 5: Deploy Infrastructure (PLS & PE for all workspaces) ====================

Write-Output "`n[5/5] Deploying Private Link Services and Private Endpoints..." 

if (-not (Test-Path $TemplateFile)) {
    throw "Template file not found: $TemplateFile"
}

# Get shared infrastructure parameters
$sharedInfra = $config.parameters

# Build deployment parameters with workspace configs array
$deploymentParams = @{
    workspaceConfigs = $workspaceConfigsWithIds
    tenantId         = $sharedInfra.tenantId.value
    subnetId         = $sharedInfra.subnetId.value
    privateDnsZoneId = $sharedInfra.privateDnsZoneId.value
    location         = $sharedInfra.location.value
}

Write-Output "  Resource Group: $ResourceGroupName" 
Write-Output "  Template: $TemplateFile" 
Write-Output "  Deploying infrastructure for $($workspaceConfigsWithIds.Count) workspace(s)..." 

if ($WhatIf) {
    Write-Output "  [WhatIf] Validating Bicep deployment..." 
    try {
        New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName `
            -TemplateFile $TemplateFile `
            -TemplateParameterObject $deploymentParams `
            -WhatIf -ErrorAction Stop
        Write-Output "  ✓ Deployment validation passed (WhatIf)" 
    }
    catch {
        Write-Output "  ✗ Deployment validation failed: $($_.Exception.Message)" 
        throw
    }
}
else {
    Write-Output "  Starting Bicep deployment..." 
    try {
        $deployment = New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName `
            -TemplateFile $TemplateFile `
            -TemplateParameterObject $deploymentParams `
            -ErrorAction Stop
        
        Write-Output "  ✓ Bicep deployment completed successfully" 
        Write-Output "  ✓ Deployment ID: $($deployment.DeploymentId)" 
        Write-Output "  ✓ Outputs:" 
        
        if ($deployment.Outputs.Count -gt 0) {
            $deployment.Outputs | ForEach-Object {
                Write-Output "    - $($_.Name): $($_.Value.Value)" 
            }
        }
        else {
            Write-Output "    (No outputs)" 
        }
    }
    catch {
        Write-Output "  ✗ Bicep deployment failed: $($_.Exception.Message)" 
        throw
    }
}

Write-Output "`n=================================================" 
Write-Output "✓ Fabric Workspace Infrastructure Deployment Complete" 
Write-Output "=================================================" 
