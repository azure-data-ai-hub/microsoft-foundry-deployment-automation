// Storage Account Module - Secure defaults
targetScope = 'resourceGroup'

import { tagsType } from 'types.bicep'

@description('Storage account name (3-24 lowercase alphanumeric characters)')
@minLength(3)
@maxLength(24)
param storageName string

@description('Azure region')
param location string

@description('Resource tags')
param tags tagsType = {}

@description('SKU name')
@allowed([
  'Standard_LRS'
  'Standard_GRS'
  'Standard_RAGRS'
  'Standard_ZRS'
  'Premium_LRS'
])
param skuName string = 'Standard_LRS'

@description('Enable hierarchical namespace for ADLS Gen2')
param enableHierarchicalNamespace bool = false

@description('Create default containers for AI Foundry')
param createContainers bool = true

@description('Container names to create')
param containerNames array = [
  'data'
  'models'
  'artifacts'
]

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  tags: tags
  sku: {
    name: skuName
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    isHnsEnabled: enableHierarchicalNamespace
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled' // Change to 'Disabled' for private endpoints
    networkAcls: {
      defaultAction: 'Allow' // Change to 'Deny' with allowedIpRules for production
      bypass: 'AzureServices'
    }
    encryption: {
      services: {
        blob: {
          enabled: true
        }
        file: {
          enabled: true
        }
      }
      keySource: 'Microsoft.Storage'
    }
  }

  // Blob service with containers
  resource blobService 'blobServices@2023-05-01' = {
    name: 'default'

    resource containers 'containers@2023-05-01' = [for containerName in containerNames: if (createContainers) {
      name: containerName
      properties: {
        publicAccess: 'None'
      }
    }]
  }
}

@description('Storage account resource ID')
output id string = storageAccount.id

@description('Storage account name')
output name string = storageAccount.name

@description('Primary endpoints')
output primaryEndpoints object = storageAccount.properties.primaryEndpoints
