# fabric-cicd-v3 — Code Review: Improvement Plan

Organized by severity. Each item names the affected file(s), describes the problem, and states the fix.

---

## 🔴 Critical — Bugs / Data Loss / Security

### 1. `New-FabDeployConfig.ps1` — `item_types_in_scope` YAML indentation is invalid

**Problem.** The generated list items are not indented under the key:

```yaml
# Generated (wrong)
core:
  item_types_in_scope:
  - Notebook          ← should be indented relative to the key
```

The `$typeEntries` strings are prefixed with `"  - "` and `$itemTypeLines` is further prefixed with `"  "` in the here-string, but the list items never get the combined 4-space indent required to sit under `core.item_types_in_scope`.

**Fix.** Prefix each entry with 4 spaces so the output is valid YAML:

```powershell
$typeEntries  = $ItemTypesInScope | ForEach-Object { "    - $_" }   # 4 spaces
$itemTypeLines = "item_types_in_scope:`n$($typeEntries -join "`n")"
```

---

### 2. `Deploy-PrivateLinks.ps1` — Wrong token scope for Fabric REST API - DONE

**Problem.** Phase 2 (network communication policy) calls `GET/PUT https://api.fabric.microsoft.com/v1/workspaces/…` but acquires the token with the Power BI scope:

```powershell
scope = 'https://analysis.windows.net/powerbi/api/.default'
```

The Fabric REST API requires `https://api.fabric.microsoft.com/.default`. This will silently succeed on tenants where both APIs share a token cache, but is semantically wrong and can fail.

**Fix.** Add a dedicated Fabric token acquisition alongside the existing Power BI one, and use it for the `$fabricHeaders`:

```powershell
function Get-FabricToken {
    param([string]$TenantId, [string]$ClientId, [string]$ClientSecret)
    $response = Invoke-RestMethod -Method Post `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -Body @{
            grant_type    = 'client_credentials'
            client_id     = $ClientId
            client_secret = $ClientSecret
            scope         = 'https://api.fabric.microsoft.com/.default'
        }
    return $response.access_token
}
```

---

### 3. `Deploy-LogAnalytics.ps1` — SPN token payload logged to pipeline output - DONE

**Problem.** The script decodes the JWT and writes the raw token payload to `Write-Host`:

```powershell
$parts   = $pbiToken.Split('.')
$payload = [System.Text.Encoding]::UTF8.GetString(...)
Write-Host "  Token payload: $payload"   # ← exposes token claims in plain text
```

Token claims (`oid`, `roles`, `tid`, `appid`) are logged to the ADO pipeline log, which may be retained and accessible to pipeline readers.

**Fix.** Remove the three lines entirely. They are debug artefacts from the SPN auth investigation.

---

### 4. `deploy-environment.yml` — `Deploy-PrivateLinks.ps1` called without SPN credentials - DONE

**Problem.** The AzurePowerShell@5 task does not pass `-ClientId`, `-ClientSecret`, `-TenantId` to `Deploy-PrivateLinks.ps1`:

```yaml
ScriptArguments: >-
  -ConfigFile       "..."
  -WorkspaceMapFile "..."
  -TemplateFile     "..."
  -ResourceGroupName "..."
  # ← SPN params missing
```

Phase 2 of `Deploy-PrivateLinks.ps1` (network communication policy) requires these credentials. Any workspace with `denyPublicAccess: true` will throw at runtime.

**Fix.** Add the three credential parameters to `ScriptArguments`:

```yaml
ScriptArguments: >-
  -ConfigFile        "..."
  -WorkspaceMapFile  "..."
  -TemplateFile      "..."
  -ResourceGroupName "${{ parameters.resourceGroupName }}"
  -ClientId          "${{ parameters.clientId }}"
  -ClientSecret      "${{ parameters.clientSecret }}"
  -TenantId          "${{ parameters.tenantId }}"
