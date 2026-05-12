# Log Analytics Workspace Deployment & Integration Plan

## Objective

Automate the deployment of Azure Log Analytics Workspaces (LAW) per environment and configure each Fabric workspace to send diagnostic logs to its designated LAW, as part of the `fabric-cicd-v2` deployment pipeline using the Fabric CLI (`fab`) and Azure PowerShell.

## Overview

Microsoft Fabric (via the Power BI engine) integrates with Azure Log Analytics to expose Analysis Services engine events — query execution, semantic model refreshes, errors, and performance metrics. Each Fabric workspace on a Premium/Fabric capacity can be connected to a dedicated Azure Log Analytics Workspace, enabling per-environment observability.

Data flows into the `PowerBIDatasetsWorkspace` table in Log Analytics and is available within ~5 minutes.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Environment: dev                                           │
│                                                             │
│  Azure Log Analytics Workspace                              │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  ndpl-necp01-weu-fdev-law                             │  │
│  │  RG: ndpl-necp01-weu-fdev-rsg                         │  │
│  │  Table: PowerBIDatasetsWorkspace                      │  │
│  └───────────────┬───────────────────┬───────────────────┘  │
│                  │                   │                       │
│  ┌───────────────▼──┐  ┌────────────▼──────────┐           │
│  │ FIN-Core-Dev      │  │ FIN-Reporting-Dev      │           │
│  │ (Fabric workspace)│  │ (Fabric workspace)     │           │
│  └──────────────────┘  └───────────────────────┘           │
└─────────────────────────────────────────────────────────────┘
```

Each environment (dev, tst, prd) gets its own LAW. Individual Fabric workspaces can opt in or out via a per-workspace config property.

## Prerequisites

### 1. Register `microsoft.insights` resource provider

The Azure subscription hosting the LAW must have `microsoft.insights` registered:

```bash
az provider register --namespace microsoft.insights --subscription <subscriptionId>
```

### 2. Fabric capacity requirement

The Fabric workspace must be assigned to a **Fabric capacity (F SKU)** or **Power BI Premium capacity (P SKU / A4+)**. Log Analytics connections are not supported on shared/Pro-only workspaces.

### 3. Tenant admin setting

A Fabric/Power BI administrator must enable the tenant setting:

> **Admin portal → Tenant Settings → Audit and usage settings → "Azure Log Analytics connections for workspace administrators"** → **Enabled**

This allows workspace administrators to configure Log Analytics connections. The setting can be scoped to specific security groups.

### 4. Permissions

| Principal | Required Role | Target |
|---|---|---|
| Service principal running the pipeline | **Log Analytics Contributor** | On the Azure Log Analytics Workspace resource |
| Service principal running the pipeline | **Fabric Administrator** (tenant-level) | Required to call the Power BI Admin API (`PATCH /admin/groups/{id}`) |
| Workspace admin | Workspace Admin role | On each target Fabric workspace |

## API Details

### Connecting a Fabric workspace to Log Analytics

There is **no native `fab` command** for Log Analytics connections. This must be done via the **Power BI Admin REST API** using `fab api`.

#### Assign LAW to a workspace

```
PATCH https://api.powerbi.com/v1.0/myorg/admin/groups/{workspaceId}
```

Request body:

```json
{
  "logAnalyticsWorkspace": {
    "subscriptionId": "ff10c34a-8edb-4d5a-b37f-82e2b9cc0347",
    "resourceGroup": "ndpl-necp01-weu-fdev-rsg",
    "resourceName": "ndpl-necp01-weu-fdev-law"
  }
}
```

#### Using `fab api` with Power BI audience

```bash
# Assign LAW to workspace
fab api -X patch -A powerbi admin/groups/<workspaceId> \
  -i '{"logAnalyticsWorkspace":{"subscriptionId":"ff10c34a-...","resourceGroup":"ndpl-necp01-weu-fdev-rsg","resourceName":"ndpl-necp01-weu-fdev-law"}}'

# Disconnect LAW from workspace
fab api -X patch -A powerbi admin/groups/<workspaceId> \
  -i '{"logAnalyticsWorkspace":null}'

# Get workspace details (includes logAnalyticsWorkspace if set)
fab api -A powerbi admin/groups/<workspaceId>
```

> **Note:** The `-A powerbi` flag tells `fab api` to use the Power BI audience (`https://api.powerbi.com`) instead of the default Fabric audience. The Power BI Admin API requires `Tenant.ReadWrite.All` scope.

