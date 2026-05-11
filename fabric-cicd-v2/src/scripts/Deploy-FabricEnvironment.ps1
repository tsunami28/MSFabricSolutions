#Requires -Version 7.0

<#
.SYNOPSIS
    Main orchestrator for deploying Microsoft Fabric resources using Fabric CLI.

.DESCRIPTION
    Reads a YAML environment config and provisions/configures Fabric resources
    in the target environment. Safe to re-run - all operations are idempotent.

    Deployment order (respects dependency chain):
        1. Authenticate  - fab auth login (service principal or managed identity)
        2. Workspaces    - create/update workspaces, assign to capacity
        3. Items         - deploy item definitions via 'fab deploy'
        4. Security      - configure workspace RBAC role assignments

    Authentication methods (mutually exclusive):
      Service principal:   -ClientId / -ClientSecret / -TenantId
      Managed identity:    -UseManagedIdentity (optionally -ClientId for user-assigned)

.PARAMETER ConfigFile
    Path to the environment YAML parameter file.
    Example: config/environments/dev.yml

.PARAMETER Environment
    Target environment name. Must match the 'environment' field in the config.
    Valid values: dev | tst | prd

.PARAMETER ClientId
    Entra application (client) ID. Used for service principal or user-assigned MI auth.

.PARAMETER ClientSecret
    Client secret for service principal authentication.

.PARAMETER TenantId
    Azure AD Tenant ID. Required for service principal authentication.

.PARAMETER UseManagedIdentity
    Authenticate using the system-assigned managed identity of the build agent.

.PARAMETER Scope
    Controls which deployment phases run.
    Valid values: all | workspaces | items | security
    Default: all

.PARAMETER RepoRoot
    Absolute path to the repository root. Used to resolve relative
    repository_directory paths in the config. Defaults to the ADO
    $(Build.SourcesDirectory) or the repo root inferred from script location.

.EXAMPLE
    # Service principal - typical for Azure DevOps pipelines
    .\Deploy-FabricEnvironment.ps1 `
        -ConfigFile  'config/environments/dev.yml' `
        -Environment 'dev' `
        -ClientId    '$(CLIENT_ID)' `
        -ClientSecret '$(CLIENT_SECRET)' `
        -TenantId    '$(TENANT_ID)'

.EXAMPLE
    # System-assigned managed identity
    .\Deploy-FabricEnvironment.ps1 `
        -ConfigFile         'config/environments/prd.yml' `
        -Environment        'prd' `
        -UseManagedIdentity
#>
[CmdletBinding(DefaultParameterSetName = 'ServicePrincipal')]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf }, ErrorMessage = "Config file not found: {0}")]
    [string]$ConfigFile,

    [Parameter(Mandatory)]
    [ValidateSet('dev', 'tst', 'prd')]
    [string]$Environment,

    # ── Service principal auth ─────────────────────────────────────────────────
    [Parameter(Mandatory, ParameterSetName = 'ServicePrincipal')]
    [ValidateNotNullOrEmpty()]
    [string]$ClientId,

    [Parameter(Mandatory, ParameterSetName = 'ServicePrincipal')]
    [ValidateNotNullOrEmpty()]
    [string]$ClientSecret,

    [Parameter(Mandatory, ParameterSetName = 'ServicePrincipal')]
    [ValidateNotNullOrEmpty()]
    [string]$TenantId,

    # ── Managed identity auth ──────────────────────────────────────────────────
    [Parameter(Mandatory, ParameterSetName = 'ManagedIdentity')]
    [switch]$UseManagedIdentity,

    [Parameter(ParameterSetName = 'ManagedIdentity')]
    [string]$ManagedIdentityClientId,  # user-assigned MI only; omit for system-assigned

    # ── Deployment control ─────────────────────────────────────────────────────
    [Parameter()]
    [ValidateSet('all', 'workspaces', 'items', 'security', 'privatelinks')]
    [string]$Scope = 'all',

    [Parameter()]
    [string]$RepoRoot = '',

    # ── Private link infrastructure ────────────────────────────────────────────
    [Parameter()]
    [string]$TemplateFile = '',

    [Parameter()]
    [string]$ResourceGroupName = '',

    [Parameter()]
    [string]$SubscriptionId = '',

    [Parameter()]
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Resolve paths ──────────────────────────────────────────────────────────────
$scriptsRoot = $PSScriptRoot
$helpersRoot = Join-Path $scriptsRoot '../helpers'

# Repository root: ADO variable → inferred from script location → current dir
if (-not $RepoRoot) {
    $RepoRoot = if ($env:BUILD_SOURCESDIRECTORY) {
        $env:BUILD_SOURCESDIRECTORY
    } else {
        (Resolve-Path (Join-Path $scriptsRoot '../../..')).Path
    }
}

# Artifacts staging (for logs/validation)
$artifactsDir = if ($env:BUILD_ARTIFACTSTAGINGDIRECTORY) {
    $env:BUILD_ARTIFACTSTAGINGDIRECTORY
} else {
    Join-Path ([System.IO.Path]::GetTempPath()) 'fabric-cicd-v2-artifacts'
}
$null = New-Item -ItemType Directory -Path $artifactsDir -Force -ErrorAction SilentlyContinue

