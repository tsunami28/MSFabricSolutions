# Source Code Reference

This directory contains all PowerShell scripts and helpers that power the fabric-cicd-v2 deployment solution.

```
src/
├── helpers/                           # Shared utility functions (dot-sourced)
│   ├── Invoke-FabCli.ps1              # Fabric CLI wrapper + Test-FabResourceExists
│   ├── Read-EnvironmentConfig.ps1     # YAML config loader and validator
│   └── New-FabDeployConfig.ps1        # Generates fab deploy config files
└── scripts/                           # Deployment scripts
    ├── Deploy-FabricEnvironment.ps1   # Main orchestrator (entry point)
    ├── Deploy-Workspaces.ps1          # Workspace create/update
    ├── Deploy-Items.ps1               # Item deployment via fab deploy
    ├── Deploy-Security.ps1            # RBAC role assignments
    ├── Deploy-PrivateLinks.ps1        # PLS + PE via Bicep
    └── Validate-Deployment.ps1        # Post-deployment validation
```

---

## Scripts

### Deploy-FabricEnvironment.ps1

**The main entry point.** Orchestrates the full deployment lifecycle for one environment.

**Invocation:** Standalone (from CLI or pipeline).

**Execution order:**

1. Authenticate to Fabric (`fab auth login`)
2. Read and validate the environment YAML config
3. Deploy workspaces (or resolve existing IDs if scope is restricted)
4. Deploy items via `fab deploy`
5. Configure RBAC security
6. Export `workspace-map.json` for downstream tasks (Private Links)

**Parameters:**

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-ConfigFile` | Yes | — | Path to environment YAML file (e.g. `config/environments/dev.yml`) |
| `-Environment` | Yes | — | Target environment: `dev`, `tst`, or `prd`. Validated against config. |
| `-ClientId` | Yes (SPN) | — | Entra application (client) ID |
| `-ClientSecret` | Yes (SPN) | — | Client secret for service principal auth |
| `-TenantId` | Yes (SPN) | — | Azure AD tenant ID |
| `-UseManagedIdentity` | Yes (MI) | — | Use system-assigned managed identity |
| `-ManagedIdentityClientId` | No | — | Client ID for user-assigned managed identity |
| `-Scope` | No | `all` | Restrict which phases run: `all`, `workspaces`, `items`, `security`, `privatelinks` |
| `-RepoRoot` | No | Auto-detected | Repository root for resolving `repository_directory` paths |
| `-WhatIf` | No | `$false` | Preview mode (not fully wired to all sub-scripts) |

**Authentication** uses two mutually exclusive parameter sets:
- **ServicePrincipal:** `-ClientId` + `-ClientSecret` + `-TenantId`
- **ManagedIdentity:** `-UseManagedIdentity` (optionally + `-ManagedIdentityClientId`)

**Outputs:**
- `workspace-map.json` — JSON file mapping workspace names to GUIDs, exported to the artifacts directory
- ADO pipeline variable `WorkspaceMapFile` — set via `##vso[task.setvariable]` so downstream tasks can reference the map

**Example:**

```powershell
.\Deploy-FabricEnvironment.ps1 `
    -ConfigFile   'config/environments/dev.yml' `
    -Environment  'dev' `
    -ClientId     '<appId>' `
    -ClientSecret '<secret>' `
    -TenantId     '<tenantId>' `
    -Scope        'all'
```

---

### Deploy-Workspaces.ps1

Creates or updates Fabric workspaces defined in the environment config.

**Invocation:** Called by `Deploy-FabricEnvironment.ps1`. Not standalone.

**What it does per workspace:**

1. `fab exists <name>.Workspace` — checks if the workspace already exists
2. If missing: `fab mkdir <name>.Workspace` — creates it with the configured capacity
3. If existing: `fab set <name>.Workspace -q description` — updates the description
4. `fab get <name>.Workspace -q id` — retrieves the workspace GUID

**Parameters:**

| Parameter | Required | Description |
|---|---|---|
| `-Config` | Yes | Parsed environment config object (from `Read-EnvironmentConfig`) |
| `-Environment` | Yes | Target environment: `dev`, `tst`, or `prd` |

**Returns:** `[hashtable]` — workspace name → GUID mapping.

**Capacity assignment:** Uses `fab config set default_capacity <name>` before `fab mkdir` to assign the workspace to the correct capacity. Per-workspace overrides (`capacityOverride`) take precedence over the top-level `capacityName`.

**Idempotency:** Safe to re-run. Existing workspaces are updated, not recreated. Handles the edge case where `fab exists` returns false but `fab mkdir` reports a conflict (identity lacks read permissions).

---

### Deploy-Items.ps1

