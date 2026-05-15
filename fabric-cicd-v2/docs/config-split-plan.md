# Config Split Plan — Per-Workspace YAML Files with Shared Defaults

## Problem Statement

Each environment config (`config/environments/dev.yml`, `tst.yml`, `prd.yml`) is a single monolithic file containing **all** workspace definitions, roles, items, privateLink, and gateway blocks. With ~30 workspaces per environment, each file will exceed 2,000+ lines, making it:

- **Hard to read** — a single change requires scrolling through an enormous file.
- **Hard to manage** — merge conflicts are likely when multiple teams edit different workspaces in the same file.
- **Hard to review** — PRs touch one file even when only one workspace changed.
- **Repetitive** — infrastructure identities (e.g. `fabric_admins` group, deployment SPN), `privateLinks` base settings, and gateway definitions are duplicated across all three environment files.

## Goals

1. **One YAML file per workspace** — each workspace definition lives in its own file under a per-environment directory.
2. **Shared defaults** — common settings (privateLinks infra, common RBAC identities, gateways template) are defined once and inherited.
3. **Backward-compatible output** — `Read-EnvironmentConfig` continues to return the same `PSCustomObject` structure to all downstream scripts. No changes needed in `Deploy-Workspaces.ps1`, `Deploy-Items.ps1`, `Deploy-Security.ps1`, etc.
4. **Minimal blast radius** — the refactor is confined to config file layout and `Read-EnvironmentConfig.ps1`. Pipeline templates need only a path update.

---

## Proposed Directory Layout

```
config/
├── shared/
│   ├── capacities.yml              # (existing) capacity reference
│   ├── defaults.yml                # NEW — shared privateLinks, common roles, gateways template
│   └── roles-common.yml            # NEW — RBAC identities required on every workspace
│
├── environments/
│   ├── dev/
│   │   ├── _env.yml                # environment-level settings (environment, capacityName, privateLinks overrides)
│   │   ├── FIN-Core-Dev.yml        # workspace definition
│   │   ├── FIN-Reporting-Dev.yml   # workspace definition
│   │   ├── HR-Analytics-Dev.yml    # workspace definition
│   │   └── ...                     # one file per workspace
│   │
│   ├── tst/
│   │   ├── _env.yml
│   │   ├── FIN-Core-Tst.yml
│   │   ├── FIN-Reporting-Tst.yml
│   │   └── ...
│   │
│   └── prd/
│       ├── _env.yml
│       ├── Analytics-Prd.yml
│       ├── DataEngineering-Prd.yml
│       └── ...
```

### Naming Convention

- `_env.yml` — leading underscore signals "environment-level, not a workspace".
- `<WorkspaceName>.yml` — file name matches the workspace `name` field exactly (easier to find).

---

## File Schemas

### `config/shared/defaults.yml` — Shared Infrastructure Defaults

Contains settings that are identical (or nearly identical) across all environments. Per-environment files can override any value.

```yaml
# ── Shared Private Link base settings ──────────────────────────────────────
# Environment-specific values (subnetId, resourceGroupName) go in _env.yml.
privateLinks:
  tenantId: "2f741536-f5f3-445f-b1a9-9d260038ca80"
  privateDnsZoneId: "/subscriptions/e0cda8cb-4a9b-413e-9ab9-a3732f46fbd4/resourceGroups/mgmt-necp01-weu-ntwk-rsg/providers/Microsoft.Network/privateDnsZones/privatelink.fabric.microsoft.com"
  location: westeurope
```

### `config/shared/roles-common.yml` — Common RBAC Identities

Roles that must exist on **every** workspace (e.g. platform admin group, deployment SPN). These are automatically merged into each workspace's `roles` array unless the workspace explicitly opts out.

