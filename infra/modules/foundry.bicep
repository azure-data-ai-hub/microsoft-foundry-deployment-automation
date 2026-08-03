// Microsoft Foundry Resource Module
// Deploys a Microsoft Foundry resource (Cognitive Services account, kind 'AIServices')
// with `allowProjectManagement: true`, which is the current (non-Hub) Foundry resource
// model. Foundry Projects are deployed as child resources via modules/project.bicep.
targetScope = 'resourceGroup'

import { tagsType, modelDeploymentType } from 'types.bicep'

@description('Microsoft Foundry resource name (Cognitive Services account)')
param foundryName string

@description('Azure region')
param location string

@description('Resource tags')
param tags tagsType = {}

@description('SKU for the Foundry resource')
@allowed([
  'S0'
])
param skuName string = 'S0'

@description('Custom subdomain name for the Foundry resource endpoint (required for Microsoft Entra ID auth and the Foundry portal)')
param customSubDomainName string = ''

@description('Disable local (API key) authentication - Microsoft Entra ID (AAD) is the only supported auth mode')
param disableLocalAuth bool = true

@description('Public network access setting')
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Enabled'

@description('Array of model deployments (e.g. GPT-4o, embeddings) hosted on this Foundry resource')
param deployments modelDeploymentType[] = []

@description('Name of the project to use as the default when data-plane calls omit a project')
param defaultProject string = ''

@description('Deploy the account-level Agents capability host (required for Standard Agent Setup with BYO Cosmos DB, AI Search and Storage)')
param enableAgentCapabilityHost bool = false

// The Microsoft Foundry resource. Setting allowProjectManagement to true is what turns
// this Cognitive Services account into a Foundry resource capable of hosting Projects
// as child resources (replacing the older Hub/Project ML workspace model).
resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: foundryName
  location: location
  tags: tags
  sku: {
    name: skuName
  }
  kind: 'AIServices'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: !empty(customSubDomainName) ? customSubDomainName : foundryName
    disableLocalAuth: disableLocalAuth
    publicNetworkAccess: publicNetworkAccess
    allowProjectManagement: true
    defaultProject: !empty(defaultProject) ? defaultProject : null
    networkAcls: {
      defaultAction: 'Allow' // Change to 'Deny' with ipRules for production
      bypass: 'AzureServices'
    }
  }
}

// Deploy OpenAI/Foundry models on the Foundry resource
@batchSize(1)
resource modelDeployments 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = [for deployment in deployments: {
  name: deployment.name
  parent: foundry
  sku: {
    capacity: deployment.sku.capacity
    name: deployment.sku.name
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: deployment.model.name
      version: deployment.model.version
    }
  }
}]

// Account-level capability host for the Agents feature. Required for the Standard Agent
// Setup (bring-your-own Cosmos DB, AI Search and Storage) - see project.bicep and
// modules/project-capability-host.bicep for the project-level counterpart. Not needed for
// the Basic Agent Setup, where Microsoft manages the backing resources automatically.
resource accountCapabilityHost 'Microsoft.CognitiveServices/accounts/capabilityHosts@2025-06-01' = if (enableAgentCapabilityHost) {
  name: 'caphost-account'
  parent: foundry
  properties: {
    capabilityHostKind: 'Agents'
  }
}

@description('Microsoft Foundry resource ID')
output id string = foundry.id

@description('Microsoft Foundry resource name')
output name string = foundry.name

@description('Microsoft Foundry resource endpoint')
output endpoint string = foundry.properties.endpoint

@description('System-assigned managed identity principal ID')
output principalId string = foundry.identity.principalId
