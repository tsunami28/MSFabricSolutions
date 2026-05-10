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

@description('The resource name')
param name string

resource fabricpls 'Microsoft.Fabric/privateLinkServicesForFabric@2024-06-01' = {
  name: name
  location: 'global'
  properties: {
    tenantId: tenantId
    workspaceId: workspaceId
  }
}

// **   OUTPUTS   ** //

@description('The resource ID of the deployed Private Link Service for Fabric.')
output resourceId string = fabricpls.id

@description('The name of the deployed Private Link Service for Fabric.')
output name string = fabricpls.name