Deploys Fabric items from local source directories to target workspaces using `fab deploy`.

**Invocation:** Called by `Deploy-FabricEnvironment.ps1`. Not standalone.

**What it does per workspace:**

1. Resolves `repository_directory` to an absolute path
2. Reads `item_types_in_scope` (optional filter) and `parameters.find_replace` (optional substitutions)
3. Calls `New-FabDeployConfig` to generate a `fab deploy` config YAML and parameter file
4. Runs `fab deploy --config <generated.yml> -f`

**Parameters:**

| Parameter | Required | Description |
|---|---|---|
| `-Config` | Yes | Parsed environment config object |
| `-WorkspaceMap` | Yes | Hashtable of workspace name → GUID (from `Deploy-Workspaces`) |
| `-Environment` | Yes | Target environment: `dev`, `tst`, or `prd` |
| `-RepoRoot` | Yes | Absolute path to repository root for resolving relative paths |

**Generated files** (written to a temp directory, cleaned up after deployment):

| File | Purpose |
|---|---|
| `fab-deploy-<ws>.yml` | `fab deploy` config: workspace ID, source directory, item type filter |
| `fab-params-<ws>.yml` | Find/replace parameter file referenced by the deploy config |

**Skips gracefully** when:
- No `items:` block defined for a workspace
- Workspace not found in the workspace map
- `repository_directory` is empty or the directory doesn't exist

---

### Deploy-Security.ps1

Configures RBAC role assignments for Fabric workspaces.

**Invocation:** Called by `Deploy-FabricEnvironment.ps1`. Not standalone.

**What it does per workspace:**

1. `fab acl get <ws>.Workspace --output_format json` — retrieves current ACLs
2. Compares each desired role against existing assignments
3. `fab acl set ... -I <objectId> -R <role> -f` — assigns or updates roles
4. `fab acl rm ... -I <objectId> -f` — removes roles marked `remove: true`
5. Skips roles that already match the desired state

**Parameters:**

| Parameter | Required | Description |
|---|---|---|
| `-Config` | Yes | Parsed environment config object |
| `-WorkspaceMap` | Yes | Hashtable of workspace name → GUID (from `Deploy-Workspaces`) |
| `-Environment` | Yes | Target environment: `dev`, `tst`, or `prd` |

**Returns:** `[List[PSCustomObject]]` — array of result objects with properties:

| Property | Description |
|---|---|
| `Workspace` | Workspace name |
| `Identity` | Entra Object ID |
| `Role` | Target role |
| `Action` | `Assigned`, `Removed`, `Skipped`, or `AlreadyAbsent` |

**Behavior:**
- **Additive only** — roles present in Fabric but absent from config are NOT removed
- **Explicit removal** — entries with `remove: true` are actively revoked
- **Idempotent** — re-running with the same config produces `Skipped` actions

---

### Deploy-PrivateLinks.ps1

Deploys Azure Private Link Services (PLS) and Private Endpoints (PE) for Fabric workspaces via Bicep.

**Invocation:** Standalone. Runs as a separate `AzurePowerShell@5` pipeline task after `Deploy-FabricEnvironment.ps1`.

**Prerequisites:**
- Active Azure context (provided by `AzurePowerShell@5` task via service connection)
- `Az` PowerShell module
- `workspace-map.json` exported by `Deploy-FabricEnvironment.ps1`
- Bicep template for PLS/PE resources (provided externally)
- Top-level `privateLinks:` section in the environment config

**Parameters:**

| Parameter | Required | Description |
|---|---|---|
| `-ConfigFile` | Yes | Path to the environment YAML config file |
| `-WorkspaceMapFile` | Yes | Path to the workspace-map JSON exported by the orchestrator |
| `-TemplateFile` | Yes | Path to the Bicep template for PLS/PE |
| `-ResourceGroupName` | Yes | Azure resource group for the deployment |
| `-WhatIfMode` | No | Run `New-AzResourceGroupDeployment -WhatIf` instead of deploying |

**What it does:**

1. Verifies an Azure context exists
2. Loads the environment config and workspace map
3. Skips if no `privateLinks` section is defined
4. For each workspace with a `privateLink:` block, builds a config entry with `workspaceId`, `plsName`, `peResourceName`
5. Validates that `subnetId` and `privateDnsZoneId` are set
6. Deploys all workspaces in a **single** `New-AzResourceGroupDeployment` call

**Bicep template parameters passed:**

| Parameter | Source |
|---|---|
| `workspaceConfigs` | Array of `{ workspaceId, plsName, peResourceName, peType }` |
| `subnetId` | From `privateLinks.subnetId` |
| `privateDnsZoneId` | From `privateLinks.privateDnsZoneId` |
| `tenantId` | From `privateLinks.tenantId` (optional) |
| `location` | From `privateLinks.location` (optional) |

