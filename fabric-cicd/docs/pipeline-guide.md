# Pipeline Guide

## Running the Pipeline

### Automatic Runs (CI)

The pipeline triggers automatically on any push to `main` that touches files under `config/**` or `src/**`. It always runs all four stages in sequence (Validate → Dev → Tst → Prd), with approval gates on Tst and Prd.

### Manual Runs

Use **Run pipeline** in ADO to trigger a run with custom parameters:

| Parameter | Description | Default |
|---|---|---|
| **Target Environment** | `all` runs all stages. `dev` / `tst` / `prd` runs only that stage (skipping others). | `all` |
| **Dry Run** | `true` logs all planned actions without calling any Fabric API. | `false` |
| **Deployment Scope** | `all` runs workspaces + items + security. `workspaces` / `items` / `security` runs that step only. | `all` |

**Example**: To validate that a config change looks correct before merging, manually trigger with `Dry Run = true` and `Target Environment = dev`.

---

## Stage Behaviour

### Validate

Runs `Test-Json -Schema` against all three environment parameter files. Fails immediately if any file violates the schema. No Azure or Fabric calls are made.

### Deploy_Dev

Runs automatically after Validate succeeds, or when `Target Environment` is `dev` or `all`. Uses the `fabric-dev` ADO Environment - no approval required.

Steps:
1. Install PowerShell modules (`MicrosoftFabricMgmt`, `PSFramework`, `Az.Accounts`)
2. Run `Deploy-FabricEnvironment.ps1` (workspaces → items → security)
3. Run `Validate-Deployment.ps1` and publish results to ADO Tests tab

### Deploy_Tst / Deploy_Prd

Same steps as Dev. Run after the previous stage **succeeds or is skipped** (the skip condition allows targeting a single environment on manual runs without re-running earlier stages).

An approval reviewer must approve before each of these stages executes. Configure reviewers in **Pipelines → Environments → fabric-tst / fabric-prd → Approvals and checks**.

---

## Skipping Stages on Manual Runs

The stage conditions use `in(dependencies.X.result, 'Succeeded', 'Skipped')`. This means:

- If you manually run with `Target Environment = prd`, Validate still runs but Deploy_Dev and Deploy_Tst are skipped (because the `environment` parameter is not `all`/`dev`/`tst`). Deploy_Prd then runs, because its dependency (Tst) was **skipped** - not failed.
- This allows incident response re-runs against a single environment without re-running earlier stages.

---

## Deployment Scope

The `scope` parameter controls which sub-scripts the orchestrator calls:

| Scope | Workspaces | Items | Security |
|---|---|---|---|
| `all` | ✅ | ✅ | ✅ |
| `workspaces` | ✅ | ❌ | ❌ |
| `items` | ❌ | ✅ | ❌ |
| `security` | ❌ | ❌ | ✅ |

Use scoped runs when iterating on a specific layer without affecting others. For example, after adding a new security group to a parameter file, run with `scope = security` to apply only the RBAC change.

---

## Artifacts and Test Results

After each deployment stage, two artifacts are published:

| Artifact | Where in ADO |
|---|---|
| `validation-{env}.xml` | **Tests tab** - NUnit XML; shows pass/fail per resource check |
| `validation-{env}/` folder | **Artifacts tab** - contains `fabric-deploy.log` with structured PSFramework log output |

If the validation script detects a missing resource, the test result is marked as failed, the stage fails, and the log contains `##vso[task.logissue type=error]` annotations that appear inline in the pipeline run summary.

---

## Dry Run

When `DryRun = true`:

- All API read calls execute normally (Get-FabricWorkspace, Get-FabricLakehouse, etc.)
- All API write calls (create, update, assign) are skipped
- The orchestrator logs `[DRY RUN] Would create workspace: Analytics-Dev` style messages
- The validation script is **not** run after a dry-run deployment (because resources were not actually created)

Use dry run on the first pipeline run against any environment to verify parameter file content and authentication without risk of creating partial state.

