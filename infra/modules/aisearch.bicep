// Azure AI Search Module - Standard Agent Setup vector store
targetScope = 'resourceGroup'

import { tagsType } from 'types.bicep'

@description('Azure AI Search service name (2-60 lowercase alphanumeric/hyphen characters)')
@minLength(2)
@maxLength(60)
param aiSearchName string

@description('Azure region')
param location string

@description('Resource tags')
param tags tagsType = {}

@description('SKU for the Azure AI Search service')
@allowed([
  'free'
  'basic'
  'standard'
  'standard2'
  'standard3'
])
param skuName string = 'standard'

resource searchService 'Microsoft.Search/searchServices@2024-06-01-preview' = {
  name: aiSearchName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: skuName
  }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'default'
    publicNetworkAccess: 'enabled' // Change to 'disabled' for private endpoints
    disableLocalAuth: true
  }
}

@description('Azure AI Search service resource ID')
output id string = searchService.id

@description('Azure AI Search service name')
output name string = searchService.name

@description('Azure AI Search service endpoint')
output endpoint string = 'https://${searchService.name}.search.windows.net'

@description('Azure AI Search service location')
output location string = searchService.location