#### Unassign LAW from a workspace

```json
{
  "logAnalyticsWorkspace": null
}
```

### API constraints

| Constraint | Detail |
|---|---|
| Rate limit | 200 requests per hour on the Admin API |
| Required scope | `Tenant.ReadWrite.All` |
| Caller | Must be a Fabric administrator |
| Capacity requirement | Only Premium/Fabric capacity workspaces support LAW connections |

## Data Captured

Once connected, the LAW receives events in the `PowerBIDatasetsWorkspace` table:

| Category | Examples |
|---|---|
| Query | DAX query start/end, duration, CPU time |
| Command | Refresh operations, XMLA commands |
| DirectQuery | External query execution, connection times |
| Error | Failed operations with error details |
| ProgressReport | Refresh step progress |
| VertiPaqSEQuery | Storage engine queries |
| Session Initialize | New session events |
| Deadlock | Deadlock detection |
| ExecutionMetrics | End-of-request performance summary (CPU, memory, duration, throttling) |

### Key schema columns

| Column | Description |
|---|---|
| `TimeGenerated` | Event timestamp (UTC) |
| `OperationName` | Trace event (e.g., `QueryEnd`, `CommandEnd`) |
| `DurationMs` | Operation duration in milliseconds |
| `CpuTimeMs` | CPU time consumed |
| `ExecutingUser` | User who triggered the operation |
| `ArtifactName` | Semantic model name |
| `PowerBIWorkspaceName` | Workspace name |
| `StatusCode` | Success/failure code |
| `EventText` | Verbose details (DAX query text, refresh XML, etc.) |

## Implementation Plan

### 1. Config Schema — Add `logAnalytics` blocks

#### Environment-level LAW definition

Add a top-level `logAnalytics` section to environment config (e.g., `config/environments/dev.yml`):

```yaml
# ── Log Analytics ──────────────────────────────────────────────────────────────
# Azure Log Analytics Workspace for this environment.
# Deployed via Bicep/ARM; connected to Fabric workspaces via Power BI Admin API.
logAnalytics:
  subscriptionId: "ff10c34a-8edb-4d5a-b37f-82e2b9cc0347"
  resourceGroupName: ndpl-necp01-weu-fdev-rsg
  workspaceName: ndpl-necp01-weu-fdev-law
  location: westeurope
  sku: PerGB2018                 # PerGB2018 (pay-as-you-go) | CapacityReservation
  retentionInDays: 90            # 30-730 days
  dailyQuotaGb: -1               # -1 = no cap; or a numeric daily ingest cap in GB
```

#### Per-workspace opt-in

Add an optional `logAnalytics` property to each workspace definition:

```yaml
workspaces:
  - name: FIN-Core-Dev
    description: Finance core development workspace

    # Enable Log Analytics for this workspace.
    # true  = connect to environment-level LAW
    # false = explicitly disconnect / skip
    # omit  = skip (no change to current state)
    logAnalytics: true

    items:
      repository_directory: artifacts/FIN-Core-Dev.Workspace
      # ...

  - name: FIN-Sandbox-Dev
    description: Finance sandbox — no monitoring needed
    logAnalytics: false           # explicitly disconnected
    # ...
```

### 2. Azure Infrastructure — LAW Deployment via Bicep

Create a Bicep template for the Log Analytics Workspace resource. This runs as an `AzurePowerShell@5` or `AzureResourceManagerTemplateDeployment@3` task in the pipeline (same pattern as Private Links).

#### `infra/log-analytics-workspace.bicep`

```bicep
@description('Name of the Log Analytics Workspace')
param workspaceName string

@description('Azure region')
param location string = resourceGroup().location

@description('Pricing SKU')
@allowed(['PerGB2018', 'CapacityReservation'])
param sku string = 'PerGB2018'

@description('Data retention in days (30-730)')
@minValue(30)
@maxValue(730)
param retentionInDays int = 90

@description('Daily ingestion cap in GB. -1 = no limit')
param dailyQuotaGb int = -1

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  properties: {
    sku: {
      name: sku
    }
    retentionInDays: retentionInDays
    workspaceCapping: dailyQuotaGb > 0 ? {
      dailyQuotaGb: dailyQuotaGb
    } : null
  }
}

output lawId string = law.id
output lawName string = law.name
output lawResourceGroup string = resourceGroup().name
```

