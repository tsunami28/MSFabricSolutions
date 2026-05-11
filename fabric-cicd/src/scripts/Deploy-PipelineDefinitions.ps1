#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'MicrosoftFabricMgmt'; ModuleVersion = '1.0.8' }
#Requires -Modules @{ ModuleName = 'PSFramework'; ModuleVersion = '1.12.0' }

<#
.SYNOPSIS
    Uploads data pipeline definitions from the repository to Fabric.

.DESCRIPTION
    For each data pipeline entry that has a 'definitionPath' in the config, this script:
      1. Resolves the pipeline item by name in Fabric
      2. Reads 'pipeline-content.json' from the definitionPath folder
      3. Base64-encodes the raw bytes
      4. Wraps the payload in the Fabric definition envelope
      5. Calls POST /v1/workspaces/{id}/dataPipelines/{id}/updateDefinition

    The upload runs on every pipeline execution regardless of whether the file has
    changed. This ensures the live Fabric definition is always in sync with the repo.
    The updateDefinition API returns HTTP 202 (LRO); the call blocks until completion.

    Pipelines without a 'definitionPath' are silently skipped.
    Notebook definition upload is deferred to a later phase.

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
    Phase 3. Called by Deploy-FabricEnvironment.ps1 via splatting.
    Must run after Deploy-Items.ps1 (pipelines must exist before their definitions
    can be uploaded).
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

# Load REST helper if not already in scope (normally dot-sourced by the orchestrator)
if (-not (Get-Command -Name 'Invoke-FabricRestMethod' -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot '../helpers/Invoke-FabricRestMethod.ps1')
}

# Resolve repository root - needed to locate definitionPath files
if (-not $RepoRoot) {
    $RepoRoot = if ($env:SYSTEM_DEFAULTWORKINGDIRECTORY) {
        $env:SYSTEM_DEFAULTWORKINGDIRECTORY
    } else {
        # Local dev: scripts/ → src/ → fabric-cicd/ → repo-root
        (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    }
}

Write-PSFMessage -Level Verbose -Message "  Repository root for definitions: $RepoRoot"

$uploadedCount = 0

foreach ($workspaceConfig in $Config.workspaces) {
    $wsName    = $workspaceConfig.name
    $pipelines = @($workspaceConfig.items.dataPipelines | Where-Object { $_ -and $_.definitionPath })

    if ($pipelines.Count -eq 0) { continue }

    if ($WorkspaceFilter.Count -gt 0 -and $wsName -notin $WorkspaceFilter) {
        Write-PSFMessage -Level Verbose -Message "  Skipping pipeline definitions for workspace '$wsName' (not in change set)"
        continue
    }

    Write-PSFMessage -Level Host -Message "  Uploading pipeline definitions for workspace: $wsName"

    $workspace = Get-FabricWorkspace -WorkspaceName $wsName -ErrorAction SilentlyContinue
    if (-not $workspace) {
        Write-PSFMessage -Level Warning -Message "    Workspace '$wsName' not found. Run the workspaces scope first."
        continue
    }

    foreach ($plConfig in $pipelines) {
        $plName      = $plConfig.name
        $defFolder   = Join-Path $RepoRoot $plConfig.definitionPath
        $contentFile = Join-Path $defFolder 'pipeline-content.json'

        if (-not (Test-Path $contentFile)) {
            Write-PSFMessage -Level Warning -Message "    Pipeline '$plName': definition file not found at '$contentFile'. Skipping."
            Write-Host "##vso[task.logissue type=warning]Pipeline definition file not found: $contentFile"
            continue
        }

        $pipeline = Get-FabricDataPipeline -WorkspaceId $workspace.id -DataPipelineName $plName -ErrorAction SilentlyContinue
        if (-not $pipeline) {
            Write-PSFMessage -Level Warning -Message "    Pipeline '$plName' not found in workspace '$wsName'. Run the items scope first."
            continue
        }

        if ($DryRun) {
            Write-PSFMessage -Level Host -Message "    [DRY RUN] Would upload definition for pipeline '$plName' from '$contentFile'"
            continue
        }

        Write-PSFMessage -Level Host -Message "    Uploading definition: $plName"

        # Read the inner pipeline-content.json and base64-encode it.
        # The Fabric updateDefinition API wraps the encoded payload in a parts envelope.
        $rawBytes = [System.IO.File]::ReadAllBytes($contentFile)
        $b64      = [System.Convert]::ToBase64String($rawBytes)

        $body = [ordered]@{
            definition = [ordered]@{
                parts = @(
                    [ordered]@{
                        path        = 'pipeline-content.json'
                        payload     = $b64
                        payloadType = 'InlineBase64'
                    }
                )
            }
        } | ConvertTo-Json -Depth 10

        $updateUri = New-FabricUri -Path "workspaces/$($workspace.id)/dataPipelines/$($pipeline.id)/updateDefinition"

        # updateDefinition returns HTTP 202 - WaitForLRO polls until Succeeded/Failed
        Invoke-FabricRestMethod -Uri $updateUri -Method Post -Body $body -WaitForLRO | Out-Null

        $uploadedCount++
        Write-PSFMessage -Level Host -Message "    Definition uploaded: $plName"
    }
}

Write-PSFMessage -Level Host -Message "  Pipeline definitions step complete. Uploaded: $uploadedCount."
return $uploadedCount
