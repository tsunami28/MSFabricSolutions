#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'PSFramework'; ModuleVersion = '1.12.0' }

<#
.SYNOPSIS
    Determines which workspaces are affected by changes in the current PR or push.

.DESCRIPTION
    Computes the set of workspaces that need to be deployed by comparing changed
    files in git against the environment configuration.

    Decision logic (first match wins):
      1. If git diff fails or produces no output          → AllWorkspaces (safe fallback)
      2. If shared config (capacities, schema) changed    → AllWorkspaces
      3. If env JSON changed:
           - Retrieve the old version with 'git show'
           - JSON-diff workspace entries individually
           - Only include workspaces whose entry changed / was added
      4. If artifact files changed:
           - Walk all workspace 'definitionPath' references in the config
           - Any workspace referencing a changed artifact path is included
      5. If no changes map to any workspace               → NothingToDo

    Return value: PSCustomObject with three properties:
      NothingToDo     [bool]    - no Fabric changes detected; skip deployment
      AllWorkspaces   [bool]    - full deploy required
      WorkspaceFilter [string[]]- ordered list of workspace names to deploy
                                  (only meaningful when NothingToDo=$false and AllWorkspaces=$false)

    This script does NOT call any Fabric API — it is safe to run without Azure auth.

.PARAMETER Environment
    Target environment name. Valid values: dev | tst | prd.

.PARAMETER ConfigPath
    Absolute path to the environment JSON parameter file.

.PARAMETER RepoRoot
    Root of the repository on disk. Used to resolve artifact paths and compute
    relative paths for git diff matching. Defaults to SYSTEM_DEFAULTWORKINGDIRECTORY
    (ADO) or three levels up from this script (local dev).

.PARAMETER BaseRef
    Git ref to diff against. Defaults to 'origin/main'.
    In a PR context, use "origin/$(System.PullRequest.TargetBranchName)".

.PARAMETER FabricCicdRoot
    Repo-relative path to the fabric-cicd folder. Used to locate config/shared/.
    Default: 'fabric-cicd'.

.EXAMPLE
    # PR pipeline — compare against target branch
    $scope = & Get-DeploymentScope.ps1 `
        -Environment dev `
        -ConfigPath '$(Build.SourcesDirectory)/fabric-cicd/config/environments/dev.json' `
        -RepoRoot   '$(Build.SourcesDirectory)' `
        -BaseRef    'origin/$(System.PullRequest.TargetBranchName)'

    if ($scope.NothingToDo) { Write-Host "No Fabric changes detected." }
    elseif ($scope.AllWorkspaces) { Write-Host "Full deploy required." }
    else { Write-Host "Affected workspaces: $($scope.WorkspaceFilter -join ', ')" }

.EXAMPLE
    # Main deploy pipeline — compare against previous commit
    $scope = & Get-DeploymentScope.ps1 `
        -Environment dev `
        -ConfigPath "$RepoRoot/fabric-cicd/config/environments/dev.json" `
        -RepoRoot $RepoRoot `
        -BaseRef 'HEAD~1'

.NOTES
    Phase 5. No Fabric API calls. Requires git on PATH.
    Called by Deploy-FabricEnvironment.ps1 (auto-scope mode) and by the PR pipeline.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('dev', 'tst', 'prd')]
    [string]$Environment,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf }, ErrorMessage = "Config file not found: {0}")]
    [string]$ConfigPath,

    [Parameter()]
    [string]$RepoRoot,

    [Parameter()]
    [string]$BaseRef = 'origin/main',

    [Parameter()]
    [string]$FabricCicdRoot = 'fabric-cicd'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Helper ────────────────────────────────────────────────────────────────────
function New-ScopeResult {
    param([bool]$NothingToDo, [bool]$AllWorkspaces, [string[]]$WorkspaceFilter = @())
    return [PSCustomObject]@{
        NothingToDo     = $NothingToDo
        AllWorkspaces   = $AllWorkspaces
        WorkspaceFilter = $WorkspaceFilter
    }
}

