# Authentication Design

## Summary

Every environment uses a dedicated **User-Assigned Managed Identity (UAMI)**. The Azure DevOps pipeline uses that identity to obtain tokens, and the PowerShell scripts use those tokens to call both Az.Accounts-based helpers and the Fabric REST API. No passwords, client secrets, or certificates are stored anywhere.

---

## Token Flow

```
Azure DevOps Agent
│
├── AzurePowerShell@5 task
│     Service connection: sc-fabric-{env}
│     ↓
│     Connect-AzAccount  (called automatically by the task)
│         Identity: User-Assigned MI (fabric-{env}-mi)
│         Establishes Az.Accounts session in the PowerShell runspace
│
└── Deploy-FabricEnvironment.ps1  (runs in the same runspace)
      │
      ├── Set-FabricApiHeaders
      │     -TenantId            $(fabricTenantId)
      │     -UseManagedIdentity
      │     -ManagedIdentityId   $(managedIdentityClientId)
      │     ↓
      │     Internally calls Get-AzAccessToken for the Fabric resource URL
      │     Stores auth context in MicrosoftFabricMgmt module state
      │     All subsequent module cmdlets (Get-FabricWorkspace, etc.) use this context
      │
      └── Invoke-FabricRestMethod.ps1  (dot-sourced)
            ↓
            Get-AzAccessToken
              -ResourceUrl 'https://analysis.windows.net/powerbi/api'
              -AsSecureString
            ↓
            Bearer token used in Authorization header
            Token is fetched fresh on every call - Az.Accounts caches and
            auto-renews it, so there is no expiry risk on long deployments
```

---

## Why One Identity Per Environment

| Concern | How it is addressed |
|---|---|
| **Blast radius** | A compromised dev identity cannot touch tst or prd resources |
| **Audit trail** | Fabric audit logs show `fabric-dev-mi` / `fabric-tst-mi` / `fabric-prd-mi` as distinct actors |
| **Least privilege** | Each UAMI is granted access only to the capacities and workspaces for its environment |
| **Secret rotation** | UAMIs use workload identity federation - no secrets to rotate |

---

## Why AzurePowerShell@5 (Not a Plain PowerShell Task)

The `AzurePowerShell@5` task does two things a plain `PowerShell@2` task cannot:

1. Calls `Connect-AzAccount` using the service connection's federated credential - no token handling in script code
2. Passes the established Az.Accounts session into the child PowerShell process, so `Get-AzAccessToken` works transparently in all scripts that run within the same task step

> **Session boundary**: Az.Accounts session state does **not** persist across separate task steps. The orchestrator script (`Deploy-FabricEnvironment.ps1`) is designed to call all sub-scripts (`Deploy-Workspaces.ps1`, `Deploy-Items.ps1`, `Deploy-Security.ps1`) within the **same** `AzurePowerShell@5` task step to avoid re-authentication overhead and session isolation issues.

---

## Managed Identity Permissions Required

For each UAMI, a Fabric admin must grant:

1. **Fabric tenant setting** - `Admin portal → Tenant settings → Developer settings → Service principals can use Fabric APIs` must be enabled (can be scoped to a security group)
2. **Workspace access** - The UAMI (or a group it belongs to) must have at minimum the **Admin** role on every workspace it will create or modify
3. **Capacity access** - The UAMI must be a **Capacity Admin** or **Capacity Contributor** on the Fabric capacity it assigns workspaces to

> If the UAMI only needs to read and not create workspaces in a given environment, **Member** access is sufficient. The pipeline's scripts use `New-FabricWorkspace`, which requires Admin.

---

## Token Acquisition - Technical Detail

`Set-FabricApiHeaders` (from MicrosoftFabricMgmt) and `Invoke-FabricRestMethod` both call:

```powershell
Get-AzAccessToken `
    -ResourceUrl  'https://analysis.windows.net/powerbi/api' `
    -AsSecureString `
    -ErrorAction  Stop
```

The returned `SecureString` token is converted to a plain string only at the point of use in the `Authorization: Bearer …` header. The plain string is not assigned to a variable and is not logged.

Az.Accounts automatically refreshes the cached token before it expires (typically 1-hour window), so long deployment runs spanning multiple API calls work without re-authentication.

---

## Service Connection Configuration in ADO

Each service connection is of type **Azure Resource Manager → Workload identity federation (manual)**:

| Field | Value |
|---|---|
| **Service principal (client) ID** | UAMI client ID |
| **Tenant ID** | Azure AD tenant GUID |
| **Subscription ID** | Azure subscription hosting the UAMI |
| **Credential** | Workload identity federation - no secret required |

The pipeline references service connections by name (`sc-fabric-dev`, `sc-fabric-tst`, `sc-fabric-prd`) in the `azureSubscription` field of each `AzurePowerShell@5` task. The correct connection is selected via the YAML template parameter `environment`, which resolves to the matching service connection name.

---

## No Secrets in Parameter Files

Parameter files (`config/environments/*.json`) must **never** contain secrets (passwords, keys, SAS tokens). If a connection or shortcut requires a credential, the `credentialsRef` field holds an ADO variable group reference (`$(mySecret)`). The actual secret lives in the variable group and is injected at pipeline runtime as a masked environment variable.
