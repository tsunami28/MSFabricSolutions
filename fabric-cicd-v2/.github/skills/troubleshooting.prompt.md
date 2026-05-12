---
description: "Troubleshoot fabric-cicd-v2 deployment failures. Use when debugging Fabric CLI errors, authentication issues, pipeline failures, or configuration problems."
---

# Deployment Troubleshooting

## Common Failure Modes

### 1. Authentication Failures (Exit Code 2)

**Symptoms:** `fab auth login` fails, or subsequent commands return exit code 2.

**Checks:**
- Verify service principal credentials (ClientId, ClientSecret, TenantId)
- Confirm the SPN has Fabric Admin or workspace-scoped permissions
- Check if the client secret has expired
- For managed identity: ensure the agent VM has system-assigned MI enabled

**Resolution:**
```powershell
# Test auth manually
fab auth login --client-id $clientId --client-secret $secret --tenant-id $tenantId
fab ls  # should list workspaces
```

### 2. Workspace Creation Conflicts

**Symptoms:** `fab mkdir` returns error despite `fab exists` returning false.

**Cause:** The service principal lacks read permissions on an existing workspace with the same name.

**Resolution:** Grant the SPN at least Viewer role on the workspace, or use a Fabric Admin SPN.

### 3. Item Deployment Failures

**Symptoms:** `fab deploy` returns non-zero exit.

**Checks:**
- Verify `repository_directory` exists and contains valid item folders
- Each item folder must have a `.platform` file
- Check `find_replace` values — invalid JSON in item definitions after replacement
- Ensure item types are supported by the current `fab` version

### 4. RBAC Failures

**Symptoms:** `fab acl set` or `fab acl rm` fails.

**Checks:**
- Verify identity GUIDs are valid Entra Object IDs
- Confirm the deploying SPN has Admin role on the target workspace
- Check that role names are valid: Admin, Member, Contributor, Viewer

### 5. Private Link Failures

**Symptoms:** Bicep deployment for PLS/PE fails.

**Checks:**
- Verify subnet ID and DNS zone ID are correct ARM resource paths
- Confirm the Azure service connection has Contributor on the target resource group
- Check that `workspace-map.json` was properly generated in the previous step

### 6. Config Validation Errors

**Symptoms:** Script fails at `Read-EnvironmentConfig` with missing field errors.

**Resolution:** Check the YAML file against required schema:
```yaml
environment: dev|tst|prd     # Required
capacityName: <name>          # Required
workspaces:                   # Required, at least one entry
  - name: <string>            # Required per workspace
```

### 7. Pipeline Variable Issues

**Symptoms:** Downstream tasks don't receive workspace map or other outputs.

**Checks:**
- Verify `##vso[task.setvariable variable=VarName;isOutput=true]` syntax
- Confirm task `name:` is set (required for output variables)
- Reference as `$(TaskName.VarName)` in same job or `$[dependencies.JobName.outputs['TaskName.VarName']]` cross-job

## Diagnostic Commands

```powershell
# Check fab version
fab --version

# Test connectivity
fab auth login --client-id $id --client-secret $secret --tenant-id $tenant
fab ls --output_format json

# Verbose deployment (see all fab commands)
$VerbosePreference = 'Continue'
.\Deploy-FabricEnvironment.ps1 -ConfigFile ... -Environment dev ...

# Validate config without deploying
. src/helpers/Read-EnvironmentConfig.ps1
Read-EnvironmentConfig -ConfigPath 'config/environments/dev.yml'
```

## Retry Behavior

The `Invoke-FabCli` helper implements exponential backoff:
- Default: 3 retries with base 2 (delays: 2s, 4s, 8s)
- Exit code 2 (auth): **never retried** — requires re-auth
- Exit code 0: success, no retry
- All other codes: retried up to MaxRetries