```

---

## 🟠 High — Broken Patterns / Bypassed Wrappers

### 5. `Deploy-Workspaces.ps1` — Direct `fab ls` call, unescaped regex - DONE

**Problem.** The existence check calls `fab` directly (bypassing `Invoke-FabCli`) and uses an unescaped regex match:

```powershell
$allDeployedWorkspaces = fab ls                                     # bypasses wrapper
if ($allDeployedWorkspaces -match "$wsName.Workspace") {            # '.' matches any char
```

The `.` in `"$wsName.Workspace"` is a regex wildcard — `FIN-Core-Dev-Workspace`, `FIN-CoreXDev.Workspace`, etc. would all match. This is the same pattern flagged in `Deploy-Gateways.ps1` and fixed in `Validate-Deployment.ps1` (which uses `[regex]::Escape`).

**Fix.** Use `Invoke-FabCli` and escape the match string:

```powershell
$allDeployedWorkspaces = (Invoke-FabCli -Arguments @('ls') -MaxRetries 2).Output
$wsFabPath = "$wsName.Workspace"
if ($allDeployedWorkspaces -match [regex]::Escape($wsFabPath)) {
```

---

### 6. `Deploy-Gateways.ps1` — Same direct `fab ls` + unescaped regex - DONE

Identical issue to item 5, in `Deploy-Gateways.ps1`:

```powershell
$allDeployedGateways = fab ls .gateways         # bypasses wrapper
if ($allDeployedGateways -match $gwName) {       # unescaped — partial name matches
```

**Fix.** Same pattern — wrap and escape:

```powershell
$allDeployedGateways = (Invoke-FabCli -Arguments @('ls', '.gateways') -MaxRetries 2).Output
$gwFabName = "$gwName.Gateway"
if ($allDeployedGateways -match [regex]::Escape($gwFabName)) {
```

---

### 7. `Deploy-FabricEnvironment.ps1` — Debug lines left in production at step 8 - DONE

**Problem.** The gateway deployment step contains hardcoded debug output that calls `fab` directly:

```powershell
Write-Host "Check if SPN can see GW:"
fab ls .gateways -l                   # direct call, bypasses wrapper, not removed
Write-Host ""
```

This outputs raw gateway listing to every pipeline run and calls `fab` outside the wrapper (no retry, no error handling).

**Fix.** Remove both `Write-Host "Check if SPN can see GW:"` and `fab ls .gateways -l` entirely.

---

### 8. `Deploy-FabricEnvironment.ps1` — Step counter inconsistency - DONE

**Problem.** Steps 1–3 are labelled `[x/10]` and steps 4–11 are labelled `[x/11]`. There are 11 actual steps.

**Fix.** Renumber all step headers to `[1/11]` through `[11/11]`.

---

### 9. `deploy-environment.yml` — `connections` scope value missing from parameter list - DONE

**Problem.** The orchestrator's `-Scope` `[ValidateSet]` includes `connections` but the pipeline template does not:

```yaml
# deploy-environment.yml
values: [all, workspaces, items, security, privatelinks, gitintegration, gateways, loganalytics]
#         ↑ 'connections' missing
```

Passing `scope: connections` from a pipeline will silently use the default (`all`) instead.

**Fix.** Add `connections` to the values list in `deploy-environment.yml`.

---

## 🟡 Medium — Dead Code / Duplication / Maintainability

### 10. `Deploy-LogAnalytics.ps1` — Two functions defined but never called

`Get-FabApiResponseText` and `Get-LawDetails` are defined in the script but the live code path uses `Invoke-RestMethod` directly and never calls either function. They are carry-overs from an earlier `fab api`-based implementation.

**Fix.** Remove both function definitions.

---

### 11. `Deploy-Connections.ps1` — `Validate-FabConnectionPayload` checks conditions the builder never produces - DONE

The validator checks for `creationMethod` mismatches and `path` being present — both of which the payload builder explicitly avoids. These checks can never fire against a payload produced by the same script.

**Fix.** Either remove the function entirely, or replace the body with checks that actually guard the current payload structure (e.g., verify `parameters` array is non-empty, verify `url` parameter exists).

---

### 12. ACL output unwrapping logic is duplicated in three scripts

The pattern for normalising `fab acl get` output (handling both wrapped and unwrapped envelope formats) is copy-pasted across:

- `Deploy-Security.ps1`
- `Deploy-Gateways.ps1`
- `Validate-Deployment.ps1`

**Fix.** Extract to a shared helper function `ConvertFrom-FabAclOutput` in `Invoke-FabCli.ps1` (or a new `Get-FabAclEntries.ps1` helper). Each script dot-sources it instead of repeating the logic.

---

### 13. `Deploy-Security.ps1` — Debug-level output uses `Write-Host` - DONE

```powershell
Write-Host " Identity $identity has existing assignment: $($existingRole ?? 'None')"
```

This is internal state, not an actionable progress message. Per the established pattern (`Write-Verbose` for internal state, `Write-Host` for actionable progress), this should be `Write-Verbose`. It also has an off-by-one leading space.

**Fix.** Change to `Write-Verbose "    Identity $identity has existing assignment: $($existingRole ?? 'None')"`.

---

### 14. `Deploy-Security.ps1` — Role comparison is case-sensitive; `acl set` uses lowercase - DONE

The comparison `$existingRole -eq $desiredRole` is case-sensitive. The API may return `admin` (lowercase) while config defines `Admin` (title-case). The `acl set` call already applies `.ToLower()`, so the comparison should too.

**Fix.**

```powershell
if ($existing -and $existingRole.ToLower() -eq $desiredRole.ToLower()) {
```

---

### 15. `Read-EnvironmentConfig.ps1` — `logAnalytics` validator does not check `tenantId`

`dev.yml` defines a `tenantId` field under `logAnalytics`, and `Deploy-LogAnalytics.ps1` passes it as a parameter. The validator only checks `subscriptionId`, `resourceGroupName`, and `workspaceName` — so a missing `tenantId` passes validation and causes a runtime failure in `Get-PowerBIAdminToken`.

**Fix.** Add `tenantId` to the validated fields:

```powershell
foreach ($field in @('tenantId', 'subscriptionId', 'resourceGroupName', 'workspaceName')) {
```

---

### 16. `Read-EnvironmentConfig.ps1` — `inboundFirewallRules` validated at wrong location

The validator checks for `inboundFirewallRules` as a **top-level** config key. But `Deploy-PrivateLinks.ps1` reads it from `$plConfig.inboundFirewallRules` — i.e., **under `privateLinks`**. The validator will never find rules defined where they're actually used.

**Fix.** Move the firewall rule validation to run against `$config['privateLinks']` when that block is present:

```powershell
if ($config.ContainsKey('privateLinks') -and $config['privateLinks'] -and
    $config['privateLinks'].ContainsKey('inboundFirewallRules') -and
    $null -ne $config['privateLinks']['inboundFirewallRules']) {
    # validate rules here
}
```

And remove the orphaned top-level `inboundFirewallRules` validation block.

---

### 17. `Deploy-Connections.ps1` — `AzureKeyVault` type declared in schema but not implemented - DONE

`Read-EnvironmentConfig.ps1` allows `type: AzureKeyVault` in the connections block. `Deploy-Connections.ps1` hits the `default` branch and throws. This creates a confusing experience where config validation passes but deployment fails.

**Fix.** Either implement `AzureKeyVault` connection creation, or remove `AzureKeyVault` from the `$validConnTypes` list in `Read-EnvironmentConfig.ps1` until it is implemented. Add a `# TODO` comment if deferring.

---

### 18. `Deploy-Gateways.ps1` — Gateway PATCH uses raw `Invoke-FabCli` instead of `Invoke-FabApiCall`

The settings update PATCH:

```powershell
Invoke-FabCli -Arguments @('api', '-X', 'patch', "gateways/$gwId", '-i', $patchJson) | Out-Null
```

This ignores the HTTP status code embedded in the response (fab exits 0 for 4xx). `Deploy-Connections.ps1` introduced `Invoke-FabApiCall` specifically to handle this. `Deploy-Gateways.ps1` should use it.

**Fix.** Dot-source `Deploy-Connections.ps1`'s `Invoke-FabApiCall` — or move the helper to `Invoke-FabCli.ps1` so all scripts can use it — then replace the raw call:

```powershell
Invoke-FabApiCall -Arguments @('api', '-X', 'patch', "gateways/$gwId", '-i', $patchJson) `
    -OpDesc "PATCH gateway settings for '$gwName'" | Out-Null
```

---

## 🔵 Low — Minor Issues / Consistency

### 19. `Deploy-FabricEnvironment.ps1` — `$WhatIf` parameter declared but never used - DONE

`-WhatIf` is a declared parameter but is not passed to any sub-script or conditional block inside the orchestrator.

**Fix.** Either pass it to `Deploy-PrivateLinks.ps1` (which has `-WhatIfMode`) or remove the parameter from the orchestrator if it is not intended to cascade.

---

### 20. `docs/PowerBiAdminApi-SPNAccessPattern.md` — File is a PowerShell script, not markdown - DONE

The file starts with `#Requires -Version 7.0` and contains only PowerShell code. It appears to be an earlier draft of `Deploy-LogAnalytics.ps1` saved with the wrong extension. The regional endpoint discovery logic (`Get-PowerBIRegionalBaseUrl`) in this file is **not present** in the production script.

**Fix.** Rename to `Deploy-LogAnalytics-regional-variant.ps1` or delete if superseded. If the regional endpoint fallback strategy is still wanted, port `Get-PowerBIRegionalBaseUrl` into the production script.

---

### 21. `Merge-EnvironmentConfig` path resolution assumes fixed 3-level directory depth

```powershell
$envParent  = Split-Path $dirPath  -Parent   # config/environments
$configRoot = Split-Path $envParent -Parent   # config
$sharedDir  = Join-Path  $configRoot 'shared'
```

This works for `config/environments/dev/` but breaks for any other layout (e.g., the current `parameters/necp01/weu/dev/` structure used in production).

**Fix.** Accept a `-SharedDir` parameter on `Merge-EnvironmentConfig`, or make the shared dir location configurable, rather than deriving it by walking up a fixed number of levels.

---

## Suggested Work Order

| Step | Items | Effort |
|------|-------|--------|
| 1 — Fix silent failures | 1, 2, 4 | Small |
| 2 — Remove debug/sensitive output | 3, 7, 13 | Trivial |
| 3 — Fix wrapper bypasses | 5, 6, 8, 9 | Small |
| 4 — Validation correctness | 15, 16, 17 | Small |
| 5 — Dead code cleanup | 10, 11, 19, 20 | Trivial |
| 6 — Shared helper extraction | 12, 18 | Medium |
| 7 — Consistency / minor | 14, 21 | Small |