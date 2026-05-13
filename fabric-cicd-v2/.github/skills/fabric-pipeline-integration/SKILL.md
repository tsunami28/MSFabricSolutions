---
name: fabric-pipeline-integration
description: 'Azure DevOps pipeline orchestration and cross-component data flow for fabric-cicd-v2. Use when asking about pipeline variables, output variables, workspace-map.json, cross-job references, deployment gates, approval gates, variable groups, PowerShell@2 vs AzurePowerShell@5, pipeline templates, deploy-fabric.yml, deploy-environment.yml, install-prerequisites.yml, ADO environment, stage dependencies, or pipeline secret handling.'
---

# ADO Pipeline Integration & Data Flow

Pipeline orchestration patterns and cross-component data flow in fabric-cicd-v2. Pipelines live in `pipelines/` and use reusable templates in `pipelines/templates/`.

## Pipeline Architecture

### Main Pipeline: `pipelines/deploy-fabric.yml`

```
Trigger: main branch (config/ or src/ changes) + daily 05:00 UTC schedule

Stages:
  ├─ Deploy_Dev_Infrastructure    Bicep: capacity + Key Vault (dev)
  ├─ Deploy_Tst_Infrastructure    Bicep: capacity + Key Vault (tst)
  ├─ Deploy_Prd_Infrastructure    Bicep: capacity + Key Vault (prd)
  ├─ Validate                     Config syntax check (all envs)
  ├─ Deploy_Dev                   Fabric deployment (auto, no gate)
  │     └─ depends on: Deploy_Dev_Infrastructure, Validate
  ├─ Deploy_Tst                   Fabric deployment (optional gate)
  │     └─ depends on: Deploy_Dev
  └─ Deploy_Prd                   Fabric deployment (required gate)
        └─ depends on: Deploy_Tst
```

### Templates

| Template | Purpose | Task Type |
|----------|---------|-----------|
| `install-prerequisites.yml` | Install `ms-fabric-cli` (pip), `powershell-yaml` module | PowerShell@2 |
| `deploy-capacity.yml` | Bicep: Fabric capacity + Key Vault per env | AzurePowerShell@5 |
| `deploy-environment.yml` | Run `Deploy-FabricEnvironment.ps1` + `Deploy-PrivateLinks.ps1` | PowerShell@2 + AzurePowerShell@5 |
| `validate-deployment.yml` | Run `Validate-Deployment.ps1`, publish NUnit XML | PowerShell@2 |

## Task Type Selection

### PowerShell@2

Use for scripts that only call `fab` CLI (already authenticated):

```yaml
- task: PowerShell@2
  displayName: 'Deploy Fabric Environment'
  inputs:
    targetType: filePath
    filePath: $(Build.SourcesDirectory)/src/scripts/Deploy-FabricEnvironment.ps1
    arguments: >-
      -ConfigFile '$(Build.SourcesDirectory)/config/environments/dev.yml'
      -Environment 'dev'
      -ClientId '$(FAB_CLIENT_ID)'
      -ClientSecret '$(FAB_CLIENT_SECRET)'
      -TenantId '$(TENANT_ID)'
    pwsh: true
```

### AzurePowerShell@5

Use for scripts that call Azure APIs (Bicep deployment, ARM, Az module):

```yaml
- task: AzurePowerShell@5
  displayName: 'Deploy Private Links'
  inputs:
    azureSubscription: ${{ parameters.connectedServiceName }}
    ScriptType: FilePath
    ScriptPath: $(Build.SourcesDirectory)/src/scripts/Deploy-PrivateLinks.ps1
    ScriptArguments: >-
      -WorkspaceMapPath '$(WorkspaceMapPath)'
      -TemplateFile '${{ parameters.templateFile }}'
      -ResourceGroupName '${{ parameters.resourceGroupName }}'
    azurePowerShellVersion: LatestVersion
```

**Rule of thumb:** If the script needs `Az.Resources`, `New-AzResourceGroupDeployment`, or Azure service connections → `AzurePowerShell@5`. Otherwise → `PowerShell@2`.

## Data Flow Between Stages

### Workspace Map Handoff

The critical cross-component data: workspace name → GUID mapping.

