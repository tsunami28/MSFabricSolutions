#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'MicrosoftFabricMgmt'; ModuleVersion = '1.0.8' }
#Requires -Modules @{ ModuleName = 'PSFramework'; ModuleVersion = '1.12.0' }

<#
.SYNOPSIS
    Main orchestrator for deploying Microsoft Fabric resources from parameter files.

.DESCRIPTION
    Reads a JSON parameter file and provisions/configures Fabric resources in the
    target environment. Supports idempotent deployment - safe to re-run at any time.

    Deployment order (respects dependency chain):
        1. Workspaces      - create/update workspaces, assign to capacity
        2. Items           - lakehouses, warehouses, notebooks, pipelines, environments
        3. Security        - workspace RBAC role assignments

    Auth flow:
        The AzurePowerShell@5 task pre-calls Connect-AzAccount using the ADO service
        connection linked to the environment's User-Assigned Managed Identity.
        This script calls Set-FabricApiHeaders to obtain a Fabric API token from
        the established Az.Accounts session - no credentials are passed explicitly.

.PARAMETER ConfigFile
    Absolute or relative path to the environment JSON parameter file.
    Example: config/environments/dev.json

.PARAMETER Environment
    Target environment name. Must match the 'environment' field in the config file.
    Valid values: dev | tst | prd

.PARAMETER TenantId
    Azure AD Tenant ID. Supplied via $(fabricTenantId) from the ADO variable group.

.PARAMETER ManagedIdentityClientId
    Client ID of the User-Assigned Managed Identity for this environment.
    Supplied via $(managedIdentityClientId) from the ADO variable group.

.PARAMETER Scope
    Controls which deployment steps run.
    Valid values: all | workspaces | connections | items | pipeline-definitions | spark-job-definitions | security
    Default: all

.PARAMETER DryRun
    When True, logs all planned changes without creating or modifying any resources.
    In dry-run mode a 'dry-run-summary.json' file is written to the artifacts staging
    directory for use by the PR comment template.

.PARAMETER WorkspaceFilter
    Optional list of workspace names to deploy. When supplied, all step scripts skip
    workspaces whose name is not in this list. Empty array (default) = deploy all.

.PARAMETER AutoScope
    When True, calls Get-DeploymentScope.ps1 automatically to compute the WorkspaceFilter
    from git diff before running any deployment steps. Ignored when WorkspaceFilter is
    explicitly provided. Default: False.

.EXAMPLE
    # Run from an AzurePowerShell@5 task (auth pre-established by task):
    .\Deploy-FabricEnvironment.ps1 `
        -ConfigFile 'config/environments/dev.json' `
        -Environment 'dev' `
        -TenantId '00000000-0000-0000-0000-000000000000' `
        -ManagedIdentityClientId '11111111-1111-1111-1111-111111111111'

.EXAMPLE
    # Dry-run for prod:
    .\Deploy-FabricEnvironment.ps1 `
        -ConfigFile 'config/environments/prd.json' `
        -Environment 'prd' `
        -TenantId '...' `
        -ManagedIdentityClientId '...' `
        -DryRun $true
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf }, ErrorMessage = "Config file not found: {0}")]
    [string]$ConfigFile,

    [Parameter(Mandatory)]
    [ValidateSet('dev', 'tst', 'prd')]
    [string]$Environment,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ManagedIdentityClientId,

    [Parameter()]
    [ValidateSet('all', 'workspaces', 'connections', 'items', 'pipeline-definitions', 'spark-job-definitions', 'security')]
    [string]$Scope = 'all',

    [Parameter()]
    [bool]$DryRun = $false,

    [Parameter()]
    [string[]]$WorkspaceFilter = @(),

    [Parameter()]
    [bool]$AutoScope = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Resolve paths ─────────────────────────────────────────────────────────────
$scriptsRoot  = $PSScriptRoot
$helpersRoot  = Join-Path $scriptsRoot '../helpers'
$artifactsDir = if ($env:BUILD_ARTIFACTSTAGINGDIRECTORY) {
    $env:BUILD_ARTIFACTSTAGINGDIRECTORY
} else {
    Join-Path $env:TEMP 'fabric-cicd-artifacts'
}
$logDir = Join-Path $artifactsDir "validation-$Environment"
$null   = New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue

# ── PSFramework logging ────────────────────────────────────────────────────────
Set-PSFLoggingProvider -Name logfile `
    -FilePath (Join-Path $logDir 'fabric-deploy.log') `
    -Enabled $true `
    -ErrorAction SilentlyContinue

