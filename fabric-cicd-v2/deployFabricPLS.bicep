// **   TEMPLATE INFO   ** //
metadata templateInfo = {
  templateName: 'deployFabricPrivateLinkSerice'
  description: 'Deploy a Private Link Service for Fabric'
  category: 'Data'
  owner: 'NewCold CCoE Team'
  version: '1.0.0'
  createdOn: '2026-04-25'
  lastChangedOn: '2026-04-25'
  lastChangedBy: 'Milos Katinski'
}

// **   PARAMETERS   ** //

@description('The tenant ID associated with the Fabric workspace.')
param tenantId string = subscription().tenantId

@description('The workspace ID of the Fabric capacity to which the Private Link Service will be associated.')
param workspaceId string

@description('The resource name for the Private Link Service.')
param name string

@description('The resource name for the Private Endpoint. If empty, PE deployment is skipped.')
param peResourceName string = ''

@description('The resource ID of the subnet where the Private Endpoint will be created.')
param subnetId string = ''

@description('The resource ID of the Private DNS Zone for automatic DNS registration.')
param privateDnsZoneId string = ''

@description('The Azure region for the Private Endpoint.')
param location string = resourceGroup().location

resource fabricpls 'Microsoft.Fabric/privateLinkServicesForFabric@2024-06-01' = {
  name: name
  location: 'global'
  properties: {
    tenantId: tenantId
    workspaceId: workspaceId
  }
}

// ── Private Endpoint (optional — deployed only when peResourceName is provided) ──

resource fabricpe 'Microsoft.Network/privateEndpoints@2024-05-01' = if (!empty(peResourceName)) {
  name: !empty(peResourceName) ? peResourceName : 'unused'
  location: location
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: peResourceName
        properties: {
          privateLinkServiceId: fabricpls.id
          groupIds: [
            'Workspace'
          ]
        }
      }
    ]
  }
}

resource dnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = if (!empty(peResourceName) && !empty(privateDnsZoneId)) {
  parent: fabricpe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'fabric'
        properties: {
          privateDnsZoneId: privateDnsZoneId
        }
      }
    ]
  }
}

// **   OUTPUTS   ** //

@description('The resource ID of the deployed Private Link Service for Fabric.')
output resourceId string = fabricpls.id

@description('The name of the deployed Private Link Service for Fabric.')
output name string = fabricpls.name

@description('The resource ID of the deployed Private Endpoint (empty if not deployed).')
output peResourceId string = !empty(peResourceName) ? fabricpe.id : ''