### 3. New Script — `Deploy-LogAnalytics.ps1`

Create `src/scripts/Deploy-LogAnalytics.ps1` following existing patterns:

```powershell
# Pseudocode flow:

# ──────────────────────────────────────────────────────────
# Phase 1: Deploy Azure LAW resource (Bicep)
# ──────────────────────────────────────────────────────────
# Run as AzurePowerShell@5 task (same pattern as Private Links):
#   az deployment group create \
#     --resource-group $config.logAnalytics.resourceGroupName \
#     --template-file infra/log-analytics-workspace.bicep \
#     --parameters workspaceName=$config.logAnalytics.workspaceName \
#                  location=$config.logAnalytics.location \
#                  sku=$config.logAnalytics.sku \
#                  retentionInDays=$config.logAnalytics.retentionInDays \
#                  dailyQuotaGb=$config.logAnalytics.dailyQuotaGb

# ──────────────────────────────────────────────────────────
# Phase 2: Connect Fabric workspaces to LAW (fab api)
# ──────────────────────────────────────────────────────────
foreach ($ws in $config.workspaces) {

    # Skip workspaces without logAnalytics property
    if ($null -eq $ws.logAnalytics) { continue }

    # Resolve workspace ID from workspace map
    $workspaceId = $workspaceMap[$ws.name]

    if ($ws.logAnalytics -eq $true) {
        # Build the LAW connection payload
        $body = @{
            logAnalyticsWorkspace = @{
                subscriptionId = $config.logAnalytics.subscriptionId
                resourceGroup  = $config.logAnalytics.resourceGroupName
                resourceName   = $config.logAnalytics.workspaceName
            }
        } | ConvertTo-Json -Compress

        # Check current state first (idempotency)
        $current = Invoke-FabCli -Arguments @(
            'api', '-A', 'powerbi',
            "admin/groups/$workspaceId"
        )

        $currentLaw = $current.logAnalyticsWorkspace
        $desiredLaw = @{
            subscriptionId = $config.logAnalytics.subscriptionId
            resourceGroup  = $config.logAnalytics.resourceGroupName
            resourceName   = $config.logAnalytics.workspaceName
        }

        if ($currentLaw.resourceName -eq $desiredLaw.resourceName `
            -and $currentLaw.resourceGroup -eq $desiredLaw.resourceGroup `
            -and $currentLaw.subscriptionId -eq $desiredLaw.subscriptionId) {
            Write-Host "  Log Analytics already configured for $($ws.name) — skipping"
            continue
        }

        # Assign LAW
        Invoke-FabCli -Arguments @(
            'api', '-X', 'patch', '-A', 'powerbi',
            "admin/groups/$workspaceId",
            '-i', $body
        )
        Write-Host "  Connected $($ws.name) → $($config.logAnalytics.workspaceName)"
    }
    elseif ($ws.logAnalytics -eq $false) {
        # Disconnect LAW
        $body = '{"logAnalyticsWorkspace":null}'
        Invoke-FabCli -Arguments @(
            'api', '-X', 'patch', '-A', 'powerbi',
            "admin/groups/$workspaceId",
            '-i', $body
        )
        Write-Host "  Disconnected Log Analytics from $($ws.name)"
    }
}
```

### 4. Orchestrator Integration

Add `'loganalytics'` to `$Scope` validation set in `Deploy-FabricEnvironment.ps1`:

```powershell
[ValidateSet('all', 'workspaces', 'items', 'security', 'privatelinks', 'gateways', 'loganalytics')]
[string]$Scope = 'all',
```

Deploy order — Log Analytics runs after workspaces exist and the workspace map is exported, but before items:

```
Deployment order:
  1. Authenticate
  2. Workspaces
  3. Gateways
  4. Log Analytics (Azure infra)    ← NEW — Phase 1: deploy LAW via Bicep
  5. Log Analytics (connections)    ← NEW — Phase 2: connect workspaces via fab api
  6. Items
  7. Security
  8. Private Links
```

### 5. Pipeline Integration

#### Separate task for Azure LAW deployment

Since the LAW deployment uses Azure Resource Manager / Bicep, it needs to run as an `AzurePowerShell@5` task (or `AzureResourceManagerTemplateDeployment@3`), similar to the Private Links deployment:

