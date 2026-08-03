// Project-level Agents capability host - Standard Agent Setup.
// Ties the project's Cosmos DB / Storage / AI Search connections together so the Agents
// service uses these bring-your-own resources instead of Microsoft-managed infrastructure.
targetScope = 'resourceGroup'

@description('Name of the Microsoft Foundry resource (Cognitive Services account)')
param foundryName string

@description('Name of the Foundry project')
param projectName string

@description('Name of the Cosmos DB connection on the project (thread storage)')
param cosmosDBConnectionName string

@description('Name of the Storage connection on the project (file storage)')
param storageConnectionName string

@description('Name of the AI Search connection on the project (vector store)')
param aiSearchConnectionName string

resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: foundryName

  resource project 'projects@2025-06-01' existing = {
    name: projectName
  }
}

resource projectCapabilityHost 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts@2025-06-01' = {
  parent: foundry::project
  name: 'caphost-project'
  properties: {
    capabilityHostKind: 'Agents'
    threadStorageConnections: [
      cosmosDBConnectionName
    ]
    storageConnections: [
      storageConnectionName
    ]
    vectorStoreConnections: [
      aiSearchConnectionName
    ]
  }
}

@description('Project capability host resource ID')
output id string = projectCapabilityHost.id
