// Microsoft Foundry Project Module
// Deploys a Foundry Project as a child resource of a Microsoft Foundry resource
// (Microsoft.CognitiveServices/accounts with allowProjectManagement: true). This replaces the
// legacy Microsoft.MachineLearningServices/workspaces (kind: Project) model.
//
// Supports both agent setup modes:
// - Basic Agent Setup (default): Microsoft manages the backing Cosmos DB/AI Search/Storage
//   for Agents automatically - no connections are created here.
// - Standard Agent Setup (standardAgentSetup = true): this project gets AAD-authenticated
//   connections to bring-your-own Cosmos DB, Storage and AI Search resources, which are then
//   tied together by a project-level Agents capability host (see project-capability-host.bicep).
targetScope = 'resourceGroup'

import { tagsType } from 'types.bicep'

@description('Name of the Microsoft Foundry resource (Cognitive Services account) that will host this project')
param foundryName string

@description('Project name')
param projectName string

@description('Azure region (must match the parent Foundry resource region)')
param location string

@description('Resource tags')
param tags tagsType = {}

@description('Display name for the project')
param displayName string = ''

@description('Description of the project')
param projectDescription string = ''

@description('Deploy Standard Agent Setup connections (Cosmos DB, Storage, AI Search) on this project')
param standardAgentSetup bool = false

@description('Cosmos DB account name (thread storage for the Standard Agent Setup)')
param cosmosDBName string = ''

@description('Cosmos DB document endpoint')
param cosmosDBEndpoint string = ''

@description('Cosmos DB account resource ID (for connection metadata)')
param cosmosDBResourceId string = ''

@description('Storage account name (BYO storage for the Standard Agent Setup)')
param azureStorageName string = ''

@description('Storage account primary blob endpoint')
param azureStorageBlobEndpoint string = ''

@description('Storage account resource ID (for connection metadata)')
param azureStorageResourceId string = ''

@description('Azure AI Search service name (vector store for the Standard Agent Setup)')
param aiSearchName string = ''

@description('Azure AI Search service endpoint')
param aiSearchEndpoint string = ''

@description('AI Search service resource ID (for connection metadata)')
param aiSearchResourceId string = ''

// Reference to the existing Microsoft Foundry resource
resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: foundryName
}

resource foundryProject 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: foundry
  name: projectName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: !empty(displayName) ? displayName : projectName
    description: projectDescription
  }

  // Project-level connections used by the Standard Agent Setup capability host
  // (thread storage, vector store and BYO storage). Auth is AAD-only. Only created when
  // standardAgentSetup is true.
  resource cosmosDbConnection 'connections@2025-06-01' = if (standardAgentSetup) {
    name: cosmosDBName
    properties: {
      category: 'CosmosDB'
      target: cosmosDBEndpoint
      authType: 'AAD'
      metadata: {
        ApiType: 'Azure'
        ResourceId: cosmosDBResourceId
        location: location
      }
    }
  }

  resource storageConnection 'connections@2025-06-01' = if (standardAgentSetup) {
    name: azureStorageName
    properties: {
      category: 'AzureStorageAccount'
      target: azureStorageBlobEndpoint
      authType: 'AAD'
      metadata: {
        ApiType: 'Azure'
        ResourceId: azureStorageResourceId
        location: location
      }
    }
  }

  resource aiSearchConnection 'connections@2025-06-01' = if (standardAgentSetup) {
    name: aiSearchName
    properties: {
      category: 'CognitiveSearch'
      target: aiSearchEndpoint
      authType: 'AAD'
      metadata: {
        ApiType: 'Azure'
        ResourceId: aiSearchResourceId
        location: location
      }
    }
  }
}

@description('Project resource ID')
output id string = foundryProject.id

@description('Project name')
output name string = foundryProject.name

@description('System-assigned managed identity principal ID')
output principalId string = foundryProject.identity.principalId

// The internalId is the project's workspace ID (GUID, no dashes) used to name the
// Cosmos DB/Storage containers that the Agents capability host provisions automatically.
// Only meaningful for the Standard Agent Setup.
#disable-next-line BCP053
output workspaceId string = foundryProject.properties.internalId

@description('Name of the Cosmos DB connection on this project (empty when standardAgentSetup is false)')
output cosmosDBConnectionName string = standardAgentSetup ? cosmosDBName : ''

@description('Name of the Storage connection on this project (empty when standardAgentSetup is false)')
output storageConnectionName string = standardAgentSetup ? azureStorageName : ''

@description('Name of the AI Search connection on this project (empty when standardAgentSetup is false)')
output aiSearchConnectionName string = standardAgentSetup ? aiSearchName : ''
