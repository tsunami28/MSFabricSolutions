# Architecture

## Overview

The Fabric CI/CD solution provisions and configures Microsoft Fabric resources declaratively from JSON parameter files, driven by an Azure DevOps YAML pipeline. It uses the [MicrosoftFabricMgmt](../tools/MicrosoftFabricMgmt/) PowerShell module (v1.0.8) for the majority of API interactions, with a thin REST wrapper for the small number of endpoints the module does not yet cover.

---

## Repository Layout

```
fabric-cicd/
├── config/
│   ├── environments/        ← per-environment parameter files (dev.json, tst.json, prd.json)
│   ├── schemas/             ← JSON Schema for parameter file validation
│   └── shared/              ← shared config (capacity ID map)
├── docs/                    ← this folder
├── pipelines/
│   ├── deploy-fabric.yml    ← main Azure DevOps pipeline definition
│   └── templates/           ← reusable YAML step templates
│       ├── install-modules.yml
│       ├── deploy-environment.yml
│       ├── validate-deployment.yml
│       ├── post-pr-comment.yml           ← PR comment template (Phase 5)
│       └── detect-environment-drift.yml ← drift detection steps (Phase 6)
└── src/
    ├── helpers/
    │   └── Invoke-FabricRestMethod.ps1   ← REST helper for module gaps
    └── scripts/
        ├── Deploy-FabricEnvironment.ps1  ← main orchestrator
        ├── Deploy-Workspaces.ps1         ← workspace provisioning
        ├── Deploy-Connections.ps1        ← Fabric connection creation (Phase 3)
        ├── Deploy-Items.ps1              ← Fabric item provisioning
        ├── Deploy-PipelineDefinitions.ps1 ← pipeline definition upload (Phase 3)
        ├── Deploy-SparkJobDefinitions.ps1 ← SJD definition upload (Phase 4)
        ├── Get-DeploymentScope.ps1       ← git diff-based workspace scope detection (Phase 5)
        ├── Get-FabricDriftReport.ps1     ← live state vs config drift checker (Phase 6)
        ├── Deploy-Security.ps1           ← RBAC role assignments
        └── Validate-Deployment.ps1       ← post-deploy validation
```

---

## Component Map

```
Azure DevOps Pipeline (deploy-fabric.yml)
│
├── Stage: Validate
│   └── PowerShell@2: Test-Json -Schema (JSON Schema draft-07)
│
├── Stage: Deploy_Dev  ──────────────────────────────────────────────────┐
├── Stage: Deploy_Tst  (approval gate: fabric-tst environment)           │
└── Stage: Deploy_Prd  (approval gate: fabric-prd environment)           │
                                                                         │
    Each deployment stage runs three templates in sequence:              │
    ┌── install-modules.yml                                              │
    │       Installs MicrosoftFabricMgmt, PSFramework, Az.Accounts       │
    ├── deploy-environment.yml   (AzurePowerShell@5 task)               │
    │       └── Deploy-FabricEnvironment.ps1   [orchestrator]           │
    │               ├── Set-FabricApiHeaders (MI auth)                  │
    │               ├── Deploy-Workspaces.ps1                           │
    │               ├── Deploy-Connections.ps1  → returns connectionMap  │
    │               ├── Deploy-Items.ps1  (receives connectionMap)       │
    │               ├── Deploy-PipelineDefinitions.ps1                  │
    │               ├── Deploy-SparkJobDefinitions.ps1                  │
    │               └── Deploy-Security.ps1                             │
    └── validate-deployment.yml  (AzurePowerShell@5 task)               │
            └── Validate-Deployment.ps1                                 │
                    └── Publishes NUnit XML → ADO Test tab              │
                    └── Publishes log file  → ADO Artifacts  ───────────┘
```

---

## Pipeline Stages

### Deploy Pipeline (`deploy-fabric.yml`)

| Stage | Trigger | Approval |
|---|---|---|
| **Validate** | Every push to `main` on `fabric-cicd/config/**` or `fabric-cicd/src/**` or `fabric-cicd/pipelines/**` | None |
| **Deploy_Dev** | Auto after Validate, or manual with `environment=dev` | None (`fabric-dev` has no reviewers) |
| **Deploy_Tst** | After Dev (succeeded **or skipped**), or `environment=tst` | Manual approval on `fabric-tst` ADO Environment |
| **Deploy_Prd** | After Tst (succeeded **or skipped**), or `environment=prd` | Manual approval on `fabric-prd` ADO Environment |

The **"or skipped"** condition on Tst and Prd allows an operator to manually trigger a deployment directly to a single environment (e.g. re-run prd only) without re-running earlier stages.