```
Deploy-Workspaces.ps1
  ├─ Creates/resolves workspaces
  ├─ Returns $workspaceMap hashtable in-process
  └─ Writes workspace-map.json to artifacts directory

Deploy-FabricEnvironment.ps1
  ├─ Receives $workspaceMap from Deploy-Workspaces return value
  ├─ Passes to Deploy-Items, Deploy-Security
  └─ Sets ADO output variable with file path

Deploy-PrivateLinks.ps1 (separate task)
  └─ Reads workspace-map.json from file path (cross-task)
```

### Setting Output Variables

```powershell
# In Deploy-FabricEnvironment.ps1:
$mapPath = Join-Path $artifactsDir 'workspace-map.json'
$workspaceMap | ConvertTo-Json | Set-Content -Path $mapPath
Write-Host "##vso[task.setvariable variable=WorkspaceMapPath;isOutput=true]$mapPath"
```

**Requirements for output variables:**
- The task must have a `name:` property in YAML (not just `displayName`)
- Use `isOutput=true` to make variable available to downstream tasks/jobs

### Consuming Output Variables

```yaml
# Same job — reference by task name
- script: echo $(deployFabric.WorkspaceMapPath)

# Different job — use dependencies syntax
variables:
  wsMapPath: $[dependencies.DeployJob.outputs['deployFabric.WorkspaceMapPath']]
```

### Cross-Stage References

```yaml
# In a downstream stage
variables:
  wsMapPath: $[stageDependencies.Deploy_Dev.DeployJob.outputs['deployFabric.WorkspaceMapPath']]
```

## Environment Gates

### ADO Environment Configuration

| Environment | Gate | When |
|-------------|------|------|
| `fabric-dev` | None (auto-deploy) | Every merge to main |
| `fabric-tst` | Optional approval | Configurable in ADO |
| `fabric-prd` | **Required approval** | Must be manually approved |

### Deployment Job vs Regular Job

```yaml
# Deployment job — provides environment gates + approval
- deployment: DeployFabric
  environment: fabric-dev
  strategy:
    runOnce:
      deploy:
        steps: [...]

# Regular job — no gates
- job: ValidateConfig
  steps: [...]
```

Use `deployment` jobs for environment-targeted work. Use regular `job` for validation, prerequisites, and infrastructure.

## Variable Groups

### `project-variables` — Shared across all environments

Typically contains:
- Tenant ID
- Subscription IDs (per env or shared)
- Azure service connection names
- Shared resource names

### `fabric-variables` — Fabric-specific secrets

Typically contains:
- `FAB_CLIENT_ID` — deployment SPN client ID
- `FAB_CLIENT_SECRET` — deployment SPN secret (marked secret)
- Capacity names per environment

### Secret Handling

```yaml
# Secrets from variable groups are automatically masked in logs
# Mark custom variables as secret:
Write-Host "##vso[task.setvariable variable=MySecret;issecret=true]$value"
```

- `issecret=true` masks the value in all subsequent log output
- Never `Write-Host` a secret value — it will be masked as `***`
- Pass secrets via parameters, not environment variables when possible

## Pipeline Parameters

```yaml
parameters:
  - name: whatIf
    displayName: Deployment Validation (What-If)
    type: boolean
    default: false
  - name: deployDev / deployTst / deployPrd
    type: boolean
    default: true              # dev/tst default true; prd may default false
  - name: devOpsManagedPoolUse
    type: boolean
    default: true
  - name: devOpsAgentImage
    type: string
    default: "ubuntu-latest"
```

### Conditional Stage Execution

```yaml
- stage: Deploy_Dev
  condition: and(succeeded(), eq('${{ parameters.deployDev }}', true))
```

## Common Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Output variable empty in downstream job | Task missing `name:` property | Add `name: taskName` to the task |
| Secret not masked in logs | Missing `issecret=true` | Add `##vso[task.setvariable variable=X;issecret=true]` |
| `AzurePowerShell@5` auth fails | Wrong service connection name | Check `connectedServiceName` parameter |
| Stage skipped unexpectedly | `condition:` excludes this run | Check parameter values and conditions |
| `fab` not found | Prerequisites step didn't run | Ensure `install-prerequisites.yml` is in the job |
| Cross-stage variable empty | Wrong `stageDependencies` path | Verify stage name, job name, and task name in path |
