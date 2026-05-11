# fabric-cicd-v2

A PowerShell + [Fabric CLI](https://microsoft.github.io/fabric-cli/) solution for deploying Microsoft Fabric resources (workspaces, items, and RBAC) across dev → tst → prd environments via Azure DevOps pipelines.

---

## Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Repository structure](#repository-structure)
- [How it works](#how-it-works)
- [Configuration](#configuration)
  - [Environment config](#environment-config)
  - [Capacity reference](#capacity-reference)
  - [Item source files](#item-source-files)
- [Authentication](#authentication)
- [Running locally](#running-locally)
- [Azure DevOps setup](#azure-devops-setup)
- [Deployment scope](#deployment-scope)
- [Extending the solution](#extending-the-solution)

---

## Overview

fabric-cicd-v2 automates the full Fabric deployment lifecycle using the `fab` Fabric CLI as the engine:

| Phase | What happens |
|---|---|
| **Workspaces** | Creates workspaces that don't exist; updates descriptions on existing ones; assigns to the configured Fabric capacity |
| **Items** | Runs `fab deploy` to publish item definitions from a local Git-Integration folder to the target workspace |
| **Security** | Applies workspace RBAC role assignments (and removes entries marked `remove: true`) using `fab acl set/rm` |
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
| Fabric service principal | Needs Fabric Admin or workspace-scoped permissions |

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
│   │   ├── dev.yml          # Dev environment - workspaces, items, roles
│   │   ├── tst.yml          # Test environment
│   │   └── prd.yml          # Production environment
│   └── shared/
│       └── capacities.yml   # Capacity name → GUID reference (informational)
│
├── pipelines/
│   ├── deploy-fabric.yml                       # Main ADO pipeline (4 stages)
│   └── templates/
│       ├── install-prerequisites.yml           # pip + pwsh module install
│       ├── deploy-environment.yml              # Reusable deploy step
│       └── validate-deployment.yml            # Reusable validate + publish step
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
        └── Validate-Deployment.ps1            # Post-deployment validation
```

---

## How it works

```
Deploy-FabricEnvironment.ps1 (orchestrator)
 │
 ├── fab auth login               ← service principal or managed identity
 │
 ├── Read-EnvironmentConfig       ← parse & validate dev.yml / tst.yml / prd.yml
 │
 ├── Deploy-Workspaces.ps1
 │    ├── fab exists <ws>.Workspace
 │    ├── fab mkdir <ws>.Workspace -P capacityname=<cap>   (if new)
 │    ├── fab set <ws>.Workspace -q description ...        (if existing)
 │    └── fab get <ws>.Workspace -q id → returns name→GUID map
 │
 ├── Deploy-Items.ps1
 │    ├── New-FabDeployConfig  → writes fab-deploy-<ws>.yml + fab-params-<ws>.yml
 │    └── fab deploy --config fab-deploy-<ws>.yml -f
 │
 ├── Deploy-Security.ps1
 │    ├── fab acl get <ws>.Workspace --output_format json
 │    ├── fab acl set <ws>.Workspace -I <objectId> -R <role> -f   (add/update)
 │    └── fab acl rm  <ws>.Workspace -I <objectId> -f             (remove)
 │
 └── Validate-Deployment.ps1
      ├── fab exists <ws>.Workspace  (per workspace)
      ├── fab acl get <ws>.Workspace  (per workspace with roles)
      └── writes NUnit XML → $(Build.ArtifactStagingDirectory)/validation-<env>/
```

---

## Configuration

### Environment config

Each environment has a YAML file in `config/environments/`. The file defines all workspaces, their item source directories, parameterization rules, and desired RBAC state.

```yaml
environment: dev                      # dev | tst | prd
capacityName: FabricCapacity-Dev      # default Fabric capacity for all workspaces

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
```

**Key rules:**
- `identity` must be an **Entra Object ID (GUID)**. The `fab acl` commands require object IDs, not UPNs or display names.
- RBAC is **additive by default** - roles present in Fabric but absent from the config are not removed unless `remove: true` is set.
- `repository_directory` must follow the [Fabric Git Integration folder structure](https://learn.microsoft.com/fabric/cicd/git-integration/git-integration-process) - `<item-name>.<ItemType>/` subdirectories with `.platform` files.

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

### 1. Variable groups (ADO Library)

Create four variable groups in ADO Library:

| Group | Variable | Value |
|---|---|---|
| `vg-fabric-common` | `agentPoolName` | Agent pool name (e.g. `ubuntu-latest`) |
| `vg-fabric-common` | `fabricTenantId` | Azure AD tenant ID |
| `vg-fabric-dev` | `clientId` | Service principal client ID |
| `vg-fabric-dev` | `clientSecret` | Service principal secret (**mark as secret**) |
| `vg-fabric-tst` | `clientId` | (same keys, different values) |
| `vg-fabric-tst` | `clientSecret` | |
| `vg-fabric-prd` | `clientId` | |
| `vg-fabric-prd` | `clientSecret` | |

### 2. ADO Environments

Create three environments in ADO (Project Settings → Environments):

| Environment | Approval gate |
|---|---|
| `fabric-dev` | None (auto-deploys on merge to main) |
| `fabric-tst` | Optional - add approvers as needed |
| `fabric-prd` | **Required** - add approvers before production deploys |

### 3. Pipeline

Create a new pipeline in ADO pointing to `fabric-cicd-v2/pipelines/deploy-fabric.yml`.

The pipeline triggers on any change under `fabric-cicd-v2/**` on the `main` branch and runs four stages in sequence:

```
Validate ──► Deploy Dev ──► Deploy Tst ──► Deploy Prd
                              (gate)        (gate)
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

Example - re-apply RBAC only:

```powershell
.\Deploy-FabricEnvironment.ps1 -ConfigFile ... -Environment prd -Scope security ...
```

---

## Extending the solution

The following capabilities are deferred to a future v2.1 release:

- **Connections** - deploying data source connections
- **Shortcuts** - OneLake shortcut management
- **Drift detection** - detecting and reporting configuration drift without applying changes
- **Dry-run mode** - previewing what would change before applying
- **Git-based scoping** - deploying only items changed in a specific commit range

To add a new environment (e.g. `uat`), duplicate one of the environment YAML files, update the `environment` field and workspace names, add the corresponding ADO variable group and environment, and add a stage to `deploy-fabric.yml`.