**`autoScope` parameter (default: `true`)**: each deploy stage calls `Get-DeploymentScope.ps1` inside the orchestrator to compute which workspaces changed since the last commit. Unchanged workspaces are skipped. Set `autoScope=false` for manual full-deploy runs.

### PR Validation Pipeline (`pr-validate-fabric.yml`)

| Stage | Condition | Auth |
|---|---|---|
| **SchemaValidation** | Always on PR to `main` | None (file I/O only) |
| **DryRun** | After SchemaValidation succeeded | `sc-fabric-dev` (dev MI) |  

### Drift Detection Pipeline (`drift-detect-fabric.yml`)

| Stage | Schedule / Trigger | Auth | Approval |
|---|---|---|---|
| **DriftCheck_Dev** | Tuesday 05:00 UTC (parallel) | `sc-fabric-dev` | None |
| **DriftCheck_Tst** | Tuesday 05:00 UTC (parallel) | `sc-fabric-tst` | None |
| **DriftCheck_Prd** | Tuesday 05:00 UTC (parallel) | `sc-fabric-prd` | None |
| **Remediate_Dev** | After DriftCheck_Dev (only if `remediate=true`) | `sc-fabric-dev` | None |
| **Remediate_Tst** | After Remediate_Dev (only if `remediate=true`) | `sc-fabric-tst` | `fabric-tst` environment |
| **Remediate_Prd** | After Remediate_Tst (only if `remediate=true`) | `sc-fabric-prd` | `fabric-prd` environment |

- `always: true` on the schedule ensures the pipeline runs even when no code changed — required for drift detection to catch manual changes in Fabric.
- Remediation conditions accept `Succeeded`, `SucceededWithIssues`, **and `Failed`** from the DriftCheck stage so that the deploy always runs regardless of drift status (the deploy scripts are idempotent).
- Remediation uses `AutoScope = $false` to deploy all workspaces in the config, bypassing git-diff scoping.

- Scope detection runs **before** the Azure PowerShell task (no auth required). Changed workspaces are identified via `git diff` and passed to the orchestrator as `AutoScope = $true`.
- If **no Fabric files changed**, the dry-run job is skipped; a "nothing to validate" PR comment is posted.
- If **shared config or scripts** changed, all workspaces are validated.
- A Markdown **PR comment** is posted after the dry-run summarising which workspaces were validated and the result of each deployment step.
- `fetchDepth: 0` on checkout ensures the full git history is available for the diff.

---

## PowerShell Scripts

### Deploy-FabricEnvironment.ps1 — Orchestrator

Entry point called by the `AzurePowerShell@5` task. Responsibilities:

1. Configure PSFramework logging to `$(BUILD_ARTIFACTSTAGINGDIRECTORY)/validation-{env}/fabric-deploy.log`
2. Call `Set-FabricApiHeaders` to establish a Fabric API token from the active Az.Accounts session
3. Load and validate the environment config JSON
4. Build the capacity ID lookup map from `config/shared/capacities.json`
5. **Scope detection** (when `AutoScope = $true`): call `Get-DeploymentScope.ps1` to compute `WorkspaceFilter` from git diff; if nothing changed, exit early and write `dry-run-summary.json`
6. Invoke sub-scripts in dependency order: **Workspaces → Connections → Items → PipelineDefinitions → SparkJobDefinitions → Security**; pass `WorkspaceFilter` to every step
7. When `DryRun = $true`, write `dry-run-summary.json` to the artifacts staging directory for use by the PR comment template
8. Annotate any failures as `##vso[task.logissue type=error]` for ADO

**New parameters (Phase 5):**

| Parameter | Type | Default | Description |
|---|---|---|---|
| `WorkspaceFilter` | `string[]` | `@()` | Explicit workspace name filter. Empty = deploy all. |
| `AutoScope` | `bool` | `$false` | Auto-compute `WorkspaceFilter` from git diff before deploying. |

### Get-FabricDriftReport.ps1

Standalone script called by `detect-environment-drift.yml`. Compares every resource in the parameter file against live Fabric state and writes both a NUnit XML and a JSON artifact.

**Checks performed (config → Fabric):**

| Category | Checks |
|---|---|
| Workspaces | Exists; correct capacity ID |
| Items | Exists (lakehouse, warehouse, notebook, data pipeline, Spark env, SJD); description drift |
| Connections | Exists in Fabric by display name |
| Security | Role assignment present for every `roles[]` entry in config |

**Orphaned resource detection (Fabric → config):**
For each workspace in the config, lists items present in Fabric but absent from the config. These are recorded as **warnings only** — they do not fail the drift check. Warnings appear as passing test cases in the NUnit output under the `Orphaned (Warnings)` suite.

**Output files:**