# ── Resolve repo root ─────────────────────────────────────────────────────────
if (-not $RepoRoot) {
    $RepoRoot = if ($env:SYSTEM_DEFAULTWORKINGDIRECTORY) {
        $env:SYSTEM_DEFAULTWORKINGDIRECTORY
    } else {
        (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    }
}

# ── 1. Run git diff ───────────────────────────────────────────────────────────
Write-PSFMessage -Level Verbose -Message "  Running: git diff --name-only $BaseRef HEAD"

Push-Location $RepoRoot
try {
    $gitOutput   = git diff --name-only $BaseRef HEAD 2>&1
    $gitExitCode = $LASTEXITCODE
} finally {
    Pop-Location
}

if ($gitExitCode -ne 0 -or -not $gitOutput) {
    Write-PSFMessage -Level Warning -Message "  Git diff failed or returned no output (exit $gitExitCode). Falling back to full deploy."
    return New-ScopeResult -NothingToDo $false -AllWorkspaces $true
}

# Normalise separators to forward-slash, drop empty lines
$changedFiles = @($gitOutput |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { $_.Trim().Replace('\', '/') })

Write-PSFMessage -Level Verbose -Message "  Changed files ($($changedFiles.Count)): $($changedFiles -join ', ')"

if ($changedFiles.Count -eq 0) {
    Write-PSFMessage -Level Host -Message "  No files changed. Nothing to deploy."
    return New-ScopeResult -NothingToDo $true -AllWorkspaces $false
}

# ── 2. Shared config change → full deploy ─────────────────────────────────────
$sharedPrefixes = @(
    "$FabricCicdRoot/config/shared/",
    "$FabricCicdRoot/config/schemas/",
    "$FabricCicdRoot/src/",           # script changes → full re-test
    "$FabricCicdRoot/pipelines/"      # pipeline YAML changes
)

foreach ($prefix in $sharedPrefixes) {
    $hit = $changedFiles | Where-Object { $_.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) }
    if ($hit) {
        Write-PSFMessage -Level Host -Message "  Shared/infrastructure change detected ($($hit[0])). Full deploy required."
        return New-ScopeResult -NothingToDo $false -AllWorkspaces $true
    }
}

# ── 3. Load current config ────────────────────────────────────────────────────
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json -Depth 20
$affectedWorkspaces = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

# ── 4. Env JSON changed → JSON-diff workspace entries ─────────────────────────
$envConfigRelPath = "$FabricCicdRoot/config/environments/$Environment.json"

$envFileChanged = $changedFiles |
    Where-Object { $_ -like "*$envConfigRelPath" -or $_ -eq $envConfigRelPath }

if ($envFileChanged) {
    Write-PSFMessage -Level Verbose -Message "  Env config changed. Performing workspace-level JSON diff."

    Push-Location $RepoRoot
    try {
        $oldContent  = git show "${BaseRef}:${envConfigRelPath}" 2>&1
        $oldExitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    if ($oldExitCode -ne 0 -or -not $oldContent) {
        # File is new (no old version) or git show failed → full deploy
        Write-PSFMessage -Level Warning -Message "  Cannot retrieve old env config (new file or detached HEAD). Full deploy."
        return New-ScopeResult -NothingToDo $false -AllWorkspaces $true
    }

    try {
        $oldConfig = $oldContent | ConvertFrom-Json -Depth 20
    } catch {
        Write-PSFMessage -Level Warning -Message "  Old env config is invalid JSON. Full deploy."
        return New-ScopeResult -NothingToDo $false -AllWorkspaces $true
    }

    # Top-level fields (capacityName, etc.) changed → full deploy
    $oldTopJson = ($oldConfig | Select-Object -ExcludeProperty workspaces) |
                    ConvertTo-Json -Depth 5 -Compress
    $newTopJson = ($config    | Select-Object -ExcludeProperty workspaces) |
                    ConvertTo-Json -Depth 5 -Compress
    if ($oldTopJson -ne $newTopJson) {
        Write-PSFMessage -Level Host -Message "  Top-level env config fields changed. Full deploy."
        return New-ScopeResult -NothingToDo $false -AllWorkspaces $true
    }

    foreach ($wsConfig in $config.workspaces) {
        $wsName = $wsConfig.name
        $oldWs  = $oldConfig.workspaces | Where-Object { $_.name -eq $wsName }

        if (-not $oldWs) {
            # New workspace added
            Write-PSFMessage -Level Verbose -Message "    New workspace detected: $wsName"
            $affectedWorkspaces.Add($wsName) | Out-Null
        } else {
            $newJson = $wsConfig | ConvertTo-Json -Depth 20 -Compress
            $oldJson = $oldWs   | ConvertTo-Json -Depth 20 -Compress
            if ($newJson -ne $oldJson) {
                Write-PSFMessage -Level Verbose -Message "    Workspace config changed: $wsName"
                $affectedWorkspaces.Add($wsName) | Out-Null
            }
        }
    }
}

# ── 5. Artifact files changed → map to workspaces ────────────────────────────
foreach ($workspaceConfig in $config.workspaces) {
    $wsName          = $workspaceConfig.name
    $items           = $workspaceConfig.items
    $referencedPaths = [System.Collections.Generic.List[string]]::new()

    # Collect all definitionPath values across all item types
    foreach ($nb in @($items.notebooks        | Where-Object { $_ -and $_.definitionPath })) {
        $referencedPaths.Add($nb.definitionPath) | Out-Null
    }
    foreach ($pl in @($items.dataPipelines    | Where-Object { $_ -and $_.definitionPath })) {
        $referencedPaths.Add($pl.definitionPath) | Out-Null
    }
    foreach ($sjd in @($items.sparkJobDefinitions | Where-Object { $_ -and $_.definitionPath })) {
        $referencedPaths.Add($sjd.definitionPath) | Out-Null
    }

    foreach ($refPath in $referencedPaths) {
        # Normalise: strip leading slash, ensure forward-slashes
        $normalized = $refPath.TrimStart('/').TrimStart('\').Replace('\', '/')

        $hit = $changedFiles | Where-Object { $_ -like "$normalized/*" -or $_ -eq $normalized }
        if ($hit) {
            Write-PSFMessage -Level Verbose -Message "  Artifact change maps to workspace '$wsName': $($hit[0])"
            $affectedWorkspaces.Add($wsName) | Out-Null
        }
    }
}

# ── 6. Return result ──────────────────────────────────────────────────────────
if ($affectedWorkspaces.Count -eq 0) {
    Write-PSFMessage -Level Host -Message "  No Fabric workspace changes detected for '$Environment'. Nothing to deploy."
    return New-ScopeResult -NothingToDo $true -AllWorkspaces $false
}

$sortedFilter = @($affectedWorkspaces | Sort-Object)
Write-PSFMessage -Level Host -Message "  Affected workspace(s): $($sortedFilter -join ', ')"
return New-ScopeResult -NothingToDo $false -AllWorkspaces $false -WorkspaceFilter $sortedFilter
