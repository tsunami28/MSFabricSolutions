#Requires -Version 7.0

<#
.SYNOPSIS
    Generates a fab deploy configuration YAML (and optional parameter file) for
    a single Fabric workspace.

.DESCRIPTION
    Produces the per-workspace config file consumed by 'fab deploy --config <file>'.
    The generated config maps a local source directory to a target workspace ID.
    Optionally writes a separate parameter file for find/replace substitutions.

    Output files are written to a temp directory and callers are responsible
    for cleaning them up (e.g. with Remove-Item after deployment).

    fab deploy config structure reference:
      https://microsoft.github.io/fabric-cli/commands/fs/deploy/

.NOTES
    Dot-sourced by Deploy-Items.ps1. Not a standalone script.
#>

# =============================================================================
function New-FabDeployConfig {
<#
.SYNOPSIS
    Writes a fab deploy YAML config (and optional parameter file) for one workspace.

.PARAMETER WorkspaceName
    Display name of the workspace (used in log messages only).

.PARAMETER WorkspaceId
    GUID of the target Fabric workspace. Required by fab deploy.

.PARAMETER RepositoryDirectory
    Absolute path to the directory containing Fabric item files
    (Fabric Git Integration folder structure).

.PARAMETER ItemTypesInScope
    Optional list of item types to include (e.g. @('Notebook','DataPipeline')).
    When null or empty, all supported types in repository_directory are deployed.

.PARAMETER FindReplace
    Optional array of [hashtable] with 'find_value' and 'replace_value' keys.
    Passed as a find_replace parameter file to fab deploy.

.PARAMETER OutputDirectory
    Directory in which to write the generated YAML files.
    Defaults to a system temp directory.

.OUTPUTS
    [PSCustomObject] with:
      ConfigPath     [string] - path to the generated fab deploy config YAML
      ParameterPath  [string] - path to the generated parameter file (or $null)

.EXAMPLE
    $generated = New-FabDeployConfig `
        -WorkspaceName      'Analytics-Dev' `
        -WorkspaceId        '12345678-1234-1234-1234-123456789abc' `
        -RepositoryDirectory 'C:\repo\artifacts\Analytics-Dev.Workspace' `
        -ItemTypesInScope   @('Notebook','DataPipeline') `
        -FindReplace        @(@{ find_value = 'PLACEHOLDER'; replace_value = 'actual-value' })

    # Run fab deploy using generated config
    fab deploy --config $generated.ConfigPath -f
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceName,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string]$WorkspaceId,

        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Container }, ErrorMessage = "repository_directory not found: {0}")]
        [string]$RepositoryDirectory,

        [Parameter()]
        [string[]]$ItemTypesInScope = @(),

        [Parameter()]
        [object[]]$FindReplace = @(),

        [Parameter()]
        [string]$OutputDirectory = $env:TEMP
    )

    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force -ErrorAction SilentlyContinue

    $safeWsName = $WorkspaceName -replace '[^A-Za-z0-9_-]', '_'
    $configPath = Join-Path $OutputDirectory "fab-deploy-${safeWsName}.yml"
    $paramPath  = $null

    # ── Build parameter file (find_replace) ────────────────────────────────────
    if ($FindReplace -and $FindReplace.Count -gt 0) {
        $paramPath = Join-Path $OutputDirectory "fab-params-${safeWsName}.yml"

        $findReplaceLines = foreach ($entry in $FindReplace) {
            "  - find_value: `"$($entry.find_value)`""
            "    replace_value: `"$($entry.replace_value)`""
        }

        $paramContent = @"
find_replace:
$($findReplaceLines -join "`n")
"@
        Set-Content -Path $paramPath -Value $paramContent -Encoding UTF8
        Write-Verbose "Generated fab parameter file: $paramPath"
    }

    # ── Build deploy config ────────────────────────────────────────────────────
    $repoDir = $RepositoryDirectory.Replace('\', '/')

    $itemTypeLines = ''
    if ($ItemTypesInScope -and $ItemTypesInScope.Count -gt 0) {
        $typeEntries = $ItemTypesInScope | ForEach-Object { "  - $_" }
        $itemTypeLines = "item_types_in_scope:`n$($typeEntries -join "`n")"
    }

    $parameterLine = ''
    if ($paramPath) {
        $paramPathEscaped = $paramPath.Replace('\', '/')
        $parameterLine = "parameter: `"$paramPathEscaped`""
    }

    $configContent = @"
core:
  workspace_id: "$WorkspaceId"
  repository_directory: "$repoDir"
$(if ($itemTypeLines) { "  $itemTypeLines" })
$(if ($parameterLine) { "  $parameterLine" })
"@

    Set-Content -Path $configPath -Value $configContent.Trim() -Encoding UTF8
    Write-Verbose "Generated fab deploy config: $configPath"

    return [PSCustomObject]@{
        ConfigPath    = $configPath
        ParameterPath = $paramPath
    }
}