```yaml
# In deploy-environment.yml template:

- task: AzurePowerShell@5
  displayName: 'Deploy Log Analytics Workspace'
  condition: and(succeeded(), ne(variables['logAnalytics.workspaceName'], ''))
  inputs:
    azureSubscription: $(serviceConnectionName)
    ScriptType: InlineScript
    Inline: |
      az deployment group create `
        --resource-group '$(logAnalytics.resourceGroupName)' `
        --template-file '$(Build.SourcesDirectory)/infra/log-analytics-workspace.bicep' `
        --parameters workspaceName='$(logAnalytics.workspaceName)' `
                     location='$(logAnalytics.location)' `
                     sku='$(logAnalytics.sku)' `
                     retentionInDays=$(logAnalytics.retentionInDays) `
                     dailyQuotaGb=$(logAnalytics.dailyQuotaGb)
    azurePowerShellVersion: LatestVersion

# Workspace-level LAW connection runs via fab api inside the main script
```

#### Scope parameter addition

```yaml
# In the scope parameter values list:
values: [all, workspaces, items, security, privatelinks, gateways, loganalytics]
```

### 6. Validation

Extend `Validate-Deployment.ps1` with Log Analytics checks:

```powershell
# Test 1: Azure LAW exists
$lawResource = az monitor log-analytics workspace show `
  --resource-group $config.logAnalytics.resourceGroupName `
  --workspace-name $config.logAnalytics.workspaceName `
  --subscription $config.logAnalytics.subscriptionId 2>$null

if (-not $lawResource) {
    Write-Warning "LAW '$($config.logAnalytics.workspaceName)' not found in RG '$($config.logAnalytics.resourceGroupName)'"
}

# Test 2: Each opt-in workspace is connected
foreach ($ws in $config.workspaces | Where-Object { $_.logAnalytics -eq $true }) {
    $workspaceId = $workspaceMap[$ws.name]
    $details = Invoke-FabCli -Arguments @(
        'api', '-A', 'powerbi',
        "admin/groups/$workspaceId"
    )
    if ($details.logAnalyticsWorkspace.resourceName -ne $config.logAnalytics.workspaceName) {
        Write-Warning "Workspace '$($ws.name)' not connected to expected LAW"
    }
}

# Test 3: microsoft.insights provider is registered
$provider = az provider show --namespace microsoft.insights `
  --subscription $config.logAnalytics.subscriptionId `
  --query "registrationState" -o tsv
if ($provider -ne 'Registered') {
    Write-Warning "microsoft.insights provider not registered on subscription"
}
```

### 7. Idempotency Considerations

| Scenario | Behavior |
|---|---|
| LAW doesn't exist in Azure | Bicep creates it |
| LAW exists, config matches | Bicep no-ops (ARM idempotency) |
| LAW exists, config differs (e.g., retention) | Bicep updates in-place |
| Workspace `logAnalytics: true`, already connected to correct LAW | Skip (no API call) |
| Workspace `logAnalytics: true`, connected to different LAW | Update to correct LAW |
| Workspace `logAnalytics: true`, not connected | Connect |
| Workspace `logAnalytics: false`, currently connected | Disconnect |
| Workspace `logAnalytics` omitted | No change to current state |

## Sample KQL Queries

Once connected, the following queries can be run in the Azure portal against the `PowerBIDatasetsWorkspace` table:

```kusto
// Log count per day for last 30 days
PowerBIDatasetsWorkspace
| where TimeGenerated > ago(30d)
| summarize count() by format_datetime(TimeGenerated, 'yyyy-MM-dd')

// Average query duration by day
PowerBIDatasetsWorkspace
| where TimeGenerated > ago(30d)
| where OperationName == 'QueryEnd'
| summarize avg(DurationMs) by format_datetime(TimeGenerated, 'yyyy-MM-dd')

// Refresh durations by workspace and semantic model
PowerBIDatasetsWorkspace
| where TimeGenerated > ago(30d)
| where OperationName == 'CommandEnd'
| where ExecutingUser contains 'Power BI Service'
| where EventText contains 'refresh'
| project PowerBIWorkspaceName, DatasetName = ArtifactName, DurationMs

// Query count, distinct users, avg CPU, avg duration by workspace
PowerBIDatasetsWorkspace
| where TimeGenerated > ago(30d)
| where OperationName == "QueryEnd"
| summarize QueryCount=count(),
    Users = dcount(ExecutingUser),
    AvgCPU = avg(CpuTimeMs),
    AvgDuration = avg(DurationMs)
by PowerBIWorkspaceId

// Throttled requests
PowerBIDatasetsWorkspace
| where TimeGenerated > ago(1d)
| where OperationName == "ExecutionMetrics"
| extend eventTextJson = parse_json(EventText)
| extend capacityThrottlingMs = toint(eventTextJson.capacityThrottlingMs)
| where capacityThrottlingMs > 0
| project TimeGenerated, PowerBIWorkspaceName, ArtifactName, capacityThrottlingMs
```

