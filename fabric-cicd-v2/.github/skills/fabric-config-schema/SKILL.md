---
name: fabric-config-schema
description: 'YAML environment config schema, validation rules, and parameterization patterns for fabric-cicd-v2. Use when asking about config validation, YAML schema, environment config, find_replace, parameterization, PLACEHOLDER_, capacityOverride, workspace config, roles config, privateLink config, item_types_in_scope, repository_directory, or Read-EnvironmentConfig errors.'
---

# Fabric Config Schema & Validation

Environment configs at `config/environments/{env}.yml` define the full desired state for one Fabric environment. Validated at runtime by `src/helpers/Read-EnvironmentConfig.ps1`.

## Full Schema Reference

```yaml
# ── Top-Level (all required unless noted) ──────────────────────────────────
environment: dev | tst | prd                    # Required. Must match -Environment param at runtime.
capacityName: <fabric-capacity-name>            # Required. Fabric CLI resolves names directly (no GUID).

# ── Optional: Shared Private Link settings ─────────────────────────────────
privateLinks:
  tenantId: "<guid>"
  SubscriptionId: "<guid>"
  subnetId: "<full-arm-resource-id>"            # /subscriptions/.../subnets/...
  privateDnsZoneId: "<full-arm-resource-id>"
  location: <azure-region>                      # e.g., westeurope
  resourceGroupName: <rg-name>

# ── Optional: Planned features (not yet implemented) ──────────────────────
logAnalytics:                                   # Planned — see docs/log-analytics-plan.md
  workspaceId: "<law-resource-id>"
gateways:                                       # Planned — see docs/vnet-data-gateway-plan.md
  - name: <gateway-name>

# ── Workspaces (required, at least one entry) ─────────────────────────────
workspaces:
  - name: <WorkspaceName>                       # Required. Must be unique within file.
    description: <text>                         # Optional. Updated on every deployment if present.
    capacityOverride: null | <capacity-name>    # Optional. null = use top-level capacityName.

    # ── Item Deployment ────────────────────────────────────────────────────
    items:                                      # Optional block. Omit to skip item deployment.
      repository_directory: artifacts/<Name>.Workspace  # Required if items present. Relative to repo root.
      item_types_in_scope:                      # Optional allow-list filter.
        - Notebook
        - DataPipeline
        - Lakehouse
      parameters:
        find_replace:                           # Optional. Applied during fab deploy.
          - find_value: "PLACEHOLDER_VALUE"
            replace_value: "actual-value-for-this-env"

    # ── RBAC Role Assignments ──────────────────────────────────────────────
    roles:                                      # Optional block. Omit to skip RBAC.
      - identity: "<entra-object-id>"           # Required. Must be GUID format.
        principalType: User | Group | ServicePrincipal  # Optional (informational for docs).
        role: Admin | Member | Contributor | Viewer     # Required.
        remove: true                            # Optional. If true, explicitly revoke this assignment.

    # ── Private Link ───────────────────────────────────────────────────────
    privateLink:                                # Optional. Requires top-level privateLinks block.
      plsName: <private-link-service-name>
      peResourceName: <private-endpoint-name>
```

## Validation Rules

Enforced by `Read-EnvironmentConfig.ps1`:

| Field | Rule |
|-------|------|
| `environment` | Exactly one of: `dev`, `tst`, `prd` |
| `capacityName` | Required, non-empty string |
| `workspaces` | Required array, minimum 1 entry |
| Workspace `name` | Required, unique within file (case-insensitive) |
| `repository_directory` | Must exist on disk; must contain `<item>.<ItemType>/` folders with `.platform` files |
| `identity` | GUID format only — UPNs and display names are NOT accepted |
| `role` | Exactly one of: `Admin`, `Member`, `Contributor`, `Viewer` |
| `principalType` | Exactly one of: `User`, `Group`, `ServicePrincipal` |
| Cross-check | `config.environment` must match the `-Environment` parameter passed at runtime |

### Testing Locally

```powershell
. src/helpers/Read-EnvironmentConfig.ps1
$config = Read-EnvironmentConfig -ConfigPath 'config/environments/dev.yml'
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