Write-PSFMessage -Level Host -Message ("=" * 70)
Write-PSFMessage -Level Host -Message "Fabric Deployment Started"
Write-PSFMessage -Level Host -Message ("=" * 70)
Write-PSFMessage -Level Host -Message "  Environment              : $Environment"
Write-PSFMessage -Level Host -Message "  Config File              : $ConfigFile"
Write-PSFMessage -Level Host -Message "  Scope                    : $Scope"
Write-PSFMessage -Level Host -Message "  Dry Run                  : $DryRun"
Write-PSFMessage -Level Host -Message "  Auto Scope               : $AutoScope"
Write-PSFMessage -Level Host -Message "  MI Client ID             : $ManagedIdentityClientId"
Write-PSFMessage -Level Host -Message ("=" * 70)

# ── Dot-source helpers ─────────────────────────────────────────────────────────
. (Join-Path $helpersRoot 'Invoke-FabricRestMethod.ps1')

# ── 1. Authenticate ────────────────────────────────────────────────────────────
Write-PSFMessage -Level Host -Message "Authenticating to Microsoft Fabric..."

try {
    Set-FabricApiHeaders `
        -TenantId $TenantId `
        -UseManagedIdentity `
        -ManagedIdentityId $ManagedIdentityClientId

    Write-PSFMessage -Level Host -Message "  Authentication successful."
} catch {
    Write-PSFMessage -Level Error -Message "Authentication failed: $_"
    Write-Host "##vso[task.logissue type=error]Fabric authentication failed: $_"
    throw
}

# ── 2. Read & validate configuration ──────────────────────────────────────────
Write-PSFMessage -Level Host -Message "Reading configuration: $ConfigFile"

$config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json -Depth 20

if ($config.environment -and $config.environment -ne $Environment) {
    throw "Config file environment '$($config.environment)' does not match target '$Environment'."
}

Write-PSFMessage -Level Host -Message "  Workspaces to process: $($config.workspaces.Count)"

# ── 3. Load capacity map ───────────────────────────────────────────────────────
$capacityMap = @{}

$capacitiesFile = Join-Path $scriptsRoot '../../config/shared/capacities.json'
if (Test-Path $capacitiesFile) {
    $capacitiesData = Get-Content $capacitiesFile -Raw | ConvertFrom-Json
    $envCapacities  = $capacitiesData.$Environment

    if ($envCapacities) {
        foreach ($prop in $envCapacities.PSObject.Properties) {
            $capacityMap[$prop.Name] = $prop.Value
        }
        Write-PSFMessage -Level Verbose -Message "Loaded $($capacityMap.Count) capacity mapping(s) for '$Environment'."
    }
}

# ── 4. Build execution plan ────────────────────────────────────────────────────
# Repository root - resolves definitionPath values in Deploy-PipelineDefinitions.ps1
$repoRoot = if ($env:SYSTEM_DEFAULTWORKINGDIRECTORY) {
    $env:SYSTEM_DEFAULTWORKINGDIRECTORY
} else {
    # Local dev: scripts/ → src/ → fabric-cicd/ → repo-root
    (Resolve-Path (Join-Path $scriptsRoot '../../..')).Path
}

# ── 4a. Workspace scope detection ────────────────────────────────────────────
$resolvedWorkspaceFilter = $WorkspaceFilter

if ($WorkspaceFilter.Count -eq 0 -and $AutoScope) {
    Write-PSFMessage -Level Host -Message "Auto-scope: detecting affected workspaces via git diff..."
    $scopeScript = Join-Path $scriptsRoot 'Get-DeploymentScope.ps1'
    $scopeResult = & $scopeScript `
        -Environment $Environment `
        -ConfigPath  $ConfigFile `
        -RepoRoot    $repoRoot

    if ($scopeResult.NothingToDo) {
        Write-PSFMessage -Level Host -Message "Auto-scope: no Fabric changes detected. Deployment skipped."
        Write-Host "##vso[task.setvariable variable=fabricNothingToDo]true"

        # Write a dry-run summary so the PR comment template has something to report
        if ($DryRun) {
            $summaryPath = Join-Path $logDir 'dry-run-summary.json'
            @{ nothingToDo = $true; environment = $Environment; workspaces = @() } |
                ConvertTo-Json -Depth 5 | Set-Content $summaryPath -Encoding UTF8
        }
        return
    }

    if (-not $scopeResult.AllWorkspaces) {
        $resolvedWorkspaceFilter = $scopeResult.WorkspaceFilter
        Write-PSFMessage -Level Host -Message "Auto-scope: deploying $($resolvedWorkspaceFilter.Count) workspace(s): $($resolvedWorkspaceFilter -join ', ')"
    } else {
        Write-PSFMessage -Level Host -Message "Auto-scope: full deploy required."
    }
}

if ($resolvedWorkspaceFilter.Count -gt 0) {
    Write-PSFMessage -Level Host -Message "  Workspace filter active  : $($resolvedWorkspaceFilter -join ', ')"
}

