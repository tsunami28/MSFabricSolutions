---
name: fabric-config-schema
description: 'YAML environment config schema, validation rules, and parameterization patterns for fabric-cicd-v2. Use when asking about config validation, YAML schema, environment config, find_replace, parameterization, PLACEHOLDER_, capacityOverride, workspace config, roles config, privateLink config, item_types_in_scope, repository_directory, or Read-EnvironmentConfig errors.'
---

# Fabric Config Schema & Validation

Environment configs live as **split-file directories** at `config/environments/{env}/`. Each directory contains:
- `_env.yml` — environment-level settings (required)
- One `<WorkspaceName>.yml` per workspace

Shared values in `config/shared/defaults.yml` (privateLinks base) and `config/shared/roles-common.yml` (RBAC for every workspace) are merged at load time. Validated at runtime by `src/helpers/Read-EnvironmentConfig.ps1`.

> **Legacy:** `Read-EnvironmentConfig -ConfigPath config/environments/dev.yml` (monolithic file) is still supported.

## `_env.yml` Schema

```yaml
# ── Required ─────────────────────────────────────────────────────────────────
environment: dev | tst | prd
capacityName: <fabric-capacity-name>

# ── Optional: env-specific privateLinks overrides (merged with defaults.yml) ─
privateLinks:
  # Required for PLS/PE deployments: these fields MUST be set in `_env.yml`
  tenantId: "<tenant-guid>"
  privateDnsZoneId: "<resource-id-or-guid>"
  location: "<region>"
  SubscriptionId: "<guid>"
  subnetId: "<full-arm-resource-id>"
  resourceGroupName: <rg-name>

# ── Optional: VNet Data Gateways (environment-scoped) ────────────────────────
gateways:
  - name: <gateway-name>
    capacityName: <fabric-capacity-name>
    subscriptionId: "<guid>"
    resourceGroupName: <rg-name>
    virtualNetworkName: <vnet-name>
    subnetName: <subnet-name>
    inactivityMinutesBeforeSleep: 30  # 30|60|90|120|150|240|360|480|720|1440
    numberOfMemberGateways: 2         # 1-9
    roles:
      - identity: "<entra-object-id>"
        role: Admin | ConnectionCreator | ConnectionCreatorWithResharing
```

## Per-workspace `<WorkspaceName>.yml` Schema

```yaml
# ── Required ─────────────────────────────────────────────────────────────────
name: <WorkspaceName>                         # Must be unique within environment.

# ── Optional ─────────────────────────────────────────────────────────────────
description: <text>
capacityOverride: null | <capacity-name>
skipCommonRoles: false                        # Set true to skip roles-common.yml injection.

# ── Item Deployment ────────────────────────────────────────────────────────
items:
  repository_directory: artifacts/<Name>.Workspace  # Required if items present.
  item_types_in_scope:                        # Optional allow-list filter.
    - Notebook
    - DataPipeline
    - Lakehouse
  parameters:
    find_replace:
      - find_value: "PLACEHOLDER_VALUE"
        replace_value: "actual-value-for-this-env"

# ── RBAC Role Assignments ──────────────────────────────────────────────────
# roles-common.yml entries are prepended automatically (deduped by identity+role)
roles:
  - identity: "<entra-object-id>"
    principalType: User | Group | ServicePrincipal
    role: Admin | Member | Contributor | Viewer
    remove: true                              # Optional. Explicitly revoke.

# ── Private Link ───────────────────────────────────────────────────────────
privateLink:
  plsName: <private-link-service-name>
  peResourceName: <private-endpoint-name>

# ── Git Integration ────────────────────────────────────────────────────────
gitIntegration:                               # Set to false to disconnect.
  provider: AzureDevOps | GitHub
  organizationName: <org>                     # AzureDevOps only
  projectName: <project>                      # AzureDevOps only
  repositoryName: <repo>
  branchName: <branch>
  directoryName: <path-in-repo>
  connectionId: "<fabric-connection-guid>"   # Required for SPN/MI auth
  initializationStrategy: None | PreferRemote | PreferWorkspace
  conflictResolutionPolicy: PreferRemote | PreferWorkspace
  allowOverrideItems: true
```

## Validation Rules