---

### Validate-Deployment.ps1

Post-deployment validation that checks deployed resources match the config. Outputs NUnit XML for the ADO Tests tab.

**Invocation:** Standalone. Called by the `validate-deployment.yml` pipeline template.

**Parameters:**

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-ConfigFile` | Yes | — | Path to the environment YAML config file |
| `-Environment` | Yes | — | Target environment: `dev`, `tst`, or `prd` |
| `-OutputPath` | No | System temp | Directory to write NUnit XML results |

**Checks performed per workspace:**

| Check | How |
|---|---|
| Workspace exists | `fab exists <ws>.Workspace` |
| Expected roles assigned | `fab acl get <ws>.Workspace --output_format json` — verifies each non-removed role is present |

**Output:** NUnit XML file at `<OutputPath>/fabric-validation-<env>.xml`, consumed by the `PublishTestResults@2` pipeline task.

**Exit code:** Returns `1` if any checks fail, `0` if all pass.

> **Note:** The validation task is currently **disabled** in the pipeline template (`enabled: false`) pending completion.

---

## Helpers

Helpers are **dot-sourced** by scripts — they define functions, not standalone executables.

### Invoke-FabCli.ps1

Provides two functions:

#### `Invoke-FabCli`

Executes a Fabric CLI (`fab`) command with structured output handling, retry logic, and JSON parsing.

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-Arguments` | Yes | — | Array of arguments to pass to `fab` (e.g. `@('ls', '--output_format', 'json')`) |
| `-MaxRetries` | No | `3` | Number of retry attempts for transient failures |
| `-RetryBackoffBase` | No | `2` | Base for exponential backoff (delay = base^attempt seconds) |
| `-AllowNonZeroExit` | No | `$false` | Don't throw on non-zero exit codes (use for `fab exists`) |

**Returns:** `[PSCustomObject]` with:
- `ExitCode` — process exit code
- `Output` — parsed JSON object (when `--output_format json`) or raw stdout string
- `Stderr` — stderr content

**Retry behavior:**
- Exit code `0` = success (no retry)
- Exit code `2` = authentication error (not retried — requires re-auth)
- Other exit codes = retried with exponential backoff

#### `Test-FabResourceExists`

Returns `$true` / `$false` for whether a Fabric resource path exists.

```powershell
if (Test-FabResourceExists 'Analytics-Dev.Workspace') { ... }
```

---

### Read-EnvironmentConfig.ps1

#### `Read-EnvironmentConfig`

Loads and validates an environment YAML config file.

| Parameter | Required | Description |
|---|---|---|
| `-ConfigPath` | Yes | Path to the YAML file (e.g. `config/environments/dev.yml`) |

**Returns:** `[PSCustomObject]` — the validated config.

**Validations performed:**
- Required top-level fields: `environment`, `capacityName`, `workspaces`
- `environment` must be `dev`, `tst`, or `prd`
- At least one workspace defined
- Each workspace must have a `name` (no duplicates)
- Each role must have `identity` and `role` fields
- `role` must be `Admin`, `Member`, `Contributor`, or `Viewer`
- `principalType` (if set) must be `Group`, `User`, or `ServicePrincipal`

**Requires:** `powershell-yaml` module.

---

### New-FabDeployConfig.ps1

#### `New-FabDeployConfig`

Generates the YAML config files consumed by `fab deploy` for a single workspace.

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-WorkspaceName` | Yes | — | Workspace display name (for file naming) |
| `-WorkspaceId` | Yes | — | Workspace GUID (validated as a GUID pattern) |
| `-RepositoryDirectory` | Yes | — | Absolute path to the item source directory |
| `-ItemTypesInScope` | No | `@()` (all) | List of item types to include |
| `-FindReplace` | No | `@()` | Array of `@{ find_value; replace_value }` hashtables |
| `-OutputDirectory` | No | `$env:TEMP` | Directory for generated files |

**Returns:** `[PSCustomObject]` with:
- `ConfigPath` — path to the generated `fab-deploy-<ws>.yml`
- `ParameterPath` — path to the generated `fab-params-<ws>.yml` (or `$null` if no find/replace rules)

**Generated deploy config structure:**

```yaml
core:
  workspace_id: "<guid>"
  repository_directory: "<path>"
  item_types_in_scope:        # only if ItemTypesInScope is non-empty
    - Notebook
    - Lakehouse
  parameter: "<path>"         # only if FindReplace is non-empty
```

**Generated parameter file structure:**

```yaml
find_replace:
  - find_value: "PLACEHOLDER"
    replace_value: "actual-value"
```