$executionOrder = if ($Scope -eq 'all') {
    # Order matters: workspaces first, connections before items (external shortcuts need them),
    # items before pipeline-definitions and spark-job-definitions (items must exist before definitions are uploaded)
    @('workspaces', 'connections', 'items', 'pipeline-definitions', 'spark-job-definitions', 'security')
} else {
    @($Scope)
}

$deployScripts = @{
    workspaces               = Join-Path $scriptsRoot 'Deploy-Workspaces.ps1'
    connections              = Join-Path $scriptsRoot 'Deploy-Connections.ps1'
    items                    = Join-Path $scriptsRoot 'Deploy-Items.ps1'
    'pipeline-definitions'   = Join-Path $scriptsRoot 'Deploy-PipelineDefinitions.ps1'
    'spark-job-definitions'  = Join-Path $scriptsRoot 'Deploy-SparkJobDefinitions.ps1'
    security                 = Join-Path $scriptsRoot 'Deploy-Security.ps1'
}

# ── 5. Execute deployment steps ───────────────────────────────────────────────
$results       = [System.Collections.Generic.List[PSCustomObject]]::new()
$connectionMap = @{}   # populated by 'connections' step; forwarded to 'items' step

foreach ($step in $executionOrder) {
    $scriptPath = $deployScripts[$step]

    if (-not (Test-Path $scriptPath)) {
        Write-PSFMessage -Level Warning -Message "Script not found, skipping step '$step': $scriptPath"
        continue
    }

    Write-PSFMessage -Level Host -Message ""
    Write-PSFMessage -Level Host -Message "--- Step: $step ---"

    $stepParams = @{
        Config          = $config
        CapacityMap     = $capacityMap
        Environment     = $Environment
        DryRun          = $DryRun
        WorkspaceFilter = $resolvedWorkspaceFilter
    }

    # Step-specific additional parameters
    switch ($step) {
        'items'                { $stepParams['ConnectionMap'] = $connectionMap }
        'pipeline-definitions' { $stepParams['RepoRoot']      = $repoRoot      }
        'spark-job-definitions'{ $stepParams['RepoRoot']      = $repoRoot      }
    }

    try {
        $stepResult = & $scriptPath @stepParams

        # Capture connection name→ID map returned by Deploy-Connections.ps1
        if ($step -eq 'connections' -and $stepResult -is [hashtable]) {
            $connectionMap = $stepResult
            Write-PSFMessage -Level Verbose -Message "  Captured connection map: $($connectionMap.Count) entry/entries."
        }

        $results.Add([PSCustomObject]@{
            Step    = $step
            Status  = 'Succeeded'
            Details = $stepResult
        })

        Write-PSFMessage -Level Host -Message "  Step '$step' completed successfully."

    } catch {
        $results.Add([PSCustomObject]@{
            Step    = $step
            Status  = 'Failed'
            Error   = $_.Exception.Message
        })

        Write-PSFMessage -Level Error -Message "  Step '$step' failed: $($_.Exception.Message)"
        Write-Host "##vso[task.logissue type=error]Fabric deployment step '$step' failed: $($_.Exception.Message)"
        throw
    }
}

# ── 6. Summary ─────────────────────────────────────────────────────────────────
Write-PSFMessage -Level Host -Message ""
Write-PSFMessage -Level Host -Message ("=" * 70)
Write-PSFMessage -Level Host -Message "Deployment Summary"
Write-PSFMessage -Level Host -Message ("=" * 70)

foreach ($r in $results) {
    $icon = if ($r.Status -eq 'Succeeded') { '[OK]' } else { '[FAIL]' }
    Write-PSFMessage -Level Host -Message "  $icon $($r.Step)"
}

$failedCount = ($results | Where-Object Status -ne 'Succeeded').Count
if ($failedCount -gt 0) {
    throw "Deployment completed with $failedCount failed step(s)."
}

Write-PSFMessage -Level Host -Message ("=" * 70)
Write-PSFMessage -Level Host -Message "Fabric Deployment Complete$(if ($DryRun) { ' [DRY RUN - no changes applied]' })"
Write-PSFMessage -Level Host -Message ("=" * 70)

# ── 7. Write dry-run summary for PR comment template ─────────────────────────
if ($DryRun) {
    $summaryPath = Join-Path $logDir 'dry-run-summary.json'
    $workspaceNames = if ($resolvedWorkspaceFilter.Count -gt 0) {
        $resolvedWorkspaceFilter
    } else {
        @($config.workspaces | ForEach-Object { $_.name })
    }
    @{
        nothingToDo  = $false
        environment  = $Environment
        workspaces   = $workspaceNames
        steps        = @($results | ForEach-Object { @{ step = $_.Step; status = $_.Status } })
        timestamp    = (Get-Date -Format 'o')
    } | ConvertTo-Json -Depth 5 | Set-Content $summaryPath -Encoding UTF8
    Write-PSFMessage -Level Verbose -Message "  Dry-run summary written to: $summaryPath"
}