---

## Module Installation

The `install-modules.yml` template installs three modules in the current user scope on the agent:

| Module | Version pinned |
|---|---|
| `MicrosoftFabricMgmt` | 1.0.8 |
| `PSFramework` | 1.12.0 |
| `Az.Accounts` | 5.0.0 |

Modules are checked with `Get-Module -ListAvailable` before installing - if the exact version is already present (e.g. from a warm agent), installation is skipped for faster runs. If your agent pool uses ephemeral agents, installation always runs (~30–60 seconds total).

---

## Troubleshooting

### Schema validation fails

Run `Test-Json -Schema` locally (see [parameter-files.md](parameter-files.md)) and check the error message. Common issues:

- `environment` field value does not match the file name
- A principal `role` value is not in the allowed enum (`Admin`, `Member`, `Contributor`, `Viewer`)
- A required field is missing (e.g. `name` on a lakehouse)

### Deployment stage fails at auth

- Verify the ADO service connection (`sc-fabric-{env}`) is configured correctly and the **Verify** button succeeds
- Check that `fabricTenantId` and `managedIdentityClientId` are set correctly in the variable groups
- Ensure the Fabric tenant setting **Service principals can use Fabric APIs** is enabled

### Workspace or item not created

- Check the `fabric-deploy.log` artifact for detailed PSFramework output
- Check the Tests tab for the failing validation assertion and its message
- Common cause: the UAMI does not have Admin access to the workspace or the capacity

---

## PR Validation Pipeline

### What it does

When a pull request targets `main` and touches `fabric-cicd/` files, the PR pipeline (`pr-validate-fabric.yml`) runs two stages automatically:

1. **SchemaValidation** - validates `dev.json`, `tst.json`, and `prd.json` against the JSON Schema. No Azure auth required.
2. **DryRun** - detects which workspaces are affected by the PR's changes, then runs a dry-run deployment against the dev environment for only those workspaces. Posts a Markdown summary comment on the PR.

### ADO setup (one-time)

1. **Import the pipeline**: In ADO go to Pipelines → New Pipeline → Azure Repos Git → select the repo → Existing YAML file → `fabric-cicd/pipelines/pr-validate-fabric.yml`.
2. **Enable OAuth token**: Open the pipeline's settings → check **Allow scripts to access OAuth token**. This is required for the PR comment step to call the ADO Threads REST API using `System.AccessToken`.
3. **Branch policy**: Go to Repos → Branches → `main` → Branch policies. Add a **Build validation** policy, select the PR pipeline, and set it as **Required**. Set **Trigger** to *Automatic* and **Policy requirement** to *Required*.
4. **No new service connections or variable groups** are needed - the PR pipeline reuses `sc-fabric-dev`, `vg-fabric-common`, and `vg-fabric-dev`.

### Change-set scoping

The `Get-DeploymentScope.ps1` script runs before the dry-run step (no Azure auth needed). It performs a `git diff origin/<targetBranch> HEAD` and maps changed files to affected workspaces using this decision tree (first match wins):

| Condition | Outcome |
|---|---|
| `git diff` fails | All workspaces (safe fallback) |
| No files changed under `fabric-cicd/` | Nothing to validate - dry-run skipped |
| Shared config changed (`config/shared/`, `config/schemas/`, `src/`, `pipelines/`) | All workspaces |
| Env JSON top-level fields changed | All workspaces |
| Workspace entry in env JSON changed | That workspace only |
| Artifact file changed (notebook/pipeline/SJD `definitionPath`) | Workspace that references the artifact |

`fetchDepth: 0` is set on the PR pipeline checkout. This is required because ADO uses a shallow clone by default (`fetchDepth: 1`), which means `origin/main` would not be present for the diff. A full fetch is needed.

### PR comment

After the dry-run, `post-pr-comment.yml` posts a Markdown thread on the PR. The comment includes:

- Environment and timestamp
- A table of workspaces that were in scope
- A table of deployment steps and their status
- Overall result (✅ Succeeded / ❌ Failed)

