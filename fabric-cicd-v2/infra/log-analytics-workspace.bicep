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