# ── Dot-source helpers ─────────────────────────────────────────────────────────
. (Join-Path $helpersRoot 'Invoke-FabCli.ps1')
. (Join-Path $helpersRoot 'Read-EnvironmentConfig.ps1')

# ── Banner ─────────────────────────────────────────────────────────────────────
Write-Host ('=' * 70)
Write-Host "  fabric-cicd v2 - Deployment Started"
Write-Host ('=' * 70)
Write-Host "  Environment  : $Environment"
Write-Host "  Config File  : $ConfigFile"
Write-Host "  Scope        : $Scope"
Write-Host "  Auth Method  : $($PSCmdlet.ParameterSetName)"
Write-Host "  Repo Root    : $RepoRoot"
Write-Host ('=' * 70)

# ── 1. Authenticate ────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[1/4] Authenticating to Microsoft Fabric..."

try {
    # ADO agents lack a keyring/DPAPI backend - enable plaintext token cache fallback
    Invoke-FabCli -Arguments @('config', 'set', 'encryption_fallback_enabled', 'true') -MaxRetries 0 | Out-Null

    if ($UseManagedIdentity) {
        $loginArgs = @('auth', 'login', '--identity')
        if ($ManagedIdentityClientId) {
            $loginArgs += @('-u', $ManagedIdentityClientId)
        }
    } else {
        $loginArgs = @('auth', 'login', '-u', $ClientId, '-p', $ClientSecret, '--tenant', $TenantId)
    }

    Invoke-FabCli -Arguments $loginArgs -MaxRetries 0 | Out-Null
    Write-Host "  Authentication successful."
} catch {
    Write-Host "##vso[task.logissue type=error]Fabric CLI authentication failed: $_"
    throw
}

# ── 2. Read & validate config ──────────────────────────────────────────────────
Write-Host ""
Write-Host "[2/4] Reading configuration: $ConfigFile"

$config = Read-EnvironmentConfig -ConfigPath $ConfigFile

if ($config.environment -ne $Environment) {
    throw "Config environment '$($config.environment)' does not match target '$Environment'."
}

Write-Host "  Workspaces to process : $($config.workspaces.Count)"

# ── 3. Deploy workspaces ───────────────────────────────────────────────────────
$workspaceMap = @{}

if ($Scope -in @('all', 'workspaces')) {
    Write-Host ""
    Write-Host "[3/4] Deploying workspaces..."
    $workspaceMap = & (Join-Path $scriptsRoot 'Deploy-Workspaces.ps1') `
        -Config      $config `
        -Environment $Environment
} else {
    Write-Host ""
    Write-Host "[3/4] Skipping workspaces (scope: $Scope). Resolving existing workspace IDs..."

    # Resolve IDs for workspaces even when workspace step is skipped
    foreach ($ws in $config.workspaces) {
        $idResult = Invoke-FabCli -Arguments @('get', "$($ws.name).Workspace", '-q', 'id') -AllowNonZeroExit
        if ($idResult.ExitCode -eq 0 -and $idResult.Output) {
            $wsId = $idResult.Output
            if ($wsId -is [string]) { $wsId = $wsId.Trim('"').Trim() }
            $workspaceMap[$ws.name] = $wsId
        } else {
            Write-Warning "  Workspace '$($ws.name)' not found - it will be skipped for items/security."
        }
    }
}

# ── 4. Deploy items ────────────────────────────────────────────────────────────
if ($Scope -in @('all', 'items')) {
    Write-Host ""
    Write-Host "[4a/4] Deploying items..."
    & (Join-Path $scriptsRoot 'Deploy-Items.ps1') `
        -Config       $config `
        -WorkspaceMap $workspaceMap `
        -Environment  $Environment `
        -RepoRoot     $RepoRoot
} else {
    Write-Host ""
    Write-Host "[4a/4] Skipping item deployment (scope: $Scope)."
}

# ── 5. Deploy security ─────────────────────────────────────────────────────────
if ($Scope -in @('all', 'security')) {
    Write-Host ""
    Write-Host "[4b/4] Configuring security (RBAC)..."
    & (Join-Path $scriptsRoot 'Deploy-Security.ps1') `
        -Config       $config `
        -WorkspaceMap $workspaceMap `
        -Environment  $Environment
} else {
    Write-Host ""
    Write-Host "[4b/4] Skipping security (scope: $Scope)."
}

# ── 6. Export workspace map for downstream pipeline tasks ────────────────────
# Private links deployment now runs as a separate AzurePowerShell@5 pipeline task.
# Export the workspace map so that task can consume it.
$workspaceMapFile = Join-Path $artifactsDir 'workspace-map.json'
$workspaceMap | ConvertTo-Json -Depth 5 | Set-Content -Path $workspaceMapFile -Encoding utf8
Write-Host ""
Write-Host "[5/5] Workspace map exported to: $workspaceMapFile"
# Expose as ADO pipeline variable so subsequent tasks can reference the path
Write-Host "##vso[task.setvariable variable=WorkspaceMapFile;isOutput=true]$workspaceMapFile"

# ── Summary ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host ('=' * 70)
Write-Host "  Deployment Complete"
Write-Host "  Environment : $Environment"
Write-Host "  Workspaces  : $($workspaceMap.Count) processed"
Write-Host ('=' * 70)
