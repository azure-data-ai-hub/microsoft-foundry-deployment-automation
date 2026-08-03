// Key Vault Module - RBAC-based with security features
targetScope = 'resourceGroup'

import { tagsType } from 'types.bicep'

@description('Key Vault name (3-24 alphanumeric and hyphens)')
@minLength(3)
@maxLength(24)
param kvName string

@description('Azure region')
param location string

@description('Resource tags')
param tags tagsType = {}

@description('Enable purge protection (cannot be disabled once enabled)')
param enablePurgeProtection bool = true

@description('Soft delete retention in days')
@minValue(7)
@maxValue(90)
param softDeleteRetentionInDays int = 90

@description('SKU name')
@allowed([
  'standard'
  'premium'
])
param skuName string = 'standard'

@description('Enable RBAC authorization (recommended over access policies)')
param enableRbacAuthorization bool = true

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: kvName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: skuName
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: enableRbacAuthorization
    enableSoftDelete: true
    softDeleteRetentionInDays: softDeleteRetentionInDays
    enablePurgeProtection: enablePurgeProtection
    publicNetworkAccess: 'Enabled' // Change to 'Disabled' for private endpoints
    networkAcls: {
      defaultAction: 'Allow' // Change to 'Deny' with ipRules for production
      bypass: 'AzureServices'
    }
  }
}

@description('Key Vault resource ID')
output id string = keyVault.id

@description('Key Vault name')
output name string = keyVault.name

@description('Key Vault URI')
output vaultUri string = keyVault.properties.vaultUri
