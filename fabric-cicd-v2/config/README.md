# Environment Configuration Reference

Environments are defined as **split-file directories** under `config/environments/`. Each environment has its own subdirectory (`dev/`, `tst/`, `prd/`) containing:

- `_env.yml` — environment-level settings (required)
- One `<WorkspaceName>.yml` per workspace (at least one required)

Shared settings that are identical across all environments live in `config/shared/`:

- `defaults.yml` — base `privateLinks` values (tenantId, privateDnsZoneId, location)
- `roles-common.yml` — RBAC identities injected into every workspace across all environments

The deployment scripts call `Read-EnvironmentConfig -ConfigPath config/environments/<env>/` which merges all layers and returns the same PSCustomObject structure used by the downstream scripts.

> **New:** `Read-EnvironmentConfig` also supports a parameters-style directory path such as `parameters/necp01/weu/dev/`, where one environment file and one per-workspace file are merged.

> **Legacy:** Passing a monolithic `.yml` file path (e.g. `config/environments/dev.yml`) is still supported for backward compatibility and local testing.

---

## Directory layout

```
config/
├── shared/
│   ├── defaults.yml             # Shared privateLinks base values
│   └── roles-common.yml         # RBAC identities for every workspace
│
└── environments/
    ├── dev/
    │   ├── _env.yml             # Environment settings + gateways
    │   ├── FIN-Core-Dev.yml     # Workspace definition
    │   └── FIN-Reporting-Dev.yml
    ├── tst/
    │   ├── _env.yml
    │   ├── FIN-Core-Tst.yml
    │   └── FIN-Reporting-Tst.yml
    └── prd/
        ├── _env.yml
        └── FIN-Core-Prd.yml
```

### Naming convention

- `_env.yml` — leading underscore marks this as environment-level (not a workspace).
- `<WorkspaceName>.yml` — filename matches the workspace `name` field exactly.

---

## Merge strategy

`Read-EnvironmentConfig` assembles the final config using a layered merge:

```
  shared/defaults.yml           (base)
+ shared/roles-common.yml       (common RBAC, prepended to every workspace)
+ environments/{env}/_env.yml   (env-level overrides + gateways)
+ environments/{env}/*.yml      (per-workspace files, sorted alphabetically)
─────────────────────────────────
= single PSCustomObject          (same shape as the legacy monolithic file)
```

| Section | Merge rule |
|---------|------------|
| `environment`, `capacityName` | Taken from `_env.yml` only. |
| `privateLinks` | `defaults.yml` fields merged with `_env.yml` fields. `_env.yml` wins on conflict. |
| `gateways` | Taken from `_env.yml` only. |
| Workspace `roles` | `roles-common.yml` entries are **prepended** to each workspace's `roles` array. Duplicates (same `identity` + `role`) are deduplicated. Set `skipCommonRoles: true` on a workspace to opt out. |
| All other workspace fields | Taken as-is from the per-workspace YAML file. |

---

## `_env.yml` fields

| Field | Required | Description |
|---|---|---|
| `environment` | Yes | Environment name. Must be `dev`, `tst`, or `prd`. |
| `capacityName` | Yes | Default Fabric capacity name for all workspaces. |
| `privateLinks` | No | Environment-specific overrides merged on top of `shared/defaults.yml`. |
| `gateways` | No | VNet Data Gateway definitions for this environment. |

---

## Per-workspace file fields

Each `<WorkspaceName>.yml` file defines a single workspace. The filename must match the `name` field exactly.

