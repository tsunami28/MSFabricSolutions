---
name: fabric-add-deployment-phase
description: 'Scaffold a new deployment phase for fabric-cicd-v2. Use when adding a new Deploy- script, implementing Log Analytics, implementing VNet Data Gateway, adding workspace networking policy, creating a new deployment feature, extending the orchestrator, or adding a new scope value. Guides coordinated changes across config schema, scripts, orchestrator, validation, and pipeline templates.'
---

# Add a New Deployment Phase

Multi-file workflow for adding a new deployment capability to fabric-cicd-v2. Each deployment phase requires coordinated changes across 5-7 files.

## Checklist

When adding a new deployment phase (e.g., networking, gateways, Log Analytics):

1. [ ] **Design doc** — create `docs/<feature>-plan.md`
2. [ ] **Config schema** — add YAML block to environment config
3. [ ] **Config validation** — update `Read-EnvironmentConfig.ps1`
4. [ ] **Deployment script** — create `src/scripts/Deploy-<Feature>.ps1`
5. [ ] **Orchestrator integration** — update `Deploy-FabricEnvironment.ps1`
6. [ ] **Validation tests** — update `Validate-Deployment.ps1`
7. [ ] **Pipeline template** — update `deploy-environment.yml` (and `deploy-fabric.yml` if new scope)

## Step 1: Design Doc

Create `docs/<feature-name>-plan.md` before writing code. Include:

- Feature description and motivation
- Fabric CLI commands or REST API endpoints needed
- Config schema additions
- Idempotency strategy (how to converge to desired state)
- Error scenarios and recovery
- Prerequisites (Azure resources, permissions, etc.)

See existing examples: `docs/log-analytics-plan.md`, `docs/vnet-data-gateway-plan.md`, `docs/workspace-networking-plan.md`.

## Step 2: Config Schema Extension

Add a new block to the environment YAML schema. Two patterns:

### Top-Level Block (shared across all workspaces)

```yaml
# config/environments/dev.yml
environment: dev
capacityName: my-capacity
newFeature:                    # ← new top-level block
  setting1: value
  setting2: value
workspaces: [...]
```

### Per-Workspace Block (workspace-specific settings)

```yaml
workspaces:
  - name: MyWorkspace
    newFeature:                # ← new per-workspace block
      enabled: true
      setting1: value
```

Choose based on whether the feature applies globally or per-workspace.

## Step 3: Config Validation

Update `src/helpers/Read-EnvironmentConfig.ps1` to validate the new block.

Follow the existing validation pattern:

```powershell
# Validate new top-level block (if present)
if ($config.PSObject.Properties.Name -contains 'newFeature') {
    $nf = $config.newFeature
    if (-not ($nf.PSObject.Properties.Name -contains 'setting1')) {
        throw "newFeature.setting1 is required when newFeature block is present."
    }
}

# Validate per-workspace block
foreach ($ws in $config.workspaces) {
    if ($ws.PSObject.Properties.Name -contains 'newFeature') {
        # validate fields...
    }
}
```

Key patterns:
- Use `$obj.PSObject.Properties.Name -contains 'field'` to check optional fields
- Throw descriptive errors with field path (e.g., `"workspaces[$i].newFeature.setting1"`)
- Validate types and allowed values

## Step 4: Deployment Script

Create `src/scripts/Deploy-<Feature>.ps1` following the established template:

```powershell
#Requires -Version 7.0

<#
.SYNOPSIS
    Idempotently deploys <Feature> for Fabric workspaces.

.DESCRIPTION
    For each workspace in the config that has a '<feature>' block:
      - Checks current state via 'fab ...' or 'fab api'
      - Compares against desired state from config
      - Creates/updates to converge to desired state
      - Skips workspaces without the feature block

    Called by Deploy-FabricEnvironment.ps1. Assumes 'fab auth login' has
    already been called in the same shell session.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [PSCustomObject]$Config,

    [Parameter(Mandatory)]
    [hashtable]$WorkspaceMap,

    [Parameter(Mandatory)]
    [ValidateSet('dev', 'tst', 'prd')]
    [string]$Environment
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$helpersRoot = Join-Path $PSScriptRoot '../helpers'
. (Join-Path $helpersRoot 'Invoke-FabCli.ps1')

foreach ($workspaceConfig in $Config.workspaces) {
    $wsName = $workspaceConfig.name

    # Skip if feature not configured
    $hasFeature = $workspaceConfig.PSObject.Properties.Name -contains 'newFeature'
    if (-not $hasFeature) {
        Write-Verbose "  No <feature> config for: $wsName"
        continue
    }

    if (-not $WorkspaceMap.ContainsKey($wsName)) {
        Write-Warning "  Workspace '$wsName' not in workspace map. Skipping."
        continue
    }

    Write-Host "  Configuring <feature> for: $wsName"
    $wsId = $WorkspaceMap[$wsName]

    # ── Check current state ────────────────────────────────────────────────
    # Use fab api, fab get, or fab exists depending on the feature

    # ── Converge to desired state ──────────────────────────────────────────
    # Create, update, or skip based on comparison
}
```

