---
description: "Create or modify Azure DevOps YAML pipeline definitions and templates for fabric-cicd-v2. Use when adding pipeline stages, templates, or modifying CI/CD workflows."
---

# ADO Pipeline Development

## Pipeline Architecture

```
deploy-fabric.yml (main pipeline)
├── templates/install-prerequisites.yml    # pip + pwsh modules
├── templates/deploy-capacity.yml          # Bicep infrastructure (per env)
├── templates/deploy-environment.yml       # Fabric CLI deployment (per env)
└── templates/validate-deployment.yml      # NUnit validation + publish
```

## Main Pipeline Structure

The main pipeline (`pipelines/deploy-fabric.yml`) uses:
- **Triggers**: Changes to `fabric-cicd-v2/config/**` or `fabric-cicd-v2/src/**` on `main`
- **Schedules**: Daily at 05:00 UTC on `main`
- **Parameters**: `whatIf`, `deployDev`, `deployTst`, `deployPrd`, pool selection
- **Variable Groups**: `project-variables`, `fabric-variables`
- **ADO Environments**: `fabric-dev` (auto), `fabric-tst` (optional gate), `fabric-prd` (required gate)

## Template Pattern

Templates live in `pipelines/templates/` and follow this structure:

```yaml
# template-name.yml
parameters:
  - name: environment
    type: string
    values: [dev, tst, prd]
  - name: configFile
    type: string
    default: ""
  # ... other parameters

steps:
  - task: PowerShell@2
    name: StepName
    displayName: "Step - ${{ parameters.environment }}"
    inputs:
      filePath: "$(Build.SourcesDirectory)/fabric-infra/fabric-cicd-v2/src/scripts/ScriptName.ps1"
      pwsh: true
      arguments: >-
        -Parameter1 "value"
        -Parameter2 "${{ parameters.paramName }}"
```

## Key Conventions

### Path References
- Scripts referenced from: `$(Build.SourcesDirectory)/fabric-infra/fabric-cicd-v2/src/scripts/`
- Config referenced from: `$(Build.SourcesDirectory)/fabric-infra/fabric-cicd-v2/config/environments/`
- Always use `$(Build.SourcesDirectory)` as the base

### Secrets
- Never hardcode secrets in YAML
- Use variable group references: `$(variableName)`
- Pass as template parameters from the main pipeline
- Mark secret variables with `issecret=true` in `##vso[task.setvariable]`

### Conditional Execution
```yaml
${{ if eq(parameters.deployEnabled, true) }}:
  # stage/step content
```

### Pool Selection (Managed DevOps Pool support)
```yaml
pool:
  ${{ if eq(parameters.devOpsManagedPoolUse, true) }}:
    name: ${{ parameters.devOpsPoolName }}
  ${{ else }}:
    vmImage: ${{ parameters.devOpsAgentImage }}
```

### Environment Deployment Pattern
Each environment stage follows:
1. `install-prerequisites.yml` — install `ms-fabric-cli` and `powershell-yaml`
2. `deploy-capacity.yml` — Bicep infrastructure (capacity + Key Vault)
3. `deploy-environment.yml` — Fabric resources (workspaces, items, security, private links)
4. `validate-deployment.yml` — Post-deployment checks with NUnit results

### External Repository Resource
```yaml
resources:
  repositories:
    - repository: sources
      type: git
      name: ccoe/sources
      ref: refs/heads/main
```

## Adding a New Template

1. Create `pipelines/templates/{template-name}.yml`
2. Define parameters with types and defaults
3. Reference from main pipeline using `- template: templates/{template-name}.yml`
4. Pass parameters from the stage level
5. Use `displayName` with environment interpolation for readability