```yaml
# Common roles injected into every workspace.
# Per-workspace roles are additive (merged, not replaced).
roles:
  - identity: "8464cf43-6605-46ac-a6cd-717f2ecf138d"  # ndpl-necp-fabric_admins
    principalType: Group
    role: Admin
  - identity: "bc567124-414b-4f37-9b09-eec3af933add"  # ndpl-necp01-sub-spn (Bicep deployment)
    principalType: ServicePrincipal
    role: Admin
```

### `config/environments/dev/_env.yml` — Environment-Level Settings

```yaml
environment: dev
capacityName: ndplnecp01weufdevfcp

# ── Override / extend shared privateLinks settings ─────────────────────────
privateLinks:
  SubscriptionId: "ff10c34a-8edb-4d5a-b37f-82e2b9cc0347"
  subnetId: "/subscriptions/ff10c34a-8edb-4d5a-b37f-82e2b9cc0347/resourceGroups/ndpl-necp01-weu-ntwk-rsg/providers/Microsoft.Network/virtualNetworks/ndpl-necp01-weu-ntwk-vnt/subnets/FabricDevSubnet"
  resourceGroupName: ndpl-necp01-weu-fdev-rsg

# ── VNet Data Gateways (env-specific) ─────────────────────────────────────
gateways:
  - name: fin-dev-vnet-gw
    capacityName: ndplnecp01weufdevfcp
    subscriptionId: "ff10c34a-8edb-4d5a-b37f-82e2b9cc0347"
    resourceGroupName: ndpl-necp01-weu-ntwk-rsg
    virtualNetworkName: ndpl-necp01-weu-ntwk-vnt
    subnetName: FabricGatewaySubnet
    inactivityMinutesBeforeSleep: 120
    numberOfMemberGateways: 2
    roles:
      - identity: "a2ae4cfb-3aea-45b1-80da-9e231959c755"
        role: Admin
      - identity: "c2017801-1951-4d78-acd8-b3685b18a564"
        role: ConnectionCreator
```

### `config/environments/dev/FIN-Core-Dev.yml` — Per-Workspace File

```yaml
name: FIN-Core-Dev
description: Finance core development workspace
capacityOverride: null

items:
  repository_directory: artifacts/FIN-Core-Dev.Workspace
  parameters:
    find_replace:
      - find_value: "PLACEHOLDER_LAKEHOUSE_ID"
        replace_value: "00000000-0000-0000-0000-000000000000"
      - find_value: "PLACEHOLDER_SQL_ENDPOINT"
        replace_value: "dev-server.datawarehouse.fabric.microsoft.com"

# Workspace-specific roles (merged with shared/roles-common.yml at load time)
roles:
  - identity: "da5b8c7e-02d9-4291-8377-c4c1dfc33f5d"  # [FA] Milos Katinski
    principalType: User
    role: Admin
  - identity: "a2ae4cfb-3aea-45b1-80da-9e231959c755"   # fbrc_dev-admin
    principalType: Group
    role: Admin
  - identity: "c2017801-1951-4d78-acd8-b3685b18a564"   # fbrc_dev-developer
    principalType: Group
    role: Member
  - identity: "99744186-2ff3-4c00-b353-e8e387c84b10"   # fbrc_dev-reader
    principalType: Group
    role: Viewer

privateLink:
  plsName: ndpl-necp01-weu-fdev-fin-core-pls
  peResourceName: ndpl-necp01-weu-fdev-fin-core
```

---

## Merge Strategy

`Read-EnvironmentConfig` will assemble the final config object using a **layered merge**:

```
  shared/defaults.yml           (base)
  + shared/roles-common.yml     (common RBAC)
  + environments/{env}/_env.yml (env-level overrides + gateways)
  + environments/{env}/*.yml    (each workspace file)
  ────────────────────────────────
  = single PSCustomObject        (same shape as today)
```

### Merge Rules