| File | Purpose |
|---|---|
| `drift-{env}.xml` | NUnit XML consumed by `PublishTestResults@2` |
| `drift-report-{env}.json` | Machine-readable report with full check details and warnings |

The script **always exits 0**. The ADO job fails via `PublishTestResults@2` with `failTaskOnFailedTests: true` if the NUnit XML contains failures.

### Get-DeploymentScope.ps1

Standalone helper called by the orchestrator (auto-scope mode) and directly by the PR pipeline's scope-detection step. **No Fabric API calls** — reads git diff output and the config JSON only.

**Decision logic (first match wins):**

| Condition | Result |
|---|---|
| `git diff` fails or returns no output | `AllWorkspaces = $true` (safe fallback) |
| Shared config changed (`config/shared/`, `config/schemas/`, `src/`, `pipelines/`) | `AllWorkspaces = $true` |
| Env JSON changed — top-level fields differ | `AllWorkspaces = $true` |
| Env JSON changed — workspace-level diff | Include only changed/added workspaces |
| Artifact files changed (notebook/pipeline/SJD `definitionPath`) | Include workspaces that reference those paths |
| No changes map to any workspace | `NothingToDo = $true` |

**Return type:** `PSCustomObject { NothingToDo: bool; AllWorkspaces: bool; WorkspaceFilter: string[] }`

### Deploy-Workspaces.ps1

- Idempotent: creates the workspace if it does not exist; updates description if it changed
- Assigns the workspace to a Fabric capacity (resolves `capacityOverride` → `capacityName` → `capacities.json` lookup → live API fallback)
- Assigns to a Fabric domain if `domainName` is set
- Returns a list of `{Name, Action, Id}` objects consumed by `Deploy-Items.ps1`

### Deploy-Items.ps1

Provisions Fabric items inside each workspace, in this order:

| Item type | Create | Update description | Definition upload | Shortcut |
|---|---|---|---|---|
| Lakehouse | ✅ `New-FabricLakehouse` | ✅ `Update-FabricLakehouse` | — | — |
| Warehouse | ✅ `New-FabricWarehouse` | ✅ `Update-FabricWarehouse` | — | — |
| Spark Environment | ✅ `New-FabricEnvironment` | ✅ `Update-FabricEnvironment` | — | — |
| Notebook | ✅ `New-FabricNotebook` | ✅ `Update-FabricNotebook` | Phase 3 | — |
| Data Pipeline | ✅ `New-FabricDataPipeline` | ✅ `Update-FabricDataPipeline` | Phase 3 | — |
| OneLake Shortcut | ✅ `Invoke-FabricRestMethod` | ✅ idempotent (skip if exists) | — | — |
| External Shortcut (ADLS/S3) | ✅ `Invoke-FabricRestMethod` | ✅ idempotent (skip if exists) | — | — |
| Spark Job Definition | ✅ `New-FabricSparkJobDefinition` | ✅ `Update-FabricSparkJobDefinition` | ✅ `Update-FabricSparkJobDefinitionDefinition` | — |

All creates are idempotent — the script checks for an existing item by name before creating. On re-runs, `description` is updated if the parameter file value differs from the live Fabric value.

**OneLake shortcut resolution**: target `workspaceName` and `itemName` in the parameter file are resolved to IDs at deploy time. No GUIDs are stored in parameter files.

### Deploy-Security.ps1

- **Additive by default**: role assignments present in the config are added; assignments not listed are left untouched
- Supports explicit removal: set `"remove": true` on a role entry to remove that assignment if it exists
- Matches existing assignments by `userPrincipalName` or object `id`
- Uses `Add-FabricWorkspaceRoleAssignment` / `Remove-FabricWorkspaceRoleAssignment`

### Validate-Deployment.ps1

Runs after every deployment stage. Checks:

- Each configured workspace exists
- Each configured lakehouse, warehouse, and notebook exists
- Each configured role assignment is present

Outputs an **NUnit 3 XML** file that the `PublishTestResults@2` task uploads to the ADO Tests tab. Throws if any check fails, causing the stage to fail.

### Invoke-FabricRestMethod.ps1 — REST Helper

Dot-sourced by the orchestrator. Provides:

| Function | Purpose |
|---|---|
| `Invoke-FabricRestMethod` | HTTP wrapper with retry (exponential backoff, `Retry-After` header) and LRO polling |
| `Invoke-FabricLROPoll` | Polls `Operation-Location` URL until `Succeeded`/`Failed`/`Cancelled` |
| `New-FabricUri` | Constructs `https://api.fabric.microsoft.com/v1/{path}[?query]` |

