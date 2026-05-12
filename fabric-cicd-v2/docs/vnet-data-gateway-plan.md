# VNet Data Gateway Deployment & Management Plan

## Objective

Automate the provisioning and lifecycle management of Virtual Network (VNet) Data Gateways as part of the `fabric-cicd-v2` deployment pipeline using the Fabric CLI (`fab`).

## Overview

VNet Data Gateways allow Fabric workloads to securely connect to data sources within an Azure Virtual Network without requiring an on-premises gateway installation. They run inside a delegated subnet and are managed entirely by Microsoft.

## Fabric CLI Support

The Fabric CLI has **first-class support** for VNet gateway management via the `.Gateway` resource type.

### Available Commands

| Operation | Command |
|---|---|
| Create VNet gateway | `fab create .gateways/<name>.Gateway -P capacity=...,virtualNetworkName=...,subnetName=...` |
| Check existence | `fab exists .gateways/<name>.Gateway` |
| Get details | `fab get .gateways/<name>.Gateway` |
| List all gateways | `fab ls .gateways` |
| Update display name | `fab set .gateways/<name>.Gateway -q displayName -i "<new name>"` |
| Remove gateway | `fab rm .gateways/<name>.Gateway -f` |
| Get permissions | `fab acl get .gateways/<name>.Gateway` |
| List permissions | `fab acl ls .gateways/<name>.Gateway` |
| Describe schema | `fab desc .Gateway` |

### Create Parameters

| Parameter | Required | Description |
|---|---|---|
| `capacity` | Yes | Name of the Fabric capacity to associate for billing |
| `virtualNetworkName` | Yes | Name of the Azure VNet |
| `subnetName` | Yes | Name of the delegated subnet |
| `subscriptionId` | No | Azure subscription ID (if not in default config) |
| `resourceGroupName` | No | Resource group containing the VNet |
| `inactivityMinutesBeforeSleep` | No | Auto-sleep timeout. Valid: 30, 60, 90, 120, 150, 240, 360, 480, 720, 1440. Default varies. |
| `numberOfMemberGateways` | No | Number of gateway members (1-9). Default: 1 |

### Examples

```bash
# Create basic VNet gateway
fab create .gateways/fin-dev-vnet-gw.Gateway \
  -P capacity=ndplnecp01weufdevfcp,virtualNetworkName=ndpl-necp01-weu-ntwk-vnt,subnetName=GatewaySubnet

# Create with full configuration
fab create .gateways/fin-dev-vnet-gw.Gateway \
  -P capacity=ndplnecp01weufdevfcp,resourceGroupName=ndpl-necp01-weu-ntwk-rsg,subscriptionId=ff10c34a-8edb-4d5a-b37f-82e2b9cc0347,virtualNetworkName=ndpl-necp01-weu-ntwk-vnt,subnetName=GatewaySubnet,inactivityMinutesBeforeSleep=120,numberOfMemberGateways=2

# Check if gateway exists
fab exists .gateways/fin-dev-vnet-gw.Gateway

# Get gateway details (JSON)
fab get .gateways/fin-dev-vnet-gw.Gateway --output_format json

# Remove gateway
fab rm .gateways/fin-dev-vnet-gw.Gateway -f
```

### Advanced Operations via `fab api`

For operations not covered by built-in commands (e.g., updating member count, managing role assignments programmatically):

```bash
# List all gateways (REST)
fab api gateways

# Get specific gateway by ID
fab api gateways/<gatewayId>

# Update gateway settings
fab api -X patch gateways/<gatewayId> \
  -i '{"displayName":"Updated Name","inactivityMinutesBeforeSleep":240,"numberOfMemberGateways":3}'

# Add role assignment
fab api -X post gateways/<gatewayId>/roleAssignments \
  -i '{"principal":{"id":"<objectId>","type":"User"},"role":"ConnectionCreator"}'

# Delete role assignment
fab api -X delete gateways/<gatewayId>/roleAssignments/<roleAssignmentId>
```

## Prerequisites (Azure side)

Before a VNet data gateway can be created, the following must be in place:

### 1. Register `Microsoft.PowerPlatform` resource provider

```bash
az provider register --namespace Microsoft.PowerPlatform --subscription <subscriptionId>
```

### 2. Delegate subnet to Microsoft Power Platform

The subnet must be delegated to `Microsoft.PowerPlatform/vnetaccesslinks`:

- Create a dedicated subnet (cannot be shared with other services).
- Reserve IPs: 5 (base) + 1 per gateway member. E.g., 2 clusters × 3 members = 11 IPs minimum.
- Subnet name must NOT be `gatewaysubnet` or `AzureBastionSubnet` (reserved).
- No IPv6 address space. IP range must not overlap with `10.0.1.x`.
- For large datasets, add `Microsoft.Storage` service endpoint to the subnet.

```bash
az network vnet subnet update \
  --resource-group <rg> \
  --vnet-name <vnet> \
  --name <subnet> \
  --delegations Microsoft.PowerPlatform/vnetaccesslinks
```

### 3. Permissions

The identity creating the gateway needs:
- `Microsoft.Network/virtualNetworks/subnets/join/action` on the VNet (e.g., Azure Network Contributor role).
- Fabric capacity admin or appropriate gateway installer permission in the tenant.
- Delegated scope: `Gateway.ReadWrite.All`.

## Implementation Plan

### 1. Config Schema — Add `gateways` block

Extend environment YAML config (e.g., `config/environments/dev.yml`) with a top-level `gateways` section:

