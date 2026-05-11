# Environment Configuration Reference

Each YAML file in this directory (`dev.yml`, `tst.yml`, `prd.yml`) defines the full desired state for one Fabric environment. The deployment scripts read these files and converge the target environment to match.

---

## File structure overview

```yaml
environment: <string>           # Top-level environment identifier
capacityName: <string>          # Default Fabric capacity
privateLinks: { ... }           # Optional: shared Private Link settings
workspaces:
  - name: <string>
    description: <string>
    capacityOverride: <string|null>
    items: { ... }              # Item deployment config
    roles: [ ... ]              # RBAC role assignments
    privateLink: { ... }        # Optional: per-workspace PLS/PE
```

---

## Top-level fields

| Field | Required | Description |
|---|---|---|
| `environment` | Yes | Environment name. Must be `dev`, `tst`, or `prd`. Validated against the `-Environment` parameter at runtime. |
| `capacityName` | Yes | Default Fabric capacity name. All workspaces are assigned to this capacity unless overridden. The Fabric CLI resolves names directly — no GUID needed. |
| `privateLinks` | No | Shared settings for Private Link Service / Private Endpoint deployment. See [Private Links](#privatelinks). |
| `workspaces` | Yes | List of workspace definitions. See [Workspaces](#workspaces). |

---

## Workspaces

Each entry under `workspaces:` defines a single Fabric workspace and its desired state.

| Field | Required | Description |
|---|---|---|
| `name` | Yes | Workspace display name. If the workspace doesn't exist, it will be created. |
| `description` | No | Workspace description. Updated on every run for existing workspaces. |
| `capacityOverride` | No | Override the top-level `capacityName` for this workspace only. Set to `null` to use the default. |
| `items` | No | Item deployment configuration. If omitted, no items are deployed to this workspace. See [Items](#items). |
| `roles` | No | RBAC role assignments for this workspace. See [Roles](#roles). |
| `privateLink` | No | Private Link Service + Private Endpoint config for this workspace. See [Private Links](#privatelinks). |

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
6. Update `privateLink` resource names if applicable
7. Add the new environment to the pipeline (`deploy-fabric.yml`) and create matching ADO variable group entries and environment
