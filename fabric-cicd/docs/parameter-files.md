# Parameter File Guide

Environment parameter files are the source of truth for what Fabric resources exist in each environment. The pipeline reads these files and reconciles Fabric to match.

---

## File Locations

```
config/
├── environments/
│   ├── dev.json    ← development environment
│   ├── tst.json    ← test/staging environment
│   └── prd.json    ← production environment
├── schemas/
│   └── environment.schema.json   ← JSON Schema (draft-07); validated in CI
└── shared/
    └── capacities.json           ← capacity name → GUID lookup
```

---

## Schema Validation

Every push to `main` that touches `config/**` triggers the **Validate** stage before any deployment. The stage runs `Test-Json -Schema` (PowerShell 7 built-in) against each parameter file. A schema violation fails the pipeline immediately.

To validate locally:

```powershell
$schema  = Get-Content 'config/schemas/environment.schema.json' -Raw
$content = Get-Content 'config/environments/dev.json' -Raw
$content | Test-Json -Schema $schema -ErrorAction Stop
```

---

## File Structure

```json
{
    "$schema": "../schemas/environment.schema.json",
    "environment": "dev",
    "capacityName": "FabricCapacity-Dev",
    "workspaces": [ ... ]
}
```

| Field | Required | Description |
|---|---|---|
| `environment` | ✅ | Must be `dev`, `tst`, or `prd`. Must match the file name. |
| `capacityName` | | Default Fabric capacity name for all workspaces in this file. Can be overridden per workspace. |
| `workspaces` | ✅ | Array of workspace definitions. At least one entry required. |

---

## Workspace Definition

```json
{
    "name": "Analytics-Dev",
    "description": "Analytics development workspace",
    "capacityOverride": null,
    "domainName": null,
    "roles": [ ... ],
    "items": { ... },
    "shortcuts": [ ... ],
    "connections": [ ... ]
}
```

