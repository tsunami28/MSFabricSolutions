#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'MicrosoftFabricMgmt'; ModuleVersion = '1.0.8' }
#Requires -Modules @{ ModuleName = 'PSFramework'; ModuleVersion = '1.12.0' }

<#
.SYNOPSIS
    Uploads Spark Job Definition definitions from the repository to Fabric.

.DESCRIPTION
    For each Spark Job Definition entry that has a 'definitionPath' in the config,
    this script:
      1. Resolves the SJD item by name in Fabric
      2. Locates 'SparkJobDefinitionV1.json' inside the definitionPath folder
      3. Calls Update-FabricSparkJobDefinitionDefinition, which reads the file,
         base64-encodes it, and posts it to the updateDefinition API

    The upload runs on every pipeline execution regardless of whether the file has
    changed — this ensures the live Fabric definition is always in sync with the repo.
    The updateDefinition API returns HTTP 202 (LRO); the module polls until completion.

    SJDs without a 'definitionPath' are silently skipped.

.PARAMETER Config
    Parsed environment configuration (PSCustomObject from the JSON parameter file).

.PARAMETER CapacityMap
    Capacity name-to-ID map. Not used here; present for a consistent step signature.

.PARAMETER Environment
    Target environment name. Valid values: dev | tst | prd.

.PARAMETER DryRun
    When $true, logs planned changes without making any API calls.

.PARAMETER RepoRoot
    Root of the checked-out repository. Used to resolve relative 'definitionPath'
    values. Defaults to $env:SYSTEM_DEFAULTWORKINGDIRECTORY (Azure DevOps) or the
    folder three levels above the scripts directory (local development).

.NOTES
    Phase 4. Called by Deploy-FabricEnvironment.ps1 via splatting.
    Must run after Deploy-Items.ps1 (SJDs must exist before their definitions can
    be uploaded).

    Unlike Deploy-PipelineDefinitions.ps1, this script uses the module cmdlet
    Update-FabricSparkJobDefinitionDefinition directly — it accepts a file path
    and handles base64 encoding internally.
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
    [string]$RepoRoot,

    [Parameter()]
    [string[]]$WorkspaceFilter = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolve repository root
if (-not $RepoRoot) {
    $RepoRoot = if ($env:SYSTEM_DEFAULTWORKINGDIRECTORY) {
        $env:SYSTEM_DEFAULTWORKINGDIRECTORY
    } else {
        # Local dev: scripts/ → src/ → fabric-cicd/ → repo-root
        (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    }
}

Write-PSFMessage -Level Verbose -Message "  Repository root for SJD definitions: $RepoRoot"

$uploadedCount = 0

foreach ($workspaceConfig in $Config.workspaces) {
    $wsName = $workspaceConfig.name
    $sjds   = @($workspaceConfig.items.sparkJobDefinitions | Where-Object { $_ -and $_.definitionPath })

    if ($sjds.Count -eq 0) { continue }

    if ($WorkspaceFilter.Count -gt 0 -and $wsName -notin $WorkspaceFilter) {
        Write-PSFMessage -Level Verbose -Message "  Skipping SJD definitions for workspace '$wsName' (not in change set)"
        continue
    }

    Write-PSFMessage -Level Host -Message "  Uploading Spark Job Definition definitions for workspace: $wsName"

    $workspace = Get-FabricWorkspace -WorkspaceName $wsName -ErrorAction SilentlyContinue
    if (-not $workspace) {
        Write-PSFMessage -Level Warning -Message "    Workspace '$wsName' not found. Run the workspaces scope first."
        continue
    }

    foreach ($sjdConfig in $sjds) {
        $sjdName    = $sjdConfig.name
        $defFolder  = Join-Path $RepoRoot $sjdConfig.definitionPath
        $defFile    = Join-Path $defFolder 'SparkJobDefinitionV1.json'

        if (-not (Test-Path $defFile)) {
            Write-PSFMessage -Level Warning -Message "    SJD '$sjdName': definition file not found at '$defFile'. Skipping."
            Write-Host "##vso[task.logissue type=warning]SJD definition file not found: $defFile"
            continue
        }

        $sjd = Get-FabricSparkJobDefinition -WorkspaceId $workspace.id -SparkJobDefinitionName $sjdName -ErrorAction SilentlyContinue
        if (-not $sjd) {
            Write-PSFMessage -Level Warning -Message "    SJD '$sjdName' not found in workspace '$wsName'. Run the items scope first."
            continue
        }

        if ($DryRun) {
            Write-PSFMessage -Level Host -Message "    [DRY RUN] Would upload definition for SJD '$sjdName' from '$defFile'"
            continue
        }

        Write-PSFMessage -Level Host -Message "    Uploading definition: $sjdName"

        # Update-FabricSparkJobDefinitionDefinition reads the file path and handles
        # base64 encoding + envelope construction internally.
        Update-FabricSparkJobDefinitionDefinition `
            -WorkspaceId                    $workspace.id `
            -SparkJobDefinitionId           $sjd.id `
            -SparkJobDefinitionPathDefinition $defFile | Out-Null

        $uploadedCount++
        Write-PSFMessage -Level Host -Message "    Definition uploaded: $sjdName"
    }
}

Write-PSFMessage -Level Host -Message "  Spark Job Definition upload step complete. Uploaded: $uploadedCount."
return $uploadedCount