| Section | Strategy |
|---------|----------|
| `environment`, `capacityName` | Taken from `_env.yml` only (required there, forbidden in workspace files). |
| `privateLinks` | `defaults.yml` fields merged with `_env.yml` fields. `_env.yml` wins on conflict. |
| `gateways` | Taken from `_env.yml` only. (Gateways are environment-scoped, not workspace-scoped.) |
| Workspace `roles` | `roles-common.yml` entries are prepended to each workspace's `roles` array. Duplicates (same `identity` + `role`) are deduplicated. A workspace can set `skipCommonRoles: true` to opt out. |
| All other workspace fields | Taken as-is from the per-workspace YAML file. |

---

## Implementation Plan

### Phase 1 — New `Read-EnvironmentConfig` Overload (No Breaking Changes)

**Changes:**

1. **New parameter**: Add `-ConfigDir` parameter to `Read-EnvironmentConfig` as an alternative to `-ConfigPath`.
   - `-ConfigPath` (existing): continues to work with a single monolithic YAML file — **zero breaking change**.
   - `-ConfigDir` (new): accepts a directory path (e.g. `config/environments/dev/`).

2. **New internal function**: `Merge-EnvironmentConfig`
   - Loads `config/shared/defaults.yml` (if it exists).
   - Loads `config/shared/roles-common.yml` (if it exists).
   - Loads `_env.yml` from the specified directory.
   - Loads every other `*.yml` file in the directory (sorted alphabetically) as workspace definitions.
   - Merges `privateLinks` from defaults + `_env.yml`.
   - Merges common roles into each workspace.
   - Validates the assembled config using existing validation logic.
   - Returns the same `PSCustomObject` shape as today.

3. **Config directory auto-detection**: If `-ConfigPath` points to a **directory** (not a file), treat it as `-ConfigDir`. This allows the pipeline template to simply update the path from `config/environments/dev.yml` to `config/environments/dev/` with no other changes.

**Files changed:**
- `src/helpers/Read-EnvironmentConfig.ps1` — add `ConfigDir` parameter, `Merge-EnvironmentConfig` function, auto-detection logic.

**Files NOT changed:**
- `Deploy-FabricEnvironment.ps1` — no change (receives same PSCustomObject).
- `Deploy-Workspaces.ps1`, `Deploy-Items.ps1`, `Deploy-Security.ps1`, etc. — no change.
- `Deploy-PrivateLinks.ps1` — no change (reads config via `Read-EnvironmentConfig`).
- `Deploy-Gateways.ps1` — no change.

### Phase 2 — Create New Config Files

1. Create `config/shared/defaults.yml` with shared `privateLinks` base settings.
2. Create `config/shared/roles-common.yml` with platform-wide RBAC identities.
3. For each existing environment (`dev`, `tst`, `prd`):
   a. Create `config/environments/{env}/` directory.
   b. Create `_env.yml` with `environment`, `capacityName`, env-specific `privateLinks` overrides, and `gateways`.
   c. Create one `<WorkspaceName>.yml` per workspace extracted from the monolithic file.
4. Keep existing monolithic files **alongside** the new split files during migration (they are still valid).

**Files created:**
- `config/shared/defaults.yml`
- `config/shared/roles-common.yml`
- `config/environments/dev/_env.yml`
- `config/environments/dev/FIN-Core-Dev.yml`
- `config/environments/dev/FIN-Reporting-Dev.yml`
- `config/environments/tst/_env.yml`
- `config/environments/tst/FIN-Core-Tst.yml`
- `config/environments/tst/FIN-Reporting-Tst.yml`
- `config/environments/prd/_env.yml`
- `config/environments/prd/Analytics-Prd.yml`
- `config/environments/prd/DataEngineering-Prd.yml`

### Phase 3 — Update Pipeline Templates

1. Update `pipelines/templates/deploy-environment.yml`:
   - Change `configFile` default from `config/environments/{env}.yml` to `config/environments/{env}/`.
2. Update `pipelines/deploy-fabric.yml` if any hardcoded paths exist.
3. Update `Deploy-PrivateLinks.ps1` pipeline step (uses its own `-ConfigFile` param).