Enforced by `Read-EnvironmentConfig.ps1`:

| Field | Rule |
|-------|------|
| `environment` | Exactly one of: `dev`, `tst`, `prd` |
| `capacityName` | Required, non-empty string |
| `workspaces` | At least one workspace file must exist in the directory |
| Workspace `name` | Required, unique within environment (case-insensitive) |
| `repository_directory` | Must exist on disk; must contain `<item>.<ItemType>/` folders with `.platform` files |
| `identity` | GUID format only — UPNs and display names are NOT accepted |
| `role` | Exactly one of: `Admin`, `Member`, `Contributor`, `Viewer` |
| `principalType` | Exactly one of: `User`, `Group`, `ServicePrincipal` |
| Cross-check | `config.environment` must match the `-Environment` parameter passed at runtime |

### Testing Locally

```powershell
. src/helpers/Read-EnvironmentConfig.ps1
$config = Read-EnvironmentConfig -ConfigPath 'config/environments/dev/'
```

Throws with descriptive error on validation failure.

## Field Interactions & Edge Cases

### `capacityOverride: null` vs Omitting the Field

- `capacityOverride: null` — explicitly uses the top-level `capacityName`. Equivalent to omitting.
- `capacityOverride: "other-capacity"` — overrides for this workspace only.
- Omitting `capacityOverride` entirely — same as `null`, uses top-level default.

Both `null` and absent produce the same behavior. Use explicit `null` for documentation clarity.

### `items` Block Absent vs Empty

- **Absent** — item deployment skipped for this workspace.
- **Present but missing `repository_directory`** — validation error.
- **`repository_directory` pointing to empty folder** — `fab deploy` succeeds (no-op).

### `roles` Block Absent vs Empty Array

- **Absent** — RBAC step skipped for this workspace. No roles touched.
- **Empty array `roles: []`** — same as absent, RBAC step skipped.
- **Present with entries** — additive merge. Existing roles NOT in config are preserved.

## Parameterization with `find_replace`

Enables single-source artifacts across environments. The Fabric CLI replaces text literals in item definitions during `fab deploy`.

### Standard Placeholder Conventions

| Placeholder | Purpose | Example Replacement |
|-------------|---------|---------------------|
| `PLACEHOLDER_LAKEHOUSE_ID` | Lakehouse GUID | `a1b2c3d4-...` |
| `PLACEHOLDER_SQL_ENDPOINT` | SQL analytics endpoint | `xyz.datawarehouse.fabric.microsoft.com` |
| `PLACEHOLDER_CONNECTION_STRING` | Connection string | `Server=...;Database=...` |
| `PLACEHOLDER_WORKSPACE_ID` | Target workspace GUID | `e5f6g7h8-...` |

### Multi-Environment Pattern

```yaml
# dev.yml
find_replace:
  - find_value: "PLACEHOLDER_LAKEHOUSE_ID"
    replace_value: "dev-lakehouse-guid-here"
  - find_value: "PLACEHOLDER_SQL_ENDPOINT"
    replace_value: "dev-sql.datawarehouse.fabric.microsoft.com"

# prd.yml — same source artifacts, different values
find_replace:
  - find_value: "PLACEHOLDER_LAKEHOUSE_ID"
    replace_value: "prd-lakehouse-guid-here"
  - find_value: "PLACEHOLDER_SQL_ENDPOINT"
    replace_value: "prd-sql.datawarehouse.fabric.microsoft.com"
```

### Common Pitfall: JSON Escaping

`find_replace` operates on raw text. If replacement values contain quotes or special characters, the resulting item JSON may be malformed. Always validate item definitions after replacement.

## Naming Conventions

- **Workspace names** — environment suffix: `Analytics-Dev`, `Analytics-Tst`, `Analytics-Prd`
- **Private Link names** — pattern: `{prefix}-{env}-{domain}-pls` / `{prefix}-{env}-{domain}`
- **Config file names** — match environment: `dev.yml`, `tst.yml`, `prd.yml`
- **Repository directories** — match workspace: `artifacts/<WorkspaceName>.Workspace`

## Shared Reference Data

`config/shared/capacities.yml` contains capacity metadata (SKU, region, resource group). Referenced by infrastructure templates but not directly by deployment scripts.
