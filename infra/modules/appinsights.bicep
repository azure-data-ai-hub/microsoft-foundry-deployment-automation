// Application Insights Module - Monitoring for AI Foundry
targetScope = 'resourceGroup'

import { tagsType } from 'types.bicep'

@description('Application Insights name')
param appInsightsName string

@description('Azure region')
param location string

@description('Resource tags')
param tags tagsType = {}

@description('Application type')
@allowed([
  'web'
  'other'
])
param applicationType string = 'web'

@description('Log Analytics workspace resource ID')
param workspaceResourceId string = ''

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: applicationType
  properties: {
    Application_Type: applicationType
    WorkspaceResourceId: !empty(workspaceResourceId) ? workspaceResourceId : null
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

@description('Application Insights resource ID')
output id string = appInsights.id

@description('Application Insights name')
output name string = appInsights.name

@description('Instrumentation key')
output instrumentationKey string = appInsights.properties.InstrumentationKey

@description('Connection string')
output connectionString string = appInsights.properties.ConnectionString