The comment step runs with `condition: always()` and is non-fatal - if posting fails (e.g. token permissions), the pipeline continues and the result is logged as a warning.

---

## Change-Set Scoping on the Deploy Pipeline

### `autoScope` parameter

The main deploy pipeline exposes an `autoScope` boolean (default: **`true`**). When true, `Deploy-FabricEnvironment.ps1` calls `Get-DeploymentScope.ps1` at runtime and skips workspaces that are not affected by the current commit.

| `autoScope` | Effect |
|---|---|
| `true` (default) | Only workspaces changed since the previous commit are deployed |
| `false` | All workspaces in the config are deployed, regardless of changes |

### When to set `autoScope = false`

- **First run** in a new environment (all workspaces must be provisioned)
- **After a long gap** between deployments where you want to reconcile all workspaces
- **Debugging** where you need to confirm a workspace is in sync even though its config didn't change
- **Manual hotfix** where you want to force-refresh a single environment regardless of git history

Set via the pipeline run parameters: uncheck `autoScope` before clicking **Run**.

### Deployment scope vs workspace scope

These are separate controls that can be combined:

- **`scope`** (e.g. `security`) - controls *which step scripts* run (workspaces, items, security, etc.)
- **`autoScope`** / **`WorkspaceFilter`** - controls *which workspaces* those steps act on

Example: `scope=security, autoScope=true` re-applies only RBAC changes for workspaces whose config changed.

---

## Drift Detection Pipeline

### What it does

`drift-detect-fabric.yml` runs every **Tuesday at 05:00 UTC** against dev, tst, and prd simultaneously. For each environment it calls `Get-FabricDriftReport.ps1` which:

1. Queries live Fabric state via the MicrosoftFabricMgmt module and the REST helper
2. Compares against the environment JSON parameter file
3. Writes a **NUnit XML** (consumed by the ADO Tests tab) and a **JSON report** (pipeline artifact)
4. Exits 0 always; the job fails via `PublishTestResults@2 failTaskOnFailedTests:true` if failures exist

### Drift checks

| Category | What is checked |
|---|---|
| Workspaces | Exists; capacity ID matches `capacities.json` lookup |
| Items | Exists (lakehouse, warehouse, notebook, data pipeline, Spark env, SJD); description matches config |
| Connections | Exists in Fabric by display name |
| Security | Each `roles[]` entry has a matching role assignment in Fabric |
| Orphaned (warnings) | Items present in Fabric but absent from config - appear as passing tests in a separate NUnit suite |

### Remediation

The pipeline has a `remediate` parameter (default: **`false`**). When set to `true` on a manual run:

- After each DriftCheck stage, a corresponding Remediate stage calls `Deploy-FabricEnvironment.ps1 -Scope all -AutoScope $false` for that environment
- Remediate_Tst and Remediate_Prd require **manual approval** on the `fabric-tst` / `fabric-prd` ADO Environments
- Remediation runs regardless of whether drift was found (the deploy is idempotent - no-op if nothing is drifted)
- Remediate stages run sequentially (dev → tst → prd) even though DriftCheck stages ran in parallel

### ADO setup (one-time)

1. Import the pipeline: `fabric-cicd/pipelines/drift-detect-fabric.yml`
2. **No new service connections or variable groups** - reuses `sc-fabric-{env}`, `vg-fabric-common`, `vg-fabric-{env}`
3. The `fabric-tst` and `fabric-prd` ADO Environments already have approval gates from the deploy pipeline setup - no additional configuration needed

### Reading drift results

| Location | Content |
|---|---|
| **ADO Tests tab** | NUnit XML with one suite per category (Workspaces, Items, Connections, Security, Orphaned) |
| **Artifacts → `drift-{env}`** | `drift-report-{env}.json` with full check list, expected vs actual, and orphaned warnings |
| **Pipeline run summary** | `##vso[task.logissue type=error]` annotations inline for each drifted resource |
