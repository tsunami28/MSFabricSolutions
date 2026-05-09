#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'MicrosoftFabricMgmt'; ModuleVersion = '1.0.8' }

<#
.SYNOPSIS
    Idempotently configures RBAC role assignments for workspaces defined in the
    environment parameter file.

.DESCRIPTION
    For each workspace in the config, ensures all role assignments from the
    'roles' array are present. Does NOT remove assignments that exist in Fabric
    but are absent from the config — only adds missing ones.

    To explicitly remove a role assignment, set "remove": true on the entry.

.NOTES
    Phase 2 implementation. Called by Deploy-FabricEnvironment.ps1 via splatting.
    Do not run standalone without first calling Set-FabricApiHeaders.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [PSCustomObject]$Config,

    [Parameter(Mandatory)]
    [hashtable]$CapacityMap,

    [Parameter(Mandatory)]
    [ValidateSet('dev', 'tst', 'prd')]
    [string]$Environment,

    [Parameter()]
    [bool]$DryRun = $false,

    [Parameter()]
    [string[]]$WorkspaceFilter = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$assignmentResults = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($workspaceConfig in $Config.workspaces) {
    $wsName = $workspaceConfig.name

    if ($WorkspaceFilter.Count -gt 0 -and $wsName -notin $WorkspaceFilter) {
        Write-PSFMessage -Level Verbose -Message "  Skipping workspace '$wsName' (not in change set)"
        continue
    }

    $workspace = Get-FabricWorkspace -WorkspaceName $wsName -ErrorAction SilentlyContinue
    if (-not $workspace) {
        Write-PSFMessage -Level Warning -Message "  Workspace '$wsName' not found. Skipping security step."
        continue
    }

    $roles = @($workspaceConfig.roles | Where-Object { $_ })
    if ($roles.Count -eq 0) {
        Write-PSFMessage -Level Verbose -Message "  No role assignments defined for: $wsName"
        continue
    }

    Write-PSFMessage -Level Host -Message "  Configuring roles for workspace: $wsName"

    # Get current role assignments
    $currentAssignments = Get-FabricWorkspaceRoleAssignment -WorkspaceId $workspace.id -ErrorAction SilentlyContinue

    foreach ($roleConfig in $roles) {
        $remove = $roleConfig.PSObject.Properties['remove'] -and $roleConfig.remove -eq $true

        # Check if assignment already exists
        $exists = $currentAssignments | Where-Object {
            ($_.principal?.id -eq $roleConfig.principal -or $_.principal?.userPrincipalName -eq $roleConfig.principal) -and
            $_.role -eq $roleConfig.role
        }

        if ($remove) {
            if ($DryRun) {
                Write-PSFMessage -Level Host -Message "    [DRY RUN] Would remove $($roleConfig.role) for: $($roleConfig.principal)"
            } elseif ($exists) {
                Write-PSFMessage -Level Host -Message "    Removing $($roleConfig.role) for: $($roleConfig.principal)"
                Remove-FabricWorkspaceRoleAssignment -WorkspaceId $workspace.id -PrincipalId $exists.principal.id -ErrorAction SilentlyContinue
                $assignmentResults.Add([PSCustomObject]@{ Workspace = $wsName; Principal = $roleConfig.principal; Role = $roleConfig.role; Action = 'Removed' })
            }
        } elseif ($exists) {
            Write-PSFMessage -Level Verbose -Message "    Assignment exists, no changes: $($roleConfig.role) → $($roleConfig.principal)"
            $assignmentResults.Add([PSCustomObject]@{ Workspace = $wsName; Principal = $roleConfig.principal; Role = $roleConfig.role; Action = 'Skipped' })
        } else {
            if ($DryRun) {
                Write-PSFMessage -Level Host -Message "    [DRY RUN] Would assign $($roleConfig.role) to: $($roleConfig.principal)"
                $assignmentResults.Add([PSCustomObject]@{ Workspace = $wsName; Principal = $roleConfig.principal; Role = $roleConfig.role; Action = 'DryRun' })
            } else {
                Write-PSFMessage -Level Host -Message "    Assigning $($roleConfig.role) to: $($roleConfig.principal) ($($roleConfig.principalType))"
                Add-FabricWorkspaceRoleAssignment `
                    -WorkspaceId    $workspace.id `
                    -PrincipalId    $roleConfig.principal `
                    -PrincipalType  $roleConfig.principalType `
                    -Role           $roleConfig.role
                $assignmentResults.Add([PSCustomObject]@{ Workspace = $wsName; Principal = $roleConfig.principal; Role = $roleConfig.role; Action = 'Assigned' })
            }
        }
    }
}

Write-PSFMessage -Level Host -Message "  Security deployment complete. Processed: $($assignmentResults.Count) assignment(s)."
return $assignmentResults