### Script Conventions

- `#Requires -Version 7.0` at top
- `Set-StrictMode -Version Latest` + `$ErrorActionPreference = 'Stop'`
- Dot-source `Invoke-FabCli.ps1` from helpers
- Accept `$Config`, `$WorkspaceMap`, `$Environment` parameters
- Iterate workspaces, skip those without the feature block
- All operations must be **idempotent**
- Use `Write-Host` for progress, `Write-Verbose` for debug, `Write-Warning` for non-fatal

### Choosing Between `fab` Commands and `fab api`

- **`fab` subcommands** (mkdir, deploy, acl) — use when a dedicated command exists
- **`fab api -X GET/PUT/PATCH`** — use for Fabric REST API or Power BI Admin API when no dedicated command exists
- **`-A powerbi`** — required for Power BI Admin API endpoints (e.g., Log Analytics)
- **`-A fabric`** (default) — Fabric API endpoints

## Step 5: Orchestrator Integration

Update `src/scripts/Deploy-FabricEnvironment.ps1`:

### Add to Scope Parameter

```powershell
[ValidateSet('all', 'workspaces', 'items', 'security', 'privatelinks', 'newfeature')]
[string]$Scope = 'all',
```

### Add Deployment Step

Insert after the appropriate dependency in the execution order:

```powershell
# ── N. Deploy <Feature> ───────────────────────────────────────────────────
if ($Scope -in @('all', 'newfeature')) {
    Write-Host ""
    Write-Host "[N/M] Deploying <feature>..."
    & (Join-Path $scriptsRoot 'Deploy-NewFeature.ps1') `
        -Config      $config `
        -WorkspaceMap $workspaceMap `
        -Environment $Environment
} else {
    Write-Host ""
    Write-Host "[N/M] Skipping <feature> (scope: $Scope)"
}
```

### Execution Order Dependencies

Current order: Auth → Workspaces → Items → Security → Private Links → Validate

- Features needing workspace GUIDs: **after** Workspaces
- Features needing items deployed: **after** Items
- Features needing Azure resources: use `AzurePowerShell@5` task type in pipeline
- Infrastructure features (Bicep): may need a separate pipeline step

## Step 6: Validation Tests

Add checks to `src/scripts/Validate-Deployment.ps1`:

```powershell
# ── Validate <Feature> ─────────────────────────────────────────────────────
foreach ($ws in $config.workspaces) {
    if ($ws.PSObject.Properties.Name -contains 'newFeature') {
        $wsName = $ws.name
        # Verify feature is configured correctly
        # Add test result to NUnit XML output
    }
}
```

## Step 7: Pipeline Template Updates

### Update Scope Values in `deploy-environment.yml`

```yaml
- name: scope
  type: string
  default: "all"
  values: [all, workspaces, items, security, privatelinks, newfeature]
```

### If Feature Needs Azure Context

If the feature calls Azure APIs (Bicep, ARM, Azure PowerShell), it needs `AzurePowerShell@5` instead of `PowerShell@2`:

```yaml
- task: AzurePowerShell@5
  displayName: 'Deploy <Feature>'
  inputs:
    azureSubscription: ${{ parameters.connectedServiceName }}
    ScriptType: FilePath
    ScriptPath: $(Build.SourcesDirectory)/src/scripts/Deploy-NewFeature.ps1
    ScriptArguments: >-
      -ConfigFile '$(Build.SourcesDirectory)/${{ parameters.configFile }}'
      -Environment '${{ parameters.environment }}'
    azurePowerShellVersion: LatestVersion
```

## Planned Features (Design Docs Exist)

Three features have design documents but are not yet implemented:

| Feature | Doc | Key Complexity |
|---------|-----|----------------|
| **Log Analytics** | `docs/log-analytics-plan.md` | Two-phase: Bicep LAW + Power BI Admin API (`-A powerbi`). Requires `Tenant.ReadWrite.All`. |
| **VNet Data Gateway** | `docs/vnet-data-gateway-plan.md` | New resource type `.gateways/`. Subnet delegation prereq. Member scaling. |
| **Workspace Networking** | `docs/workspace-networking-plan.md` | REST API only (`fab api`). Full JSON body for PUT. Inbound/outbound rules. |