**Files changed:**
- `pipelines/templates/deploy-environment.yml` — path default.
- `pipelines/deploy-fabric.yml` — only if hardcoded paths exist (likely none).

### Phase 4 — Update Validation & Documentation

1. Update `Validate-Deployment.ps1` to handle both file and directory config input.
2. Update `config/README.md` with new directory layout and merge behavior.
3. Update `src/README.md` parameter documentation.
4. Update `.github/skills/fabric-config-schema/SKILL.md` schema reference.
5. Update `.github/copilot-instructions.md` repository structure.

### Phase 5 — Cleanup

1. Delete the old monolithic files (`dev.yml`, `tst.yml`, `prd.yml`) after confirming all pipelines use the new directory structure.
2. Remove backward-compat `-ConfigPath` single-file code path from `Read-EnvironmentConfig` (optional — may keep for local testing convenience).

---

## Detailed Design: `Merge-EnvironmentConfig`

```powershell
function Merge-EnvironmentConfig {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigDir    # e.g. config/environments/dev/
    )

    # 1. Load shared defaults (optional)
    $sharedDir    = Join-Path (Split-Path $ConfigDir -Parent | Split-Path -Parent) 'shared'
    $defaultsFile = Join-Path $sharedDir 'defaults.yml'
    $defaults     = if (Test-Path $defaultsFile) { Get-Content $defaultsFile -Raw | ConvertFrom-Yaml } else { @{} }

    # 2. Load common roles (optional)
    $commonRolesFile = Join-Path $sharedDir 'roles-common.yml'
    $commonRoles     = if (Test-Path $commonRolesFile) {
        (Get-Content $commonRolesFile -Raw | ConvertFrom-Yaml)['roles']
    } else { @() }

    # 3. Load _env.yml (required)
    $envFile = Join-Path $ConfigDir '_env.yml'
    if (-not (Test-Path $envFile)) { throw "Missing required _env.yml in '$ConfigDir'" }
    $envConfig = Get-Content $envFile -Raw | ConvertFrom-Yaml

    # 4. Merge privateLinks: defaults ← _env.yml
    if ($defaults.ContainsKey('privateLinks') -or $envConfig.ContainsKey('privateLinks')) {
        $mergedPL = @{}
        if ($defaults['privateLinks']) { $defaults['privateLinks'].GetEnumerator() | ForEach-Object { $mergedPL[$_.Key] = $_.Value } }
        if ($envConfig['privateLinks']) { $envConfig['privateLinks'].GetEnumerator() | ForEach-Object { $mergedPL[$_.Key] = $_.Value } }
        $envConfig['privateLinks'] = $mergedPL
    }

    # 5. Load workspace files (all *.yml except _env.yml)
    $wsFiles = Get-ChildItem -Path $ConfigDir -Filter '*.yml' |
               Where-Object { $_.Name -ne '_env.yml' } |
               Sort-Object Name

    $workspaces = foreach ($f in $wsFiles) {
        $ws = Get-Content $f.FullName -Raw | ConvertFrom-Yaml

        # Merge common roles (prepend, deduplicate)
        if ($commonRoles.Count -gt 0) {
            $skipCommon = $ws.ContainsKey('skipCommonRoles') -and $ws['skipCommonRoles'] -eq $true
            if (-not $skipCommon) {
                $wsRoles    = if ($ws['roles']) { $ws['roles'] } else { @() }
                $existingIds = $wsRoles | ForEach-Object { "$($_.identity)|$($_.role)" }
                $merged      = @($commonRoles | Where-Object { "$($_.identity)|$($_.role)" -notin $existingIds })
                $merged     += $wsRoles
                $ws['roles'] = $merged
            }
            $ws.Remove('skipCommonRoles')  # internal flag, not passed downstream
        }

        $ws  # emit
    }

    $envConfig['workspaces'] = @($workspaces)

    # 6. Convert to PSCustomObject (same as existing code path)
    $json = $envConfig | ConvertTo-Json -Depth 20
    return $json | ConvertFrom-Json -Depth 20
}
```

