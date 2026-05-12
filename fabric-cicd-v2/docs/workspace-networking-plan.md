# Workspace Networking Configuration Plan

## Objective

Automate Fabric workspace network settings (inbound and outbound connectivity) as part of the `fabric-cicd-v2` deployment pipeline using the Fabric CLI (`fab`).

## Approach

The Fabric CLI does not have dedicated commands for workspace networking, but the `fab api` command provides authenticated access to the full Fabric REST API. This is the same tool already used throughout the project for workspace, item, and security deployments.

## Fabric REST API Endpoints

All endpoints are relative to `https://api.fabric.microsoft.com/v1/`.

| Operation | Method | Endpoint |
|---|---|---|
| Get network communication policy | `GET` | `workspaces/{workspaceId}/networking/communicationPolicy` |
| Set network communication policy | `PUT` | `workspaces/{workspaceId}/networking/communicationPolicy` |
| Get inbound Azure resource rules | `GET` | `workspaces/{workspaceId}/networking/communicationPolicy/inbound/azureResources` |
| Set inbound Azure resource rules | `PUT` | `workspaces/{workspaceId}/networking/communicationPolicy/inbound/azureResources` |
| Get outbound cloud connection rules | `GET` | `workspaces/{workspaceId}/networking/communicationPolicy/outbound/cloudConnections` |
| Set outbound cloud connection rules | `PUT` | `workspaces/{workspaceId}/networking/communicationPolicy/outbound/cloudConnections` |
| Get outbound gateway rules | `GET` | `workspaces/{workspaceId}/networking/communicationPolicy/outbound/gateways` |
| Set outbound gateway rules | `PUT` | `workspaces/{workspaceId}/networking/communicationPolicy/outbound/gateways` |
| Get Git outbound policy | `GET` | `workspaces/{workspaceId}/networking/communicationPolicy/outbound/git` |
| Set Git outbound policy | `PUT` | `workspaces/{workspaceId}/networking/communicationPolicy/outbound/git` |

### Permissions Required

- Caller must have **admin** workspace role.
- Delegated scope: `Workspace.ReadWrite.All`.
- Supports: User, Service Principal, and Managed Identity.

### Important Caveats

- The `PUT` on `communicationPolicy` **overwrites all settings**. Always call `GET` first and provide the full policy in the request body.
- If `defaultAction` is omitted from the PUT body, it defaults to `Allow`, which may unintentionally open network access. Always explicitly specify `defaultAction`.
- The inbound Azure resource rules API is currently in **Preview**.

## fab CLI Usage

```bash
# Get current policy
fab api workspaces/<workspaceId>/networking/communicationPolicy

# Set policy (deny inbound and outbound public access)
fab api -X put workspaces/<workspaceId>/networking/communicationPolicy \
  -i '{"inbound":{"publicAccessRules":{"defaultAction":"Deny"}},"outbound":{"publicAccessRules":{"defaultAction":"Deny"}}}'

# Set inbound Azure resource allowlist
fab api -X put workspaces/<workspaceId>/networking/communicationPolicy/inbound/azureResources \
  -i '{"rules":[{"displayName":"SQL Server - mysql","resourceId":"/subscriptions/.../Microsoft.Sql/servers/mysql"}]}'
```

Via `Invoke-FabCli` (PowerShell):

```powershell
# Get current policy
$result = Invoke-FabCli -Arguments @(
    'api', "workspaces/$wsId/networking/communicationPolicy"
)

# Set policy
$policyJson = @{
    inbound  = @{ publicAccessRules = @{ defaultAction = 'Deny' } }
    outbound = @{ publicAccessRules = @{ defaultAction = 'Deny' } }
} | ConvertTo-Json -Depth 5 -Compress

Invoke-FabCli -Arguments @(
    'api', '-X', 'put',
    "workspaces/$wsId/networking/communicationPolicy",
    '-i', $policyJson
)
```

## Implementation Plan

### 1. Config Schema — Add `networking` block per workspace

Extend the environment YAML config (e.g. `config/environments/dev.yml`) with a `networking` block under each workspace:

```yaml
workspaces:
  - name: FIN-Core-Dev
    # ... existing items, roles, privateLink blocks ...

    networking:
      inbound:
        defaultAction: Deny   # Allow | Deny
        azureResourceRules:
          - displayName: "SQL Server - devsql"
            resourceId: "/subscriptions/.../Microsoft.Sql/servers/devsql"
          - displayName: "Storage Account - devsa"
            resourceId: "/subscriptions/.../Microsoft.Storage/storageAccounts/devsa"
      outbound:
        defaultAction: Deny   # Allow | Deny
```

### 2. New Script — `Deploy-NetworkPolicy.ps1`

Create `src/scripts/Deploy-NetworkPolicy.ps1` following the same pattern as `Deploy-Security.ps1`:

- Accept `$Config`, `$WorkspaceMap`, `$Environment` parameters.
- For each workspace with a `networking` block:
  1. GET current policy (to log current state).
  2. PUT the full communication policy (inbound + outbound `defaultAction`).
  3. If `azureResourceRules` are defined, PUT the inbound Azure resource rules.
- Use `Invoke-FabCli` with `fab api` for all calls.

### 3. Orchestrator Integration

Add `'networking'` to the `$Scope` validation set in `Deploy-FabricEnvironment.ps1` and invoke `Deploy-NetworkPolicy.ps1` between security and private links steps.

### 4. Pipeline Integration

Add the networking scope to `deploy-environment.yml` template's scope parameter values.

### 5. Validation

Extend `Validate-Deployment.ps1` to verify network policy matches desired state after deployment.

## References

- [Fabric Managed Virtual Networks](https://learn.microsoft.com/en-us/fabric/security/security-managed-vnets-fabric-overview)
- [Fabric REST API — Workspaces](https://learn.microsoft.com/en-us/rest/api/fabric/core/workspaces)
- [Fabric CLI — API Command](https://microsoft.github.io/fabric-cli/commands/api/)
- [Fabric CLI — API Examples](https://microsoft.github.io/fabric-cli/examples/api_examples/)