| Field | Required | Description |
|---|---|---|
| `name` | ✅ | Workspace display name (1–256 chars). |
| `description` | | Workspace description. Updated on re-run if changed. |
| `capacityOverride` | | Overrides `capacityName` for this workspace only. Set to `null` to use the default. |
| `domainName` | | Fabric domain to assign this workspace to. Set to `null` to skip domain assignment. |
| `roles` | | RBAC role assignments. See [Role Assignments](#role-assignments). |
| `items` | | Fabric items (lakehouses, warehouses, etc.). See [Items](#items). |
| `shortcuts` | | OneLake and external shortcuts. See [Shortcuts](#shortcuts). |
| `connections` | | Fabric connections for external shortcuts. See [Connections](#connections). |

---

## Role Assignments

```json
{
    "principal": "analytics-developers@contoso.com",
    "principalType": "Group",
    "role": "Contributor"
}
```

| Field | Required | Values |
|---|---|---|
| `principal` | ✅ | User UPN, group email, or service principal object ID |
| `principalType` | ✅ | `User` \| `Group` \| `ServicePrincipal` \| `App` |
| `role` | ✅ | `Admin` \| `Member` \| `Contributor` \| `Viewer` |
| `remove` | | `true` to remove this assignment if it exists. Default: `false`. |

**Behaviour**: The deployment script is **additive by default**. Role assignments listed in the file are added; assignments not listed are left untouched. To explicitly remove an assignment, set `"remove": true`.

---

## Items

Each item type lives under `workspaces[].items`:

```json
"items": {
    "lakehouses": [ ... ],
    "warehouses": [ ... ],
    "notebooks": [ ... ],
    "dataPipelines": [ ... ],
    "environments": [ ... ],
    "sparkJobDefinitions": [ ... ]
}
```

All item arrays are optional. Omit or set to `[]` if not needed.

### Lakehouse

```json
{
    "name": "RawData",
    "description": "Raw ingestion layer",
    "enableSchemas": false
}
```

| Field | Required | Description |
|---|---|---|
| `name` | ✅ | Item display name |
| `description` | | Optional description. Updated on re-run if the value differs from the live Fabric item. |
| `enableSchemas` | | Enable schema support on the lakehouse. Default: `false`. |

### Warehouse

```json
{
    "name": "AnalyticsWarehouse",
    "description": "Analytics data warehouse"
}
```

### Spark Environment

```json
{
    "name": "SparkEnv-Dev",
    "description": "Spark environment for development"
}
```

### Notebook

```json
{
    "name": "Ingest-RawData",
    "description": "Raw data ingestion notebook",
    "definitionPath": "artifacts/notebooks/Ingest-RawData"
}
```

| Field | Required | Description |
|---|---|---|
| `name` | ✅ | Item display name |
| `description` | | Optional description. Updated on re-run if the value differs from the live Fabric item. |
| `definitionPath` | | Relative path (from repo root) to the notebook definition folder. Recorded in the config for Phase 3 — definition upload is not yet implemented. |

### Data Pipeline

```json
{
    "name": "MainOrchestration",
    "description": "Main ETL orchestration pipeline",
    "definitionPath": "artifacts/pipelines/MainOrchestration"
}
```

`definitionPath` points to a folder in the repository that must contain a `pipeline-content.json` file. The script reads this file, base64-encodes it, and calls `updateDefinition` on every pipeline run. `description` is updated on re-run if changed.

### Spark Job Definition

```json
{
    "name": "DailyTransform",
    "description": "Daily data transformation Spark job",
    "definitionPath": "artifacts/spark-job-definitions/DailyTransform"
}
```

| Field | Required | Description |
|---|---|---|
| `name` | ✅ | Display name. Must be unique within the workspace. Alphanumeric, spaces, underscores. |
| `description` | — | Optional description. Updated if the live value differs (description drift detection). |
| `definitionPath` | — | Repo-relative path to the folder containing `SparkJobDefinitionV1.json`. If omitted, the item is created/updated but no definition is uploaded. |

**Deployment behaviour (Phase 4 — implemented):**

1. **`Deploy-Items.ps1`** creates or updates the SJD item (name + description). Idempotent — skips creation if the item already exists; updates the description only when the value changes.
2. **`Deploy-SparkJobDefinitions.ps1`** (runs after `Deploy-Items.ps1`) uploads the definition on every pipeline run. This ensures the live Fabric definition is always in sync with the repo.

**Definition file layout on disk:**

```
artifacts/
  spark-job-definitions/
    DailyTransform/
      SparkJobDefinitionV1.json     ← required file name (Fabric schema)
```

The module cmdlet `Update-FabricSparkJobDefinitionDefinition` reads the file path directly and handles base64 encoding internally. SJD entries without `definitionPath` are silently skipped by the upload step.

---

## Shortcuts

Shortcuts are defined at the workspace level (`workspaces[].shortcuts`), not inside `items`. Only `oneLake` target shortcuts are deployed in Phase 2. External target types (`adlsGen2`, `s3`, etc.) require a Fabric connection and will be deployed in Phase 3.

### OneLake Shortcut (Phase 2 — implemented)

Points at a lakehouse in the same or a different Fabric workspace. No external connection required.

```json
{
    "lakehouseName": "CuratedData",
    "shortcutName": "raw-source",
    "subpath": "Files/raw-source",
    "target": {
        "type": "oneLake",
        "workspaceName": "Analytics-Dev",
        "itemName": "RawData",
        "itemType": "Lakehouse",
        "path": "Files"
    }
}
```

| Field | Required | Description |
|---|---|---|
| `lakehouseName` | ✅ | Name of the lakehouse in this workspace where the shortcut is mounted |
| `shortcutName` | ✅ | Display name of the shortcut |
| `subpath` | | Mount path inside the lakehouse `Files` tree. Defaults to `Files`. |
| `target.workspaceName` | ✅ | Display name of the source workspace. Resolved to a workspace ID at deploy time. |
| `target.itemName` | ✅ | Display name of the source lakehouse. Resolved to an item ID at deploy time. |
| `target.itemType` | | Currently only `Lakehouse` is supported. Default: `Lakehouse`. |
| `target.path` | ✅ | Path inside the source lakehouse to expose (e.g. `Files`, `Tables/sales`). |

### External Shortcuts (Phase 3 — implemented)

For `adlsGen2`, `s3`, `s3Compatible`, and `googleCloudStorage` targets, a Fabric connection must exist first. Connections are created by the `connections` deployment step (runs before `items`). If the `connectionRef` cannot be resolved to a connection ID the deployment **fails** — the shortcut is treated as a hard dependency.

```json
{
    "lakehouseName": "RawData",
    "shortcutName": "external-landing",
    "subpath": "Files/external-landing",
    "target": {
        "type": "adlsGen2",
        "url": "https://rawstoragedev.dfs.core.windows.net",
        "subpath": "/landing",
        "connectionRef": "adls-raw-dev"
    }
}
```

| Field | Required | Description |
|---|---|---|
| `target.type` | ✅ | `adlsGen2` \| `s3` \| `s3Compatible` \| `googleCloudStorage` |
| `target.url` | ✅ | Storage account or bucket URL |
| `target.subpath` | | Path within the storage (e.g. `/landing`, `/mycontainer/raw`). Defaults to empty string. |
| `target.connectionRef` | ✅ | Must match the `name` of a connection defined in `workspaces[].connections` |

---

## Connections

Connections are defined at the workspace level (`workspaces[].connections`). Each connection must exist before any external shortcut that references it via `connectionRef`. The `connections` deployment step runs before the `items` step.

Connections are **idempotent**: if a connection with the same display name already exists it is skipped (credentials are not overwritten). After creation the connection is shared with the workspace by posting a role assignment.

### ADLS Gen2 — Service Principal

```json
{
    "name": "adls-raw-dev",
    "type": "AzureDataLakeStorage",
    "authMethod": "ServicePrincipal",
    "accountUrl": "https://rawstoragedev.dfs.core.windows.net",
    "tenantId": "$(fabricTenantId)",
    "clientId": "$(adlsSpClientId)",
    "clientSecretRef": "$(adlsSpClientSecret)"
}
```

### ADLS Gen2 — Managed Identity

```json
{
    "name": "adls-raw-mi",
    "type": "AzureDataLakeStorage",
    "authMethod": "ManagedIdentity",
    "accountUrl": "https://rawstoragedev.dfs.core.windows.net"
}
```

### Azure SQL / Synapse — Service Principal

```json
{
    "name": "analytics-sql-dev",
    "type": "AzureSqlDatabase",
    "authMethod": "ServicePrincipal",
    "server": "myserver.database.windows.net",
    "database": "AnalyticsDB",
    "tenantId": "$(fabricTenantId)",
    "clientId": "$(sqlSpClientId)",
    "clientSecretRef": "$(sqlSpClientSecret)"
}
```

### Field Reference

| Field | Required | Description |
|---|---|---|
| `name` | ✅ | Display name. Referenced by shortcuts via `connectionRef`. |
| `type` | ✅ | `AzureDataLakeStorage` \| `AzureSqlDatabase` \| `AzureSynapse` |
| `authMethod` | ✅ | `ServicePrincipal` \| `ManagedIdentity` |
| `accountUrl` | SP/MI | Storage account DFS endpoint URL. Required for `AzureDataLakeStorage`. |
| `server` | SP | SQL Server FQDN. Required for `AzureSqlDatabase` / `AzureSynapse`. |
| `database` | SP | Database name. Required for `AzureSqlDatabase` / `AzureSynapse`. |
| `tenantId` | SP | Azure AD tenant ID. Reference the ADO variable: `$(fabricTenantId)`. |
| `clientId` | SP | Service principal application (client) ID. |
| `clientSecretRef` | SP | ADO secret variable reference. The pipeline expands this at runtime — **no secrets in the file**. Example: `$(adlsSpClientSecret)`. |

**`SP`** = required when `authMethod` is `ServicePrincipal`. **`MI`** = required when `authMethod` is `ManagedIdentity`.

The three ADO variable groups (`vg-fabric-dev`, `vg-fabric-tst`, `vg-fabric-prd`) should contain the SP credential variables, marked as secret. See [ado-setup.md](ado-setup.md).

---

## capacities.json

Maps capacity display names to their GUIDs, per environment. Used to resolve `capacityName` and `capacityOverride` values without making a live API call on every run.

```json
{
    "dev": {
        "FabricCapacity-Dev": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    },
    "tst": {
        "FabricCapacity-Tst": "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"
    },
    "prd": {
        "FabricCapacity-Prd": "zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz"
    }
}
```

You can list multiple capacities per environment if workspaces are spread across them. The key must exactly match the `capacityName` / `capacityOverride` value used in the environment files.

---

## Idempotency

All resources are provisioned with a read-before-write pattern:

- If a workspace or item already exists with the same name, it is **not recreated**
- If a `description` has changed (workspace or any item type), it is **updated** via a PATCH call
- If a role assignment already exists, it is **not duplicated**
- If an OneLake shortcut already exists with the same name, it is **skipped**
- If an external shortcut already exists with the same name, it is **skipped**
- If a connection with the same display name already exists, it is **skipped** (credentials not updated)

Re-running the pipeline against an unchanged config is a no-op — no Fabric API mutations are made for resources that already match the declared state. The `Action` column in the pipeline log reflects `Created`, `Updated`, or `Skipped` for every processed resource.

---

## Adding a New Environment Resource

1. Edit the appropriate `config/environments/{env}.json` file
2. Run `Test-Json -Schema` locally to validate (see [Schema Validation](#schema-validation))
3. Push to a feature branch and raise a PR — the Validate stage runs automatically on PR build
4. Merge to `main` — the pipeline deploys to dev automatically, then awaits approval for tst and prd
