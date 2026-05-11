// **   MODULE INFO   ** //
metadata moduleInfo = {
  moduleName: 'privateEndpoints'
  description: 'Deploy a Private Endpoint'
  category: 'Networking'
  owner: 'NewCold CCoE Team'
  version: '2.1.0'
  createdOn: '2025-06-09'
  lastChangedOn: '2026-05-07'
  lastChangedBy: 'Milos Katinski'
}

// **   PARAMETERS   ** //
@description('Define a resource name that needs to have a private endpoint.')
param resourceName string

@description('Define a resource ID that needs to have a private endpoint.')
param resourceId string

@description('Define a private endpoint type (i.e., blob, file, vault, etc.). Leave empty for Private Link Service connections.')
param privateEndpointType string = ''

@description('Define an ID of the subnet where the private endpoint will be placed.')
param subnetId string

@description('Define an ID of the respective private DNS zone.')
param privateDnsZoneId string

@description('The location where the private endpoint will be deployed.')
param location string = resourceGroup().location

// **   VARIABLES   ** //
@description('The name of the private endpoint.')
var privateEndpointName = '${resourceName}-endpoint'

// **   EXISTING RESOURCES   ** // 

// **   RESOURCES   ** // 

// Standard PE with groupIds (for blob, vault, etc.)
resource privateEndpointWithGroup 'Microsoft.Network/privateEndpoints@2025-01-01' = if (!empty(privateEndpointType)) {
  location: location
  name: privateEndpointName
  properties: {
    subnet: {
      id: subnetId
    }
    customNetworkInterfaceName: '${privateEndpointName}-nic0'
    privateLinkServiceConnections: [
      {
        name: privateEndpointName
        properties: {
          privateLinkServiceId: resourceId
          groupIds: [
            privateEndpointType
          ]
        }
      }
    ]
  }
  tags: {}
}

// PLS PE without groupIds (for Private Link Service connections)
resource privateEndpointPls 'Microsoft.Network/privateEndpoints@2025-01-01' = if (empty(privateEndpointType)) {
  location: location
  name: privateEndpointName
  properties: {
    subnet: {
      id: subnetId
    }
    customNetworkInterfaceName: '${privateEndpointName}-nic0'
    privateLinkServiceConnections: [
      {
        name: privateEndpointName
        properties: {
          privateLinkServiceId: resourceId
        }
      }
    ]
  }
  tags: {}
}

resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2025-01-01' = {
  parent: !empty(privateEndpointType) ? privateEndpointWithGroup : privateEndpointPls
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: privateEndpointName
        properties: {
          privateDnsZoneId: privateDnsZoneId
        }
      }
    ]
  }
}

// **   OUTPUTS   ** //
@description('The resource ID of the deployed Private Endpoint.')
output resourceId string = !empty(privateEndpointType) ? privateEndpointWithGroup.id : privateEndpointPls.id

@description('The name of the deployed Private Endpoint.')
output name string = !empty(privateEndpointType) ? privateEndpointWithGroup.name : privateEndpointPls.name
