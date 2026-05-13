---
name: fabric-cli-patterns
description: 'Fabric CLI (fab) command patterns, exit codes, retry logic, and auth modes specific to fabric-cicd-v2. Use when asking about fab commands, Invoke-FabCli, exit code 2, fab deploy errors, fab acl, fab api, fab exists, fab auth, fab mkdir, JSON output parsing, AllowNonZeroExit, audience flags, or Fabric CLI troubleshooting.'
---

# Fabric CLI Command Patterns

Domain knowledge for the `fab` (ms-fabric-cli) commands as used by fabric-cicd-v2. All `fab` calls go through the `Invoke-FabCli` wrapper in `src/helpers/Invoke-FabCli.ps1`.

## Invoke-FabCli Wrapper

Every `fab` command in this project is called via `Invoke-FabCli`, never directly. The wrapper provides:

- **Stdout/stderr capture** via temp files (not pipeline redirection)
- **Automatic JSON parsing** when `--output_format json` is in the arguments
- **Structured return object** with `.ExitCode`, `.Output`, `.Stderr`
- **Exponential backoff retry** for transient failures
- **Verbose logging** of every command invocation

### Return Object

```powershell
[PSCustomObject]@{
    ExitCode = [int]     # fab process exit code
    Output   = [object]  # parsed JSON (PSCustomObject/array) or raw stdout string
    Stderr   = [string]  # stderr content (populated on errors)
}
```

## Exit Code Semantics

| Code | Meaning | Retriable | Action |
|------|---------|-----------|--------|
| 0 | Success | N/A | Return result |
| 1 | General error | **Yes** | Retry with exponential backoff |
| 2 | Authentication error | **No** — never retry | Throw immediately; user must re-auth |
| 3+ | Other errors | **Yes** | Retry with exponential backoff |

### Retry Strategy

- Default: 3 retries, backoff base 2 → delays of 2s, 4s, 8s
- Configurable via `-MaxRetries` and `-RetryBackoffBase`
- Auth errors (exit 2) short-circuit immediately — no retry ever

## Authentication

Two mutually exclusive methods. Auth is performed once in `Deploy-FabricEnvironment.ps1` step 1, then cached for the session.

### Service Principal (typical for ADO pipelines)

```powershell
Invoke-FabCli -Arguments @('auth', 'login', '-u', $ClientId, '-p', $ClientSecret, '--tenant', $TenantId) -MaxRetries 0
```

### Managed Identity

```powershell
# System-assigned
Invoke-FabCli -Arguments @('auth', 'login', '--identity') -MaxRetries 0

# User-assigned
Invoke-FabCli -Arguments @('auth', 'login', '--identity', '-u', $ManagedIdentityClientId) -MaxRetries 0
```

### Pre-Auth Setup (ADO agents)

ADO agents lack keyring/DPAPI — enable plaintext token cache fallback:

```powershell
Invoke-FabCli -Arguments @('auth', 'logout') -AllowNonZeroExit -MaxRetries 0 | Out-Null
Invoke-FabCli -Arguments @('config', 'set', 'encryption_fallback_enabled', 'true') -MaxRetries 0 | Out-Null
```

## Common Command Patterns

### Check If a Resource Exists

`fab exists` returns exit code 1 for "not found" — this is NOT an error. Always use `-AllowNonZeroExit`:

```powershell
$result = Invoke-FabCli -Arguments @('exists', "$wsName.Workspace") -AllowNonZeroExit
$exists = $result.ExitCode -eq 0
```

**Never** call `fab exists` without `-AllowNonZeroExit` — it will throw on "not found".

### Create a Workspace

```powershell
Invoke-FabCli -Arguments @('mkdir', "$wsName.Workspace", '-P', "capacityname=$capacityName")
```

### Get Workspace GUID

```powershell
$wsId = (Invoke-FabCli -Arguments @('get', "$wsName.Workspace", '-q', 'id')).Output.Trim()
```

Note: `-q id` returns a bare GUID string, not JSON.

### List Resources as JSON

```powershell
$result = Invoke-FabCli -Arguments @('ls', '--output_format', 'json')
$result.Output  # already parsed PSCustomObject / array
```

When `--output_format json` is detected in arguments, `Invoke-FabCli` auto-parses with `ConvertFrom-Json`.

### Deploy Items

```powershell
$configPath = New-FabDeployConfig -WorkspaceName $wsName -ItemConfig $itemConfig -RepoRoot $RepoRoot
Invoke-FabCli -Arguments @('deploy', '--config', $configPath, '-f')
```

The `-f` flag means force (overwrite existing items).

### RBAC Operations

```powershell
# Get current ACLs
$aclResult = Invoke-FabCli -Arguments @('acl', 'get', "$wsName.Workspace", '--output_format', 'json')

# Set a role
Invoke-FabCli -Arguments @('acl', 'set', "$wsName.Workspace", '-I', $identity, '-R', $role)

# Remove a role (-f = force, no confirmation)
Invoke-FabCli -Arguments @('acl', 'rm', "$wsName.Workspace", '-I', $identity, '-f')
```

### Fabric REST API Calls

```powershell
# Fabric API (default audience)
Invoke-FabCli -Arguments @('api', '-X', 'GET', '/v1/workspaces', '--output_format', 'json')

# Power BI Admin API (different audience)
Invoke-FabCli -Arguments @('api', '-A', 'powerbi', '-X', 'PUT', '/admin/workspaces/...')
```

**Audience flags:**
- `-A fabric` (default) — Fabric API endpoints (`/v1/...`)
- `-A powerbi` — Power BI Admin API endpoints (`/admin/...`) — used for Log Analytics connection, tenant settings

### Update Workspace Description

```powershell
Invoke-FabCli -Arguments @('api', '-X', 'patch', "/v1/workspaces/$wsId", '-b', $bodyJson, '--output_format', 'json')
```

## Common Pitfalls

1. **Forgetting `-AllowNonZeroExit` on `fab exists`** — throws on "not found"
2. **Wrapping auth in retry logic** — exit code 2 should never be retried; use `-MaxRetries 0` for auth calls
3. **Single-item JSON arrays** — `ConvertFrom-Json` may return a bare object; wrap in `@()` if you need an array
4. **`-q` flag returns raw string** — not JSON, not wrapped in object; `.Output.Trim()` to get clean GUID
5. **`fab api -X PUT` requires full object** — not partial PATCH; construct the complete JSON body
6. **Rate limiting on Power BI Admin API** — 200 requests/hour; plan batch operations accordingly
