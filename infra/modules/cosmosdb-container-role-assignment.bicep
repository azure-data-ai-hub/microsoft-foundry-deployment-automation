// Grants the Foundry project's managed identity Cosmos DB Built-in Data Contributor access,
// scoped to the 'enterprise_memory' database that the Agents capability host auto-provisions
// for this project's thread/conversation storage.
targetScope = 'resourceGroup'

@description('Cosmos DB account name')
param cosmosDBName string

@description('Principal ID of the Foundry project managed identity')
param projectPrincipalId string

@description('Project workspace ID (standard GUID form) - used only to make the role assignment name unique per project')
param projectWorkspaceId string

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = {
  name: cosmosDBName
}

// Well-known built-in "Cosmos DB Built-in Data Contributor" role definition ID
var cosmosDataContributorRoleId = '00000000-0000-0000-0000-000000000002'

resource cosmosSqlRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15' = {
  name: guid(cosmosAccount.id, projectPrincipalId, cosmosDataContributorRoleId, projectWorkspaceId)
  parent: cosmosAccount
  properties: {
    principalId: projectPrincipalId
    roleDefinitionId: resourceId('Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions', cosmosDBName, cosmosDataContributorRoleId)
    scope: '${cosmosAccount.id}/dbs/enterprise_memory'
  }
}
