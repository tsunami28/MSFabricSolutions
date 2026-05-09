#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'MicrosoftFabricMgmt'; ModuleVersion = '1.0.8' }

<#
.SYNOPSIS
    Idempotently provisions workspaces defined in the environment parameter file.

.DESCRIPTION
    For each workspace in the config:
      - Creates the workspace if it does not exist
      - Updates description if it has changed
      - Assigns to the correct capacity
      - Assigns to the domain (if specified)

    This script is called by Deploy-FabricEnvironment.ps1 and assumes
    Set-FabricApiHeaders has already been called in the same PS session.

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

$deployedWorkspaces = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($workspaceConfig in $Config.workspaces) {
    $wsName = $workspaceConfig.name

    if ($WorkspaceFilter.Count -gt 0 -and $wsName -notin $WorkspaceFilter) {
        Write-PSFMessage -Level Verbose -Message "  Skipping workspace '$wsName' (not in change set)"
        continue
    }

    Write-PSFMessage -Level Host -Message "  Processing workspace: $wsName"

    # ── Resolve capacity ID ────────────────────────────────────────────────────
    $capacityName = if ($workspaceConfig.capacityOverride) {
        $workspaceConfig.capacityOverride
    } else {
        $Config.capacityName
    }

    $capacityId = $null
    if ($capacityName -and $CapacityMap.ContainsKey($capacityName)) {
        $capacityId = $CapacityMap[$capacityName]
    } elseif ($capacityName) {
        # Try to resolve by name via API
        $capacity = Get-FabricCapacity | Where-Object { $_.displayName -eq $capacityName } | Select-Object -First 1
        if ($capacity) {
            $capacityId = $capacity.id
        } else {
            Write-PSFMessage -Level Warning -Message "    Capacity '$capacityName' not found. Workspace will be created without capacity assignment."
        }
    }

    # ── Check if workspace exists ──────────────────────────────────────────────
    $existingWorkspace = Get-FabricWorkspace -WorkspaceName $wsName -ErrorAction SilentlyContinue

    if ($DryRun) {
        if ($existingWorkspace) {
            Write-PSFMessage -Level Host -Message "    [DRY RUN] Would update workspace: $wsName"
        } else {
            Write-PSFMessage -Level Host -Message "    [DRY RUN] Would create workspace: $wsName"
        }
        $deployedWorkspaces.Add([PSCustomObject]@{ Name = $wsName; Action = 'DryRun'; Id = $existingWorkspace?.id })
        continue
    }

    # ── Create or update workspace ─────────────────────────────────────────────
    if (-not $existingWorkspace) {
        Write-PSFMessage -Level Host -Message "    Creating workspace: $wsName"

        $createParams = @{
            WorkspaceName = $wsName
        }
        if ($workspaceConfig.description) {
            $createParams['WorkspaceDescription'] = $workspaceConfig.description
        }

        $workspace = New-FabricWorkspace @createParams
        Write-PSFMessage -Level Host -Message "    Created workspace: $wsName (ID: $($workspace.id))"

    } else {
        $workspace = $existingWorkspace

        # Update description if it has changed
        if ($workspaceConfig.description -and
            $workspace.description -ne $workspaceConfig.description) {

            Write-PSFMessage -Level Host -Message "    Updating description for: $wsName"
            $workspace = Update-FabricWorkspace `
                -WorkspaceId $workspace.id `
                -WorkspaceDescription $workspaceConfig.description
        } else {
            Write-PSFMessage -Level Host -Message "    Workspace exists, no changes required: $wsName"
        }
    }

    # ── Assign capacity ────────────────────────────────────────────────────────
    if ($capacityId) {
        $currentCapacityId = $workspace.capacityId
        if ($currentCapacityId -ne $capacityId) {
            Write-PSFMessage -Level Host -Message "    Assigning capacity: $capacityName"
            Add-FabricWorkspaceCapacity -WorkspaceId $workspace.id -CapacityId $capacityId
        }
    }

    # ── Assign domain ──────────────────────────────────────────────────────────
    if ($workspaceConfig.domainName) {
        $domain = Get-FabricDomain -DomainName $workspaceConfig.domainName -ErrorAction SilentlyContinue
        if ($domain) {
            Write-PSFMessage -Level Host -Message "    Assigning domain: $($workspaceConfig.domainName)"
            Add-FabricDomainWorkspace -DomainId $domain.id -WorkspaceId $workspace.id -ErrorAction SilentlyContinue
        } else {
            Write-PSFMessage -Level Warning -Message "    Domain '$($workspaceConfig.domainName)' not found. Skipping domain assignment."
        }
    }

    $deployedWorkspaces.Add([PSCustomObject]@{
        Name   = $wsName
        Action = if ($existingWorkspace) { 'Updated' } else { 'Created' }
        Id     = $workspace.id
    })
}

Write-PSFMessage -Level Host -Message "  Workspace deployment complete. Processed: $($deployedWorkspaces.Count)"
return $deployedWorkspaces