| Field | Required | Description |
|---|---|---|
| `name` | Yes | Workspace display name. Created if it doesn't exist. |
| `description` | No | Workspace description. Updated on every run. |
| `capacityOverride` | No | Override the top-level `capacityName` for this workspace. Set to `null` to use the default. |
| `items` | No | Item deployment configuration. See [Items](#items). |
| `roles` | No | RBAC role assignments (merged with `roles-common.yml`). See [Roles](#roles). |
| `gitIntegration` | No | Git repository connection. Set to `false` to disconnect. See [Git Integration](#git-integration). |
| `privateLink` | No | Per-workspace PLS/PE config. See [Private Links](#privatelinks). |
| `skipCommonRoles` | No | Set `true` to prevent `roles-common.yml` entries from being injected into this workspace's roles. |

---

## Items

The `items:` block controls which Fabric items are deployed to a workspace and how they are parameterized.

### How it works

1. `Deploy-Items.ps1` reads the `items:` block for each workspace
2. `New-FabDeployConfig` generates a `fab deploy` config YAML (and optional parameter file)
3. `fab deploy --config <generated.yml> -f` publishes items to the target workspace

```
items config ──► New-FabDeployConfig() ──► fab-deploy-<ws>.yml ──► fab deploy
                                      └──► fab-params-<ws>.yml ─┘
```

### Fields

### `repository_directory`

| | |
|---|---|
| **Required** | Yes (if `items:` is present) |
| **Type** | String (path) |
| **Description** | Path to the directory containing Fabric item definitions. Relative paths are resolved from the repository root. |

The directory must follow the [Fabric Git Integration folder structure](https://learn.microsoft.com/fabric/cicd/git-integration/git-integration-process):

```
artifacts/FIN-Core-Dev.Workspace/
├── SalesLakehouse.Lakehouse/
│   └── .platform                  ← contains logical ID
├── IngestPipeline.DataPipeline/
│   ├── .platform
│   └── pipeline-content.json
└── TransformNotebook.Notebook/
    ├── .platform
    └── notebook-content.py
```

**Prerequisite:** The directory must exist and contain at least one `<item-name>.<ItemType>/` subdirectory with a `.platform` file. These are typically exported from Fabric via Git Integration.

> **Note:** All environments can point to the **same** source directory (e.g. `artifacts/Analytics-Dev.Workspace`). Environment-specific values are swapped via `find_replace` — the source artifacts act as a single-source-of-truth template.

### `item_types_in_scope`

| | |
|---|---|
| **Required** | No |
| **Type** | List of strings |
| **Default** | All item types found in `repository_directory` |
| **Description** | Allow-list of Fabric item types to deploy. Only items matching these types are included; all others are skipped. |

**Example:**

```yaml
item_types_in_scope:
  - Notebook
  - DataPipeline
  - Lakehouse
```

**How it works:** The list is written into the generated `fab deploy` config:

```yaml
# Generated fab-deploy-FIN-Core-Dev.yml
core:
  workspace_id: "..."
  repository_directory: "..."
  item_types_in_scope:
    - Lakehouse
```

`fab deploy` then only processes `*.Lakehouse/` folders — everything else (e.g. `*.Notebook/`, `*.DataPipeline/`) is ignored.

**Known item type values:**

| Type | Description |
|---|---|
| `Notebook` | Fabric Notebook |
| `DataPipeline` | Data Pipeline |
| `Lakehouse` | Lakehouse |
| `Warehouse` | Data Warehouse |
| `Environment` | Spark Environment definition |
| `SparkJobDefinition` | Spark Job Definition |

This is not exhaustive — any Fabric item type that follows the Git Integration format can be listed here.

**Prerequisite:** None. If an item type is listed but no matching folders exist in `repository_directory`, it is simply a no-op for that type.

### `parameters.find_replace`

| | |
|---|---|
| **Required** | No |
| **Type** | List of `{ find_value, replace_value }` pairs |
| **Description** | Literal string substitutions applied to all item definition files before publishing to Fabric. |

**Example:**

```yaml
parameters:
  find_replace:
    - find_value: "PLACEHOLDER_LAKEHOUSE_ID"
      replace_value: "00000000-0000-0000-0000-000000000000"
    - find_value: "PLACEHOLDER_SQL_ENDPOINT"
      replace_value: "dev-server.datawarehouse.fabric.microsoft.com"
```

**How it works:**
1. The pairs are written to a separate parameter file (`fab-params-<ws>.yml`)
2. The deploy config references this file via the `parameter:` key
3. `fab deploy` performs literal text replacements across all item definitions before pushing to Fabric

**Prerequisite:** The `find_value` strings must actually appear in the source item definition files (e.g. JSON pipeline definitions, notebook content). If a `find_value` doesn't match anything, it's silently skipped.

**Typical use case:** Parameterize environment-specific values so the same source artifacts are reused across dev/tst/prd:

| What | Dev value | Prd value |
|---|---|---|
| `PLACEHOLDER_LAKEHOUSE_ID` | `00000000-...` | `22222222-...` |
| `PLACEHOLDER_SQL_ENDPOINT` | `dev-server.datawarehouse...` | `prd-server.datawarehouse...` |

---

## Roles

The `roles:` list defines the desired RBAC state for a workspace.

### Fields

| Field | Required | Description |
|---|---|---|
| `identity` | Yes | **Entra Object ID (GUID)** of the principal. Must be a GUID — UPNs and display names are not supported by the `fab acl` commands. |
| `principalType` | Yes | `Group`, `User`, or `ServicePrincipal`. Informational — used for clarity; the `fab acl` commands operate on the object ID. |
| `role` | Yes | One of `Admin`, `Member`, `Contributor`, `Viewer`. |
| `remove` | No | Set to `true` to explicitly revoke this assignment. Default: `false` (additive). |

### Behavior

- **Additive by default:** Roles that exist in Fabric but are not listed in the config are left untouched.
- **Explicit removal:** To revoke an assignment, add an entry with `remove: true`. The script calls `fab acl rm`.
- **Idempotent:** Re-running with the same config produces no changes.

### Example

```yaml
roles:
  # Grant access
  - identity: "da5b8c7e-02d9-4291-8377-c4c1dfc33f5d"
    principalType: User
    role: Admin

  - identity: "8464cf43-6605-46ac-a6cd-717f2ecf138d"
    principalType: Group
    role: Contributor

  # Revoke access
  - identity: "00000000-0000-0000-0000-000000000099"
    principalType: User
    role: Member
    remove: true
```

---

## Git Integration

The optional `gitIntegration:` block on a workspace connects it to a Git repository branch and performs initial synchronization. Supports Azure DevOps and GitHub providers.

Set `gitIntegration: false` to explicitly disconnect the workspace from Git.

### Fields

| Field | Required | Description |
|---|---|---|
| `provider` | Yes | Git provider: `AzureDevOps` or `GitHub`. |
| `repositoryName` | Yes | Name of the Git repository. |
| `branchName` | Yes | Branch to connect (e.g. `main`). |
| `organizationName` | Yes (ADO) | Azure DevOps organization name. Required when `provider` is `AzureDevOps`. |
| `projectName` | Yes (ADO) | Azure DevOps project name. Required when `provider` is `AzureDevOps`. |
| `ownerName` | Yes (GitHub) | GitHub repository owner. Required when `provider` is `GitHub`. |
| `connectionId` | Required for SPN/MI | Fabric Connection GUID. Required for service principal or managed identity authentication. Also required for GitHub. |
| `directoryName` | No | Relative path within the repository (e.g. `FIN-Core-Dev.Workspace`). Defaults to repository root. |
| `initializationStrategy` | No | `None`, `PreferRemote` (default), or `PreferWorkspace`. Controls initial sync direction. |
| `conflictResolutionPolicy` | No | `PreferRemote` (default) or `PreferWorkspace`. Used when `UpdateFromGit` is the required action. |
| `allowOverrideItems` | No | `true` (default) or `false`. Allows overwriting existing workspace items during `UpdateFromGit`. |

### Example

```yaml
gitIntegration:
  provider: AzureDevOps
  organizationName: MyOrg
  projectName: MyProject
  repositoryName: fabric-items
  branchName: main
  directoryName: FIN-Core-Dev.Workspace
  connectionId: "3f2504e0-4f89-11d3-9a0c-0305e82c3301"
  initializationStrategy: PreferRemote
  conflictResolutionPolicy: PreferRemote
  allowOverrideItems: true
```

### Behavior

- **Idempotent:** If the workspace is already `ConnectedAndInitialized` to the correct repo/branch/directory, no changes are made.
- **Reconnect on drift:** If the connected provider details differ from the config, the workspace is disconnected and reconnected.
- **SPN/MI auth:** Automatic Git credentials are not supported for service principal or managed identity. A pre-created Fabric Connection (`connectionId`) is required.

---

## Gateways

The optional top-level `gateways:` list defines VNet Data Gateways managed outside of workspaces. Gateways allow Fabric workloads to securely connect to data sources within an Azure Virtual Network.

### Fields

| Field | Required | Description |
|---|---|---|
| `name` | Yes | Gateway display name. Maps to the Fabric CLI path `.gateways/<name>.Gateway`. |
| `capacityName` | Yes | Fabric capacity name for billing. |
| `virtualNetworkName` | Yes | Azure Virtual Network name containing the gateway subnet. |
| `subnetName` | Yes | Subnet delegated to `Microsoft.PowerPlatform/vnetaccesslinks`. |
| `subscriptionId` | No | Azure subscription ID. Required if the VNet is in a different subscription than the Fabric capacity. |
| `resourceGroupName` | No | Resource group of the VNet. |
| `inactivityMinutesBeforeSleep` | No | Auto-pause timer in minutes. Valid values: `30`, `60`, `90`, `120`, `150`, `240`, `360`, `480`, `720`, `1440`. |
| `numberOfMemberGateways` | No | Gateway cluster size (1–9 members). |
| `roles` | No | Role assignments for the gateway. |

### Gateway roles

| Field | Required | Description |
|---|---|---|
| `identity` | Yes | Entra Object ID (GUID) of the principal. |
| `role` | Yes | One of `Admin`, `ConnectionCreator`, `ConnectionCreatorWithResharing`. |
| `remove` | No | Set to `true` to explicitly revoke this assignment. |

### Example

```yaml
gateways:
  - name: fin-dev-vnet-gw
    capacityName: ndplnecp01weufdevfcp
    subscriptionId: "ff10c34a-..."
    resourceGroupName: ndpl-necp01-weu-ntwk-rsg
    virtualNetworkName: ndpl-necp01-weu-ntwk-vnt
    subnetName: FabricGatewaySubnet
    inactivityMinutesBeforeSleep: 120
    numberOfMemberGateways: 2
    roles:
      - identity: "a2ae4cfb-..."
        role: Admin
      - identity: "c2017801-..."
        role: ConnectionCreator
```

### Behavior

- **Idempotent:** Existing gateways are updated only when settings differ. Role assignments are compared before making changes.
- **Additive RBAC:** Gateway roles not in config are preserved unless explicitly marked with `remove: true`.
- **Subnet requirements:** The subnet must be delegated to `Microsoft.PowerPlatform/vnetaccesslinks` and the deployment identity must have `Microsoft.Network/virtualNetworks/subnets/join/action` on the VNet.

---

## Private Links

Private Link configuration is **optional** and has two parts: a shared top-level section and per-workspace blocks.

### Top-level `privateLinks:` (shared settings)

Defines Azure networking context shared by all workspaces in the environment.

| Field | Required | Description |
|---|---|---|
| `tenantId` | Yes | Azure AD tenant ID |
| `subscriptionId` | Yes | Azure subscription hosting the networking resources |
| `subnetId` | Yes | Full resource ID of the subnet for PLS/PE |
| `privateDnsZoneId` | Yes | Full resource ID of the `privatelink.fabric.microsoft.com` DNS zone |
| `location` | Yes | Azure region (e.g. `westeurope`) |
| `resourceGroupName` | No | Target resource group. Can also be passed via `-ResourceGroupName` parameter on the script. |

### Per-workspace `privateLink:` block

Defines the PLS and PE resource names for a specific workspace.

| Field | Required | Description |
|---|---|---|
| `plsName` | Yes | Name for the Private Link Service resource |
| `peResourceName` | No | Name for the Private Endpoint resource |

### How it works

1. `Deploy-FabricEnvironment.ps1` exports a `workspace-map.json` with workspace name → GUID mappings
2. `Deploy-PrivateLinks.ps1` reads the map and the config, builds a parameter set for each workspace with a `privateLink:` block
3. A Bicep template is deployed via `New-AzResourceGroupDeployment`
4. Supports `-WhatIfMode` for validation without changes

### Prerequisites

- The top-level `privateLinks:` section must be present for any per-workspace `privateLink:` blocks to take effect
- Requires an Azure service connection with permissions to deploy to the target resource group
- Runs inside an `AzurePowerShell@5` pipeline task (requires `Az` PowerShell module)
- The Bicep template is provided externally via the `-TemplateFile` parameter

### Example

```yaml
privateLinks:
  tenantId: "00000000-0000-0000-0000-000000000000"
  subscriptionId: "00000000-0000-0000-0000-000000000000"
  subnetId: "/subscriptions/.../subnets/FabricDevSubnet"
  privateDnsZoneId: "/subscriptions/.../privateDnsZones/privatelink.fabric.microsoft.com"
  location: westeurope
  resourceGroupName: my-fabric-dev-rsg

workspaces:
  - name: Analytics-Dev
    # ... items, roles ...
    privateLink:
      plsName: my-fabric-dev-analytics-pls
      peResourceName: my-fabric-dev-analytics-pe
```

---

## Adding a new environment

1. Copy an existing file (e.g. `dev.yml` → `uat.yml`)
2. Update the `environment` field to `uat`
3. Update `capacityName` to the target capacity
4. Adjust workspace names, descriptions, and role assignments
5. Update `find_replace` values to match the new environment
6. Update `gitIntegration` connection details (branch, directory, connectionId) if applicable
7. Update `gateways` names, VNet/subnet references, and role assignments if applicable
8. Update `privateLink` resource names if applicable
9. Add the new environment to the pipeline (`deploy-fabric.yml`) and create matching ADO variable group entries and environment