Covers the Fabric API areas not yet available in MicrosoftFabricMgmt:
- **OneLake shortcut creation** — `POST /v1/workspaces/{id}/items/{id}/shortcuts` (Phase 2 & 3; `New-FabricOneLakeShortcut` requires a connection ID even for `oneLake` targets, so the REST helper is used instead)
- **Connection create** — `POST /v1/connections` (Phase 3)
- **Connection role assignment** — `POST /v1/connections/{id}/roleAssignments` (Phase 3)
- **Pipeline definition upload** — `POST /v1/workspaces/{id}/dataPipelines/{id}/updateDefinition` (Phase 3)

> Note: Spark Job Definition upload uses `Update-FabricSparkJobDefinitionDefinition` from the module (Phase 4), not the REST helper.

---

## Authentication Design

See [auth-design.md](auth-design.md) for full details. Summary:

- Each environment has a dedicated **User-Assigned Managed Identity** (UAMI)
- The ADO service connection (`sc-fabric-{env}`) is linked to that UAMI
- The `AzurePowerShell@5` task calls `Connect-AzAccount` automatically using the service connection
- Scripts call `Set-FabricApiHeaders -UseManagedIdentity -ManagedIdentityId $ClientId -TenantId $TenantId`
- `Invoke-FabricRestMethod` calls `Get-AzAccessToken -ResourceUrl 'https://analysis.windows.net/powerbi/api'` to get a fresh Fabric bearer token from the same Az.Accounts session — no credentials stored or passed explicitly

---

## Key Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| PowerShell version | PS 7+ only | MicrosoftFabricMgmt requirement |
| Auth model | User-Assigned Managed Identity, one per environment | Least-privilege; no secrets to rotate; environment isolation |
| Module for Fabric API | MicrosoftFabricMgmt v1.0.8 | 355+ cmdlets; keeps script code concise |
| REST wrapper needed for | Connections, deployment pipelines | Module gaps in v1.0.8 |
| Fabric Git integration | Not used | Pure API provisioning chosen (no Fabric Git workspace links) |
| Idempotency | Full read-before-write on all resources | Safe to re-run pipelines without side effects |
| Security model | Additive RBAC by default, explicit `"remove": true` for removals | Prevents accidental permission loss on re-runs |
| Parameter file format | JSON with JSON Schema (draft-07) validation | Schema enforced in CI before any deployment stage runs |
| Logging | PSFramework → log file artifact + `##vso[task.logissue]` ADO annotations | Structured logs available in ADO even when a stage fails |
| Change-set scoping | Workspace-level git diff; first-match-wins decision tree | Balances precision with reliability; shared config change → full deploy |
| PR dry-run auth | Reuses `sc-fabric-dev` MI | No dedicated PR identity; dev MI is already least-privilege |
| Drift detection direction | Config → Fabric (failures) + Fabric → config (warnings) | Failures gate remediation; orphaned resources flagged without auto-delete risk |
| Drift job failure mechanism | Script exits 0; `PublishTestResults failTaskOnFailedTests:true` fails the job | Ensures NUnit XML is always written and published even when drift exists |
| Drift remediation trigger | Manual pipeline parameter `remediate=true` | Prevents unintended side effects from automated remediation; approval gates on tst/prd |

---

## Phase Roadmap

| Phase | Status | Scope |
|---|---|---|
| 1 — Foundation | ✅ Complete | Pipeline, orchestrator, core scripts, parameter files, schema, REST helper |
| 2 — Description drift + OneLake shortcuts | ✅ Complete | Description update on existing items; OneLake shortcut creation; schema extended for shortcut targets |
| 3 — Connections, external shortcuts & pipeline defs | ✅ Complete | `Deploy-Connections.ps1` (ADLS SP/MI, SQL SP); ADLS Gen2/S3 external shortcuts; data pipeline definition upload (always-upload, LRO); connection sharing with workspace |
| 4 — Advanced items | ✅ Complete | Spark Job Definitions (create, description drift, definition upload). Fabric Deployment Pipeline execution deferred to Phase 5. |
| 5 — PR validation + change-set scoping | ✅ Complete | `pr-validate-fabric.yml` (schema + dry-run on PR); `Get-DeploymentScope.ps1` (workspace-level git diff); `WorkspaceFilter` + `AutoScope` on all scripts; `post-pr-comment.yml` (Markdown PR thread); `autoScope=true` default on deploy pipeline. Fabric Deployment Pipeline execution still deferred. |
| 6 — Drift detection | ✅ Complete | `drift-detect-fabric.yml` (Tuesday 05:00 UTC, parallel per-env); `Get-FabricDriftReport.ps1` (workspace, item, connection, security checks; orphaned warnings); `detect-environment-drift.yml` template; optional `remediate=true` parameter with approval gates on tst/prd. |
| 7 — Advanced features | 🔲 Not started | Rollback, multi-tenant, secret rotation |
