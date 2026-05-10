#Requires -Version 7.0

<#
.SYNOPSIS
    Deploys Fabric items from local source directories into target workspaces
    using the Fabric CLI 'fab deploy' command.

.DESCRIPTION
    For each workspace in the config that has an 'items' block:
      - Generates a fab deploy config YAML (and optional parameter file) for
        the workspace via New-FabDeployConfig
      - Runs 'fab deploy --config <generated.yml> -f' to publish/unpublish items
      - fab deploy handles: create new items, update changed items, remove items
        no longer present in the source directory, and resolve item dependencies

    Called by Deploy-FabricEnvironment.ps1. Assumes 'fab auth login' has
    already been called in the same shell session.

.NOTES
    Dot-sourced by Deploy-FabricEnvironment.ps1. Not a standalone script.

    The items source directories must follow the Fabric Git Integration structure:
      <workspace-folder>/
        <item-name>.<ItemType>/
          .platform          ← contains logical ID for dependency resolution
          <item definition files>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [PSCustomObject]$Config,

    [Parameter(Mandatory)]
    [hashtable]$WorkspaceMap,   # workspace name → GUID (from Deploy-Workspaces)

    [Parameter(Mandatory)]
    [ValidateSet('dev', 'tst', 'prd')]
    [string]$Environment,

    [Parameter(Mandatory)]
    [string]$RepoRoot           # absolute path to repository root
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$helpersRoot = Join-Path $PSScriptRoot '../helpers'
. (Join-Path $helpersRoot 'Invoke-FabCli.ps1')
. (Join-Path $helpersRoot 'New-FabDeployConfig.ps1')

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "fabric-cicd-v2-deploy-$Environment-$(Get-Date -Format 'yyyyMMddHHmmss')"
$null = New-Item -ItemType Directory -Path $tempDir -Force

try {
    foreach ($workspaceConfig in $Config.workspaces) {
        $wsName = $workspaceConfig.name

        if (-not ($workspaceConfig.PSObject.Properties.Name -contains 'items') -or -not $workspaceConfig.items) {
            Write-Host "  Skipping item deployment for '$wsName' — no 'items' block defined."
            continue
        }

        if (-not $WorkspaceMap.ContainsKey($wsName)) {
            Write-Warning "  Workspace '$wsName' not found in workspace map. Skipping item deployment."
            continue
        }

        $wsId   = $WorkspaceMap[$wsName]
        $items  = $workspaceConfig.items

        # ── Resolve repository directory ───────────────────────────────────────
        $repoDir = $items.repository_directory
        if (-not $repoDir) {
            Write-Warning "  No 'repository_directory' defined for workspace '$wsName'. Skipping item deployment."
            continue
        }
        if (-not [System.IO.Path]::IsPathRooted($repoDir)) {
            $repoDir = Join-Path $RepoRoot $repoDir
        }

        if (-not (Test-Path $repoDir -PathType Container)) {
            Write-Warning "  repository_directory '$repoDir' not found for workspace '$wsName'. Skipping."
            continue
        }

        Write-Host "  Deploying items to workspace: $wsName (ID: $wsId)"
        Write-Host "    Source: $repoDir"

        # ── Build item_types_in_scope ──────────────────────────────────────────
        $itemTypesInScope = @()
        if (($items.PSObject.Properties.Name -contains 'item_types_in_scope') -and $items.item_types_in_scope) {
            $itemTypesInScope = @($items.item_types_in_scope)
            Write-Host "    Item types: $($itemTypesInScope -join ', ')"
        }

        # ── Build find_replace list ────────────────────────────────────────────
        $findReplace = @()
        $hasParams = ($items.PSObject.Properties.Name -contains 'parameters') -and $items.parameters
        if ($hasParams -and ($items.parameters.PSObject.Properties.Name -contains 'find_replace') -and $items.parameters.find_replace) {
            $findReplace = @($items.parameters.find_replace | ForEach-Object {
                @{ find_value = $_.find_value; replace_value = $_.replace_value }
            })
            Write-Host "    Find/replace rules: $($findReplace.Count)"
        }

        # ── Generate fab deploy config ─────────────────────────────────────────
        $generated = New-FabDeployConfig `
            -WorkspaceName       $wsName `
            -WorkspaceId         $wsId `
            -RepositoryDirectory $repoDir `
            -ItemTypesInScope    $itemTypesInScope `
            -FindReplace         $findReplace `
            -OutputDirectory     $tempDir

        Write-Verbose "    Deploy config: $($generated.ConfigPath)"

        # ── Run fab deploy ─────────────────────────────────────────────────────
        $deployArgs = @('deploy', '--config', $generated.ConfigPath, '-f')
        Invoke-FabCli -Arguments $deployArgs -MaxRetries 2 | Out-Null

        Write-Host "    Item deployment complete: $wsName"
    }
} finally {
    # Clean up generated temp files
    if (Test-Path $tempDir) {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "  Item deployment complete for all workspaces."