---

## Detailed Design: Updated `Read-EnvironmentConfig`

```powershell
function Read-EnvironmentConfig {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ConfigPath
    )

    # Auto-detect: if path is a directory, use split-file loader
    if (Test-Path $ConfigPath -PathType Container) {
        $config = Merge-EnvironmentConfig -ConfigDir $ConfigPath
    } elseif (Test-Path $ConfigPath -PathType Leaf) {
        # Existing single-file code path (unchanged)
        $raw    = Get-Content -Path $ConfigPath -Raw
        $config = ($raw | ConvertFrom-Yaml) | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
    } else {
        throw "Config path not found: $ConfigPath"
    }

    # ── Validation (unchanged, runs on assembled config regardless of source) ──
    # ... existing validation logic ...

    return $config
}
```

The key insight: the `-ConfigFile` parameter in `Deploy-FabricEnvironment.ps1` and pipeline templates **does not need to change name** — it just accepts either a file path or a directory path. The coalesce expression in the pipeline template changes from:

```yaml
# Before
format('config/environments/{0}.yml', parameters.environment)
# After
format('config/environments/{0}/', parameters.environment)
```

---

## Migration Path (Zero Downtime)

| Step | Pipeline uses | Config source | Risk |
|------|--------------|---------------|------|
| 1. Merge Phase 1 PR | `dev.yml` (monolithic) | Old single file | None — new code reads both formats |
| 2. Merge Phase 2 PR | `dev.yml` | Old file still works; new split files exist alongside | None |
| 3. Merge Phase 3 PR | `dev/` (directory) | New split files | Low — one pipeline config change per env |
| 4. Validate all envs | `dev/`, `tst/`, `prd/` | New split files | Test cycle |
| 5. Merge Phase 5 PR | `dev/`, `tst/`, `prd/` | Delete old monolithic files | None — no longer referenced |

Each step can be merged and tested independently. Rollback is trivial: revert the pipeline path change.

---

## Testing Strategy

1. **Unit test**: Call `Merge-EnvironmentConfig` with a test directory structure and assert the output matches the expected PSCustomObject (same shape as from monolithic file).
2. **Regression test**: Load old monolithic `dev.yml` and new split `dev/` directory, compare the two PSCustomObjects — they must be identical (minus property order).
3. **Pipeline dry-run**: Run the pipeline with `-WhatIf` against the split config directory before cutting over.
4. **Validate-Deployment.ps1**: Existing NUnit tests pass unchanged (they receive the same config object).

---

## Effort Estimate

| Phase | Scope | Complexity |
|-------|-------|------------|
| Phase 1 | `Read-EnvironmentConfig.ps1` (~100 new lines) | Medium |
| Phase 2 | Create ~12 YAML files (mechanical extraction) | Low |
| Phase 3 | Pipeline template path change (2 lines) | Low |
| Phase 4 | Documentation updates | Low |
| Phase 5 | Delete 3 files | Trivial |

---

## Open Questions

1. **File naming**: Should workspace files use the workspace name exactly (`FIN-Core-Dev.yml`) or a kebab-case slug (`fin-core-dev.yml`)? Recommendation: exact name for grep-ability.
2. **Partial override of common roles**: Should `roles-common.yml` support per-environment overrides (e.g. different deployment SPN per env)? Current design only supports global common roles. If per-env common roles are needed, we can add `config/environments/{env}/_roles.yml`.
3. **Workspace ordering**: Should the alphabetical file-loading order matter? Current design: no — workspace ordering is irrelevant to deployment semantics.
4. **Gateway definitions**: Currently gateways live at environment level. Should they get their own files too (`_gateways.yml`)? Recommendation: keep in `_env.yml` unless gateway count grows significantly.