## Full Config Example

```yaml
environment: dev
capacityName: ndplnecp01weufdevfcp

# ── Log Analytics ──────────────────────────────────────────────────────────────
logAnalytics:
  subscriptionId: "ff10c34a-8edb-4d5a-b37f-82e2b9cc0347"
  resourceGroupName: ndpl-necp01-weu-fdev-rsg
  workspaceName: ndpl-necp01-weu-fdev-law
  location: westeurope
  sku: PerGB2018
  retentionInDays: 90
  dailyQuotaGb: -1

# ── Private Link Infrastructure ───────────────────────────────────────────────
privateLinks:
  tenantId: "2f741536-f5f3-445f-b1a9-9d260038ca80"
  SubscriptionId: "ff10c34a-8edb-4d5a-b37f-82e2b9cc0347"
  # ...

workspaces:
  - name: FIN-Core-Dev
    description: Finance core development workspace
    logAnalytics: true            # ← Connect to environment LAW
    items:
      repository_directory: artifacts/FIN-Core-Dev.Workspace
    roles:
      - identity: "da5b8c7e-02d9-4291-8377-c4c1dfc33f5d"
        principalType: User
        role: Admin
    privateLink:
      plsName: ndpl-necp01-weu-fdev-fin-core-pls
      peResourceName: ndpl-necp01-weu-fdev-fin-core

  - name: FIN-Reporting-Dev
    description: Finance Reporting development workspace
    logAnalytics: true            # ← Connect to environment LAW
    items:
      repository_directory: artifacts/FIN-Reporting-Dev.Workspace

  - name: FIN-Sandbox-Dev
    description: Finance sandbox — no monitoring
    logAnalytics: false           # ← Explicitly disconnected
    items:
      repository_directory: artifacts/FIN-Sandbox-Dev.Workspace
```

## Considerations & Limitations

- **Premium/Fabric capacity required** — Only workspaces on Fabric (F SKU) or Power BI Premium (P/A4+) support Log Analytics connections.
- **Workspace v2 only** — Legacy v1 workspaces do not support Log Analytics.
- **Tenant setting must be enabled** — The admin portal setting "Azure Log Analytics connections for workspace administrators" is a manual prerequisite.
- **Rate limits** — The Power BI Admin API allows 200 requests/hour. For tenants with many workspaces, implement batching.
- **No Fabric REST API** — Log Analytics connection is managed exclusively via the Power BI Admin REST API (`api.powerbi.com`), not the Fabric REST API.
- **Service principal must be Fabric admin** — The `PATCH /admin/groups/{id}` endpoint requires `Tenant.ReadWrite.All` scope and the caller must be a Fabric administrator.
- **Sovereign cloud support** — Currently limited to US DoD and US GCC High.
- **Paginated Reports** — Not supported via Log Analytics; use Azure audit logs instead.
- **Private Links + LAW** — Data ingestion into Log Analytics works with private links, but the Log Analytics Template App requires additional configuration (custom DNS mapping for private internal IP).

## References

- [Using Azure Log Analytics in Power BI (Overview)](https://learn.microsoft.com/en-us/power-bi/transform-model/log-analytics/desktop-log-analytics-overview)
- [Configure Azure Log Analytics for Power BI](https://learn.microsoft.com/en-us/power-bi/transform-model/log-analytics/desktop-log-analytics-configure)
- [Power BI Admin API — Update Group As Admin](https://learn.microsoft.com/en-us/rest/api/power-bi/admin/groups-update-group-as-admin)
- [Fabric CLI — API Command](https://microsoft.github.io/fabric-cli/commands/api/)
- [Fabric CLI — Auth Examples](https://microsoft.github.io/fabric-cli/examples/auth_examples/)
- [Create a Log Analytics Workspace (Azure)](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/quick-create-workspace)
- [Log Analytics Template Reports (GitHub)](https://github.com/microsoft/PowerBI-LogAnalytics-Template-Reports)
