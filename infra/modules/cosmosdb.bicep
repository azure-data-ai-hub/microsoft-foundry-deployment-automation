// Azure Cosmos DB Module - Standard Agent Setup thread/conversation storage
targetScope = 'resourceGroup'

import { tagsType } from 'types.bicep'

@description('Cosmos DB account name (3-44 lowercase alphanumeric/hyphen characters)')
@minLength(3)
@maxLength(44)
param cosmosDBName string

@description('Azure region')
param location string

@description('Resource tags')
param tags tagsType = {}

// Cosmos DB does not support every Azure region (e.g. some canary regions) - fall back to
// westus if the primary deployment region is not supported.
var unsupportedRegionsFallback = {
  westcentralus: 'westus'
}
var cosmosLocation = unsupportedRegionsFallback[?toLower(location)] ?? location

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = {
  name: cosmosDBName
  location: cosmosLocation
  tags: tags
  kind: 'GlobalDocumentDB'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    databaseAccountOfferType: 'Standard'
    disableLocalAuth: true
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    locations: [
      {
        locationName: cosmosLocation
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    publicNetworkAccess: 'Enabled' // Change to 'Disabled' for private endpoints
  }
}

@description('Cosmos DB account resource ID')
output id string = cosmosAccount.id

@description('Cosmos DB account name')
output name string = cosmosAccount.name

@description('Cosmos DB document endpoint')
output documentEndpoint string = cosmosAccount.properties.documentEndpoint

@description('Cosmos DB account location')
output location string = cosmosAccount.location
