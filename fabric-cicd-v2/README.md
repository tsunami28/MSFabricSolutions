# fabric-cicd-v2

A PowerShell + [Fabric CLI](https://microsoft.github.io/fabric-cli/) solution for deploying Microsoft Fabric resources (workspaces, items, RBAC, and private link infrastructure) across dev → tst → prd environments via Azure DevOps pipelines.

---

## Contents

- [fabric-cicd-v2](#fabric-cicd-v2)
  - [Contents](#contents)
  - [Overview](#overview)
  - [Prerequisites](#prerequisites)
  - [Repository structure](#repository-structure)
  - [How it works](#how-it-works)
  - [Configuration](#configuration)
    - [Environment config](#environment-config)
    - [Private links config](#private-links-config)
    - [Capacity reference](#capacity-reference)
    - [Item source files](#item-source-files)
    - [Infrastructure parameters](#infrastructure-parameters)
  - [Authentication](#authentication)
    - [Service principal (recommended for pipelines)](#service-principal-recommended-for-pipelines)
    - [Managed identity (self-hosted agents)](#managed-identity-self-hosted-agents)
  - [Running locally](#running-locally)
  - [Azure DevOps setup](#azure-devops-setup)
    - [1. External repository resource](#1-external-repository-resource)
    - [2. Variable group](#2-variable-group)
    - [3. ADO Environments](#3-ado-environments)
    - [4. Pipeline](#4-pipeline)
  - [Deployment scope](#deployment-scope)
  - [Extending the solution](#extending-the-solution)

---

## Overview

fabric-cicd-v2 automates the full Fabric deployment lifecycle using the `fab` Fabric CLI and Azure Bicep as the engines:

| Phase | What happens |
|---|---|
| **Infrastructure** | Deploys Fabric capacity and Key Vault via Bicep (`deploy-capacity.yml` template) |
| **Workspaces** | Creates workspaces that don't exist; updates descriptions on existing ones; assigns to the configured Fabric capacity |
| **Items** | Runs `fab deploy` to publish item definitions from a local Git-Integration folder to the target workspace |
| **Security** | Applies workspace RBAC role assignments (and removes entries marked `remove: true`) using `fab acl set/rm` |
| **Private Links** | Deploys Private Link Services (PLS) and Private Endpoints (PE) for workspaces that have `privateLink` config defined |
| **Validate** | Post-deployment checks that all workspaces and roles exist; results published to the ADO Tests tab as NUnit XML |

All operations are **idempotent** - safe to re-run multiple times without side effects.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Python 3.10+ | Required by ms-fabric-cli |
| `ms-fabric-cli` | `pip install ms-fabric-cli` |
| PowerShell 7.0+ | pwsh |
| `powershell-yaml` module | `Install-Module powershell-yaml -Scope CurrentUser` |
| `Az` PowerShell module | Required for Private Link and infrastructure deployments |
| Fabric service principal | Needs Fabric Admin or workspace-scoped permissions |
| Azure service connection | For Bicep-based infrastructure and PLS/PE deployments |

Check your installation:

```bash
fab --version
pwsh --version
```

---

## Repository structure

```
fabric-cicd-v2/
│
├── config/
│   ├── environments/
│   │   ├── dev.yml          # Dev environment - workspaces, items, roles, private links
│   │   ├── tst.yml          # Test environment
│   │   └── prd.yml          # Production environment
│   └── shared/
│       └── capacities.yml   # Capacity name → GUID reference (informational)
│
├── parameters/
│   └── <project>/
│       └── <region>/
│           ├── dev/
│           │   ├── deployFabricCapacity.param.jsonc   # Bicep params for Fabric capacity
│           │   └── deployFabricKeyVault.param.jsonc   # Bicep params for Key Vault
│           ├── tst/
│           └── prd/
│
├── pipelines/
│   ├── deploy-fabric.yml                       # Main ADO pipeline
│   └── templates/
│       ├── install-prerequisites.yml           # pip + pwsh module install
│       ├── deploy-capacity.yml                 # Infrastructure (Capacity + Key Vault) via Bicep
│       ├── deploy-environment.yml              # Fabric deploy + private links step
│       └── validate-deployment.yml             # Validate + publish NUnit results
│
└── src/
    ├── helpers/
    │   ├── Invoke-FabCli.ps1                  # fab wrapper with retry and JSON parsing
    │   ├── Read-EnvironmentConfig.ps1         # YAML config loader and validator
    │   └── New-FabDeployConfig.ps1            # Generates fab deploy YAML configs
    └── scripts/
        ├── Deploy-FabricEnvironment.ps1       # Main orchestrator (entry point)
        ├── Deploy-Workspaces.ps1              # Workspace create/update
        ├── Deploy-Items.ps1                   # Item deployment via fab deploy
        ├── Deploy-Security.ps1                # RBAC role assignments
        ├── Deploy-PrivateLinks.ps1            # PLS + PE deployment via Bicep
        └── Validate-Deployment.ps1            # Post-deployment validation
```

---

## How it works

```
deploy-fabric.yml (ADO pipeline)
 │
 ├── deploy-capacity.yml (per env)       ← Bicep: Fabric Capacity + Key Vault
 │    └── AzurePowerShell@5 → New-AzResourceGroupDeployment
 │
 ├── Validate stage                      ← config syntax check (Read-EnvironmentConfig)
 │
 └── Deploy_<env> stages (per env)
      │
      ├── install-prerequisites.yml      ← pip install ms-fabric-cli + powershell-yaml
      │
      ├── deploy-environment.yml
      │    │
      │    ├── Deploy-FabricEnvironment.ps1 (orchestrator)
      │    │    │
      │    │    ├── fab auth login            ← service principal or managed identity
      │    │    │
      │    │    ├── Read-EnvironmentConfig    ← parse & validate dev.yml / tst.yml / prd.yml
      │    │    │
      │    │    ├── Deploy-Workspaces.ps1
      │    │    │    ├── fab exists <ws>.Workspace
      │    │    │    ├── fab mkdir <ws>.Workspace -P capacityname=<cap>   (if new)
      │    │    │    ├── fab set <ws>.Workspace -q description ...        (if existing)
      │    │    │    └── fab get <ws>.Workspace -q id → exports workspace-map.json
      │    │    │
      │    │    ├── Deploy-Items.ps1
      │    │    │    ├── New-FabDeployConfig → writes fab-deploy-<ws>.yml + fab-params-<ws>.yml
      │    │    │    └── fab deploy --config fab-deploy-<ws>.yml -f
      │    │    │
      │    │    └── Deploy-Security.ps1
      │    │         ├── fab acl get <ws>.Workspace --output_format json
      │    │         ├── fab acl set <ws>.Workspace -I <objectId> -R <role> -f   (add/update)
      │    │         └── fab acl rm  <ws>.Workspace -I <objectId> -f             (remove)
      │    │
      │    └── Deploy-PrivateLinks.ps1 (AzurePowerShell@5 task)
      │         ├── Reads workspace-map.json for workspace GUIDs
      │         └── New-AzResourceGroupDeployment → PLS + PE Bicep template
      │
      └── validate-deployment.yml
           ├── Validate-Deployment.ps1 → NUnit XML output
           └── PublishTestResults@2 → ADO Tests tab
```

---

## Configuration

### Environment config

Each environment has a YAML file in `config/environments/`. The file defines all workspaces, their item source directories, parameterization rules, desired RBAC state, and optional private link configuration.

```yaml
environment: dev                      # dev | tst | prd
capacityName: MyFabricCapacity-Dev    # default Fabric capacity for all workspaces

# ── Private Link Infrastructure (optional) ─────────────────────────────────────
# See "Private links config" section below for details.
privateLinks:
  tenantId: "00000000-0000-0000-0000-000000000000"
  subscriptionId: "00000000-0000-0000-0000-000000000000"
  subnetId: "/subscriptions/.../subnets/FabricDevSubnet"
  privateDnsZoneId: "/subscriptions/.../privateDnsZones/privatelink.fabric.microsoft.com"
  location: westeurope
  resourceGroupName: my-fabric-dev-rsg

workspaces:
  - name: Analytics-Dev
    description: Analytics development workspace
    capacityOverride: null            # optional: per-workspace capacity override

    items:
      # Path relative to repo root using Fabric Git Integration structure
      repository_directory: artifacts/Analytics-Dev.Workspace

      # Optional: limit which item types are deployed (omit to deploy all)
      item_types_in_scope:
        - Notebook
        - DataPipeline
        - Lakehouse
        - Warehouse

      # Optional: find/replace substitutions applied to all deployed item definitions
      parameters:
        find_replace:
          - find_value: "PLACEHOLDER_LAKEHOUSE_ID"
            replace_value: "00000000-0000-0000-0000-000000000000"
          - find_value: "PLACEHOLDER_SQL_ENDPOINT"
            replace_value: "dev-server.datawarehouse.fabric.microsoft.com"

    roles:
      # identity must be an Entra Object ID (GUID) - not a UPN or email address
      - identity: "00000000-0000-0000-0000-000000000001"
        principalType: Group          # Group | User | ServicePrincipal (informational)
        role: Contributor             # Admin | Member | Contributor | Viewer

      # Set remove: true to explicitly revoke an existing assignment
      - identity: "00000000-0000-0000-0000-000000000099"
        principalType: User
        role: Member
        remove: true

    # Optional: Private Link Service + Private Endpoint for this workspace
    privateLink:
      plsName: my-fabric-dev-analytics-pls
      peResourceName: my-fabric-dev-analytics
```

**Key rules:**
- `identity` must be an **Entra Object ID (GUID)**. The `fab acl` commands require object IDs, not UPNs or display names.
- RBAC is **additive by default** - roles present in Fabric but absent from the config are not removed unless `remove: true` is set.
- `repository_directory` must follow the [Fabric Git Integration folder structure](https://learn.microsoft.com/fabric/cicd/git-integration/git-integration-process) - `<item-name>.<ItemType>/` subdirectories with `.platform` files.

### Private links config

Private Link deployment is **optional**. When configured, it provisions Azure Private Link Services (PLS) and Private Endpoints (PE) for Fabric workspaces, enabling secure connectivity over a private network.

**Top-level `privateLinks` section** (shared settings for all workspaces in the environment):

| Field | Required | Description |
|---|---|---|
| `tenantId` | Yes | Azure AD tenant ID for the deployment |
| `subscriptionId` | Yes | Azure subscription hosting the networking resources |
| `subnetId` | Yes | Full resource ID of the subnet where PLS/PE will be created |
| `privateDnsZoneId` | Yes | Full resource ID of the `privatelink.fabric.microsoft.com` DNS zone |
| `location` | Yes | Azure region (e.g. `westeurope`) |
| `resourceGroupName` | No | Can be passed via config or `-ResourceGroupName` parameter |

**Per-workspace `privateLink` block:**

| Field | Required | Description |
|---|---|---|
| `plsName` | Yes | Name for the Private Link Service resource |
| `peResourceName` | No | Name for the Private Endpoint resource |

The `Deploy-PrivateLinks.ps1` script:
1. Reads the workspace-map JSON (exported by Deploy-FabricEnvironment.ps1) to resolve workspace GUIDs
2. Builds a parameters object for all workspaces with `privateLink` config
3. Deploys via `New-AzResourceGroupDeployment` using a Bicep template (provided via `-TemplateFile`)
4. Supports `-WhatIfMode` for validation without changes

> **Note:** This step runs inside an `AzurePowerShell@5` task and requires an Azure service connection with permissions to deploy resources to the target resource group.

### Capacity reference

`config/shared/capacities.yml` maps environment names to capacity names and GUIDs. This file is **informational only** - the Fabric CLI resolves capacity names directly and does not require GUIDs.

To find capacity names and GUIDs in your tenant:

```bash
fab ls /.capacities -la --output_format json
```

### Item source files

Items are stored in the Fabric Git Integration format. Export them from Fabric directly or author them manually:

```
artifacts/
└── Analytics-Dev.Workspace/
    ├── SalesNotebook.Notebook/
    │   ├── .platform
    │   └── notebook-content.py
    └── IngestPipeline.DataPipeline/
        ├── .platform
        └── pipeline-content.json
```

The `.platform` file contains the item's logical ID used by `fab deploy` for dependency resolution between items.

### Infrastructure parameters

The `parameters/` directory contains Bicep parameter files for infrastructure deployments (Fabric Capacity, Key Vault). These are organized by project and region:

```
parameters/
└── <project-code>/
    └── <region>/
        ├── dev/
        │   ├── deployFabricCapacity.param.jsonc
        │   └── deployFabricKeyVault.param.jsonc
        ├── tst/
        └── prd/
```

These parameter files are consumed by the `deploy-capacity.yml` pipeline template, which invokes `New-AzResourceGroupDeployment` with the corresponding Bicep templates from the external `sources` repository.

---

## Authentication

### Service principal (recommended for pipelines)

Register a service principal in Entra ID and grant it Fabric workspace permissions. The service principal needs **Member or Admin** on each workspace it creates, or **Fabric Administrator** to create workspaces.

```powershell
.\src\scripts\Deploy-FabricEnvironment.ps1 `
    -ConfigFile   'config/environments/dev.yml' `
    -Environment  'dev' `
    -ClientId     '<appId>' `
    -ClientSecret '<secret>' `
    -TenantId     '<tenantId>'
```

### Managed identity (self-hosted agents)

```powershell
.\src\scripts\Deploy-FabricEnvironment.ps1 `
    -ConfigFile         'config/environments/dev.yml' `
    -Environment        'dev' `
    -UseManagedIdentity
```

For a **user-assigned** managed identity, also pass `-ClientId <miClientId>`.

---

## Running locally

1. Install prerequisites:

   ```bash
   pip install ms-fabric-cli --upgrade
   Install-Module powershell-yaml -Scope CurrentUser -Force
   ```

2. Authenticate:

   ```bash
   fab auth login -u <clientId> -p <clientSecret> --tenant <tenantId>
   # or for interactive login:
   fab auth login
   ```

3. Run the orchestrator from the repository root:

   ```powershell
   .\fabric-cicd-v2\src\scripts\Deploy-FabricEnvironment.ps1 `
       -ConfigFile  'fabric-cicd-v2\config\environments\dev.yml' `
       -Environment 'dev' `
       -ClientId    '<appId>' `
       -ClientSecret '<secret>' `
       -TenantId    '<tenantId>'
   ```

4. (Optional) Run post-deployment validation:

   ```powershell
   .\fabric-cicd-v2\src\scripts\Validate-Deployment.ps1 `
       -ConfigFile  'fabric-cicd-v2\config\environments\dev.yml' `
       -Environment 'dev'
   ```

---

## Azure DevOps setup

### 1. External repository resource

The pipeline references an external Azure DevOps repository (`ccoe/sources`) for shared Bicep templates (Fabric Capacity, Key Vault, workspace infrastructure). Configure this in your ADO project:

1. Ensure the `ccoe/sources` repository exists in the same Azure DevOps organization and contains:
   - `infrastructure-as-code/mainTemplates/deployFabricCapacity.bicep`
   - `infrastructure-as-code/mainTemplates/deployFabricKeyVault.bicep`
   - `infrastructure-as-code/mainTemplates/deployFabricWorkspaceInfra.bicep`
2. The pipeline resource is declared as:
   ```yaml
   resources:
     repositories:
       - repository: sources
         type: git
         name: ccoe/sources
         ref: refs/heads/main
   ```
3. Grant the pipeline's build service account read access to the `ccoe/sources` repository.

> **Note:** If your Bicep templates live in the same repo, adjust the `resources` block and template paths in `deploy-fabric.yml` accordingly.

### 2. Variable group

Create a single variable group in ADO Library:

| Group | Variable | Description |
|---|---|---|
| `project-variables` | `connectedServiceName` | Azure service connection for Bicep deployments |
| `project-variables` | `fabricTenantId` | Azure AD tenant ID |
| `project-variables` | `subscriptionId` | Azure subscription ID |
| `project-variables` | `necp01-dev-fdev-spn-appId` | Dev service principal client ID |
| `project-variables` | `necp01-dev-fdev-spn-secret` | Dev service principal secret (**mark as secret**) |
| `project-variables` | `necp01-tst-fdev-spn-appId` | Tst service principal client ID |
| `project-variables` | `necp01-tst-fdev-spn-secret` | Tst service principal secret (**mark as secret**) |
| `project-variables` | `necp01-prd-fdev-spn-appId` | Prd service principal client ID |
| `project-variables` | `necp01-prd-fdev-spn-secret` | Prd service principal secret (**mark as secret**) |
| `project-variables` | `devResourceGroupName` | Resource group for dev PLS/PE |
| `project-variables` | `tstResourceGroupName` | Resource group for tst PLS/PE |
| `project-variables` | `prdResourceGroupName` | Resource group for prd PLS/PE |
| `project-variables` | `fdevServiceName` | Dev Fabric service name (for capacity template) |
| `project-variables` | `ftstServiceName` | Tst Fabric service name |
| `project-variables` | `fprdServiceName` | Prd Fabric service name |
| `project-variables` | `templateFile` | Path to the workspace infra Bicep template |

### 3. ADO Environments

Create three environments in ADO (Project Settings → Environments):

| Environment | Approval gate |
|---|---|
| `fabric-dev` | None (auto-deploys on merge to main) |
| `fabric-tst` | Optional - add approvers as needed |
| `fabric-prd` | **Required** - add approvers before production deploys |

### 4. Pipeline

Create a new pipeline in ADO pointing to `fabric-cicd-v2/pipelines/deploy-fabric.yml`.

The pipeline supports the following runtime parameters:

| Parameter | Default | Description |
|---|---|---|
| `devOpsManagedPoolUse` | `true` | Use a managed DevOps agent pool |
| `devOpsAgentImage` | `ubuntu-latest` | Agent image when not using managed pool |
| `whatIf` | `false` | Run in What-If mode (validation only, no changes) |
| `deployDev` | `true` | Deploy dev environment |
| `deployTst` | `false` | Deploy tst environment |
| `deployPrd` | `false` | Deploy prd environment |

**Triggers:**

- **CI:** On changes to `fabric-cicd-v2/config/**` or `fabric-cicd-v2/src/**` on `main`
- **Scheduled:** Daily at 05:00 UTC

**Pipeline stages:**

```
Deploy Infrastructure (dev/tst/prd)    ← Capacity + Key Vault via Bicep
         │
    Validate Configs                   ← YAML syntax + schema check
         │
    Deploy Dev                         ← Fabric CLI: workspaces → items → security → PLS/PE
         │
    Deploy Tst (gated)                 ← same phases
         │
    Deploy Prd (gated)                 ← same phases
```

---

## Deployment scope

The `-Scope` parameter on `Deploy-FabricEnvironment.ps1` restricts which phases run. Useful for targeted re-runs:

| Value | Phases executed |
|---|---|
| `all` (default) | Workspaces → Items → Security |
| `workspaces` | Workspace create/update only |
| `items` | Item deployment only (workspaces must already exist) |
| `security` | RBAC only (workspaces must already exist) |
| `privatelinks` | Private Link deployment only (workspaces must already exist; requires Az context) |

Example - re-apply RBAC only:

```powershell
.\Deploy-FabricEnvironment.ps1 -ConfigFile ... -Environment prd -Scope security ...
```

Example - deploy private links with What-If:

```powershell
.\Deploy-PrivateLinks.ps1 `
    -ConfigFile       'config/environments/dev.yml' `
    -WorkspaceMapFile 'workspace-map.json' `
    -TemplateFile     'path/to/deployFabricWorkspaceInfra.bicep' `
    -ResourceGroupName 'my-fabric-dev-rsg' `
    -WhatIfMode
```

---

## Extending the solution

The following capabilities are deferred to a future release:

- **Connections** - deploying data source connections
- **Shortcuts** - OneLake shortcut management
- **Drift detection** - detecting and reporting configuration drift without applying changes
- **Dry-run mode** - previewing what would change before applying (partially addressed by `-WhatIf` / What-If pipeline parameter)
- **Git-based scoping** - deploying only items changed in a specific commit range

To add a new environment (e.g. `uat`):

1. Duplicate one of the environment YAML files in `config/environments/`; update the `environment` field, workspace names, and private link names
2. Add corresponding infrastructure parameter files under `parameters/<project>/<region>/uat/`
3. Add the environment's service principal credentials to the `project-variables` variable group
4. Create a `fabric-uat` ADO environment with desired approval gates
5. Add stages to `deploy-fabric.yml` - one `deploy-capacity.yml` invocation and one `Deploy_Uat` stage using the `deploy-environment.yml` template
