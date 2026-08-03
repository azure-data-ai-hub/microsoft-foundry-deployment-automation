// Role Assignment Module - Assigns RBAC roles
targetScope = 'resourceGroup'

@description('Principal (object) ID to assign the role to')
param principalId string

@description('Role definition ID (GUID)')
param roleDefinitionId string

@description('Principal type')
@allowed([
  'User'
  'Group'
  'ServicePrincipal'
  'ForeignGroup'
])
param principalType string = 'ServicePrincipal'

@description('Resource ID to assign the role at')
param resourceId string

// Extract resource type and name from resourceId
var resourceIdParts = split(resourceId, '/')
var resourceType = '${resourceIdParts[6]}/${resourceIdParts[7]}'
var resourceName = resourceIdParts[8]

resource targetResource 'Microsoft.KeyVault/vaults@2023-07-01' existing = if (resourceType == 'Microsoft.KeyVault/vaults') {
  name: resourceName
}

resource targetStorageResource 'Microsoft.Storage/storageAccounts@2023-05-01' existing = if (resourceType == 'Microsoft.Storage/storageAccounts') {
  name: resourceName
}

resource targetAiServicesResource 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = if (resourceType == 'Microsoft.CognitiveServices/accounts') {
  name: resourceName
}

resource targetCosmosDbResource 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = if (resourceType == 'Microsoft.DocumentDB/databaseAccounts') {
  name: resourceName
}

resource targetSearchResource 'Microsoft.Search/searchServices@2024-06-01-preview' existing = if (resourceType == 'Microsoft.Search/searchServices') {
  name: resourceName
}

resource roleAssignmentKv 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (resourceType == 'Microsoft.KeyVault/vaults') {
  scope: targetResource
  name: guid(resourceId, principalId, roleDefinitionId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalId: principalId
    principalType: principalType
  }
}

resource roleAssignmentStorage 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (resourceType == 'Microsoft.Storage/storageAccounts') {
  scope: targetStorageResource
  name: guid(resourceId, principalId, roleDefinitionId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalId: principalId
    principalType: principalType
  }
}

resource roleAssignmentAiServices 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (resourceType == 'Microsoft.CognitiveServices/accounts') {
  scope: targetAiServicesResource
  name: guid(resourceId, principalId, roleDefinitionId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalId: principalId
    principalType: principalType
  }
}

resource roleAssignmentCosmosDb 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (resourceType == 'Microsoft.DocumentDB/databaseAccounts') {
  scope: targetCosmosDbResource
  name: guid(resourceId, principalId, roleDefinitionId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalId: principalId
    principalType: principalType
  }
}

resource roleAssignmentSearch 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (resourceType == 'Microsoft.Search/searchServices') {
  scope: targetSearchResource
  name: guid(resourceId, principalId, roleDefinitionId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalId: principalId
    principalType: principalType
  }
}

@description('Role assignment ID')
output id string = resourceType == 'Microsoft.KeyVault/vaults'
  ? roleAssignmentKv.id
  : resourceType == 'Microsoft.Storage/storageAccounts'
      ? roleAssignmentStorage.id
      : resourceType == 'Microsoft.DocumentDB/databaseAccounts'
          ? roleAssignmentCosmosDb.id
          : resourceType == 'Microsoft.Search/searchServices' ? roleAssignmentSearch.id : roleAssignmentAiServices.id
