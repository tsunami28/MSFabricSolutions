// **   TEMPLATE INFO   ** //
metadata templateInfo = {
  templateName: 'deployFabricWorkspaceInfra'
  description: 'Deploy Fabric Workspace infrastructure including Private Link Services and Private Endpoints for multiple workspaces'
  category: 'Data'
  owner: 'NewCold CCoE Team'
  version: '2.0.0'
  createdOn: '2026-04-30'
  lastChangedOn: '2026-05-01'
  lastChangedBy: 'Milos Katinski'
}

// **   PARAMETERS   ** //

@description('Array of workspace configurations with injected workspace IDs, PLS names, and PE resource names.')
param workspaceConfigs array

@description('The tenant ID associated with the Fabric workspaces.')
param tenantId string = subscription().tenantId

@description('The subnet ID where private endpoints will be placed.')
param subnetId string

@description('The private DNS zone ID for Fabric workspace private links.')
param privateDnsZoneId string

@description('The location where the private endpoints will be deployed.')
param location string = resourceGroup().location

// **   VARIABLES   ** //

// **   EXISTING RESOURCES   ** //

// **   RESOURCES & MODULES   ** //

// Deploy Private Link Service for each workspace
module fabricPLS 'deployFabricPLS.bicep' = [for (wsConfig, i) in workspaceConfigs: {
  name: 'fabricPLS-${i}'
  params: {
    name: wsConfig.plsName
    tenantId: tenantId
    workspaceId: wsConfig.workspaceId
  }
}]

// Deploy Private Endpoint for each workspace connected to its PLS
module privateEndpoint '../modules/privateEndpoints/privateEndpoints.bicep' = [for (i, idx) in range(0, length(workspaceConfigs)): {
  name: 'privateEndpoint-${idx}'
  params: {
    resourceName: workspaceConfigs[idx].peResourceName
    resourceId: fabricPLS[idx].outputs.resourceId
    privateEndpointType: workspaceConfigs[idx].peType
    subnetId: subnetId
    privateDnsZoneId: privateDnsZoneId
    location: location
  }
}]

// **   OUTPUTS   ** //

@description('Array of deployed Private Link Service resource IDs.')
output plsResourceIds array = [for (i, idx) in range(0, length(workspaceConfigs)): fabricPLS[idx].outputs.resourceId]

@description('Array of deployed Private Link Service names.')
output plsNames array = [for (i, idx) in range(0, length(workspaceConfigs)): fabricPLS[idx].outputs.name]

@description('Array of deployed Private Endpoint resource IDs.')
output peResourceIds array = [for (i, idx) in range(0, length(workspaceConfigs)): privateEndpoint[idx].outputs.resourceId]

@description('Array of deployed Private Endpoint names.')
output peNames array = [for (i, idx) in range(0, length(workspaceConfigs)): privateEndpoint[idx].outputs.name]

@description('The resource group name where resources were deployed.')
output resourceGroupName string = resourceGroup().name

@description('Count of deployed workspaces.')
output workspaceCount int = length(workspaceConfigs)