```yaml
# ── VNet Data Gateways ────────────────────────────────────────────────────────
gateways:
  - name: fin-dev-vnet-gw
    capacityName: ndplnecp01weufdevfcp       # Fabric capacity for billing
    subscriptionId: "ff10c34a-8edb-4d5a-b37f-82e2b9cc0347"
    resourceGroupName: ndpl-necp01-weu-ntwk-rsg
    virtualNetworkName: ndpl-necp01-weu-ntwk-vnt
    subnetName: FabricGatewaySubnet
    inactivityMinutesBeforeSleep: 120        # 30|60|90|120|150|240|360|480|720|1440
    numberOfMemberGateways: 2                # 1-9
    roles:
      - identity: "a2ae4cfb-3aea-45b1-80da-9e231959c755"  # fabric-admins group
        role: Admin
      - identity: "c2017801-1951-4d78-acd8-b3685b18a564"  # developers group
        role: ConnectionCreator
```

### 2. New Script — `Deploy-Gateways.ps1`

Create `src/scripts/Deploy-Gateways.ps1` following existing patterns:

```powershell
# Pseudocode flow per gateway config entry:

# 1. Check existence
$exists = Test-FabResourceExists -Path ".gateways/$($gw.name).Gateway"

# 2. Create if missing
if (-not $exists) {
    $createParams = "capacity=$($gw.capacityName)"
    $createParams += ",subscriptionId=$($gw.subscriptionId)"
    $createParams += ",resourceGroupName=$($gw.resourceGroupName)"
    $createParams += ",virtualNetworkName=$($gw.virtualNetworkName)"
    $createParams += ",subnetName=$($gw.subnetName)"
    $createParams += ",inactivityMinutesBeforeSleep=$($gw.inactivityMinutesBeforeSleep)"
    $createParams += ",numberOfMemberGateways=$($gw.numberOfMemberGateways)"

    Invoke-FabCli -Arguments @('create', ".gateways/$($gw.name).Gateway", '-P', $createParams)
}

# 3. Update settings if gateway already exists (via fab api PATCH)
# Compare current vs desired and patch differences

# 4. Configure role assignments (fab acl set / fab api)
```

### 3. Orchestrator Integration

Add `'gateways'` to `$Scope` validation set in `Deploy-FabricEnvironment.ps1`:

```powershell
[ValidateSet('all', 'workspaces', 'items', 'security', 'privatelinks', 'gateways')]
[string]$Scope = 'all',
```

Invoke between workspace creation and item deployment (gateways may be referenced by connections used in items):

```
Deployment order:
  1. Authenticate
  2. Workspaces
  3. Gateways        ← NEW
  4. Items
  5. Security
  6. Private Links
```

### 4. Validation

Extend `Validate-Deployment.ps1`:

```powershell
# Test: gateway exists
$gwExists = Test-FabResourceExists -Path ".gateways/$($gw.name).Gateway"

# Test: gateway configuration matches desired state
$gwDetails = Invoke-FabCli -Arguments @('get', ".gateways/$($gw.name).Gateway", '--output_format', 'json')
# Compare numberOfMemberGateways, inactivityMinutesBeforeSleep, etc.
```

### 5. Idempotency Considerations

| Scenario | Behavior |
|---|---|
| Gateway doesn't exist | Create with full config |
| Gateway exists, settings match | No-op (log skip) |
| Gateway exists, settings differ | Update via `fab api -X patch` |
| Gateway exists, should be removed | Only if explicit `remove: true` in config |
| Subnet not delegated | Fail with clear error message — prerequisite must be resolved manually or via separate IaC |

### 6. Pipeline Integration

Add gateway scope support to `deploy-environment.yml`:

```yaml
# In the scope parameter values list:
values: [all, workspaces, items, security, privatelinks, gateways]
```

## Supported Regions

VNet data gateways are supported in: Australia East, Australia Southeast, Brazil South, Canada Central, Central India, Central US, East Asia, East US, East US 2, France Central, Germany West Central, Japan East, Korea Central, Indonesia Central, Israel Central, Italy North, Malaysia West, Mexico Central, New Zealand North, North Central US, North Europe, Norway East, Poland Central, Spain Central, South Africa North, South Central US, Southeast Asia, Sweden Central, Switzerland North, Taiwan North, UAE North, UK South, UK West, West Central US, West Europe, West US, West US 2, West US 3.

## Key Constraints

- VNet data gateways require a **Fabric capacity** (any F SKU) or Power BI Premium (P SKU or A4+).
- Subnet **cannot** be shared with other Azure services.
- Cross-tenant gateway creation is **not supported**.
- After removing the last gateway on a subnet, it may take **48-72 hours** before the subnet/VNet can be deleted.
- Gateway metadata is stored in the tenant's default Power BI home region regardless of VNet location.

## References

- [Fabric CLI — Gateway Examples](https://microsoft.github.io/fabric-cli/examples/gateway_examples/)
- [Fabric CLI — Commands](https://microsoft.github.io/fabric-cli/commands/)
- [Create VNet Data Gateways](https://learn.microsoft.com/en-us/data-integration/vnet/create-data-gateways)
- [Manage VNet Data Gateways](https://learn.microsoft.com/en-us/data-integration/vnet/manage-data-gateways)
- [Fabric REST API — Gateways](https://learn.microsoft.com/en-us/rest/api/fabric/core/gateways)
- [Fabric REST API — Create Gateway](https://learn.microsoft.com/en-us/rest/api/fabric/core/gateways/create-gateway)
