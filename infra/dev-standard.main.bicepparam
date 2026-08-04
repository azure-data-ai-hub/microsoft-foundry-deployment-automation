using './main.bicep'

// Standard Agent Setup for DEV: this repo deploys and owns the Key Vault, Storage,
// Cosmos DB and AI Search backing resources for Agents (as opposed to dev.main.bicepparam,
// which is the minimal Basic Agent Setup / Foundry-only variant).
// See: https://learn.microsoft.com/en-us/azure/ai-foundry/agents/concepts/capability-hosts

param namePrefix = 'dev-mfd'
param location = 'eastus'

param tags = {
  env: 'dev'
  owner: 'ai-team@contoso.com'
  costCenter: 'CC-AI-DEV'
}

param projects = [
  {
    name: 'chatbot'
    description: 'Development chatbot AI project'
  }
//  {
//    name: 'analytics'
//    description: 'Development analytics AI project'
//  }
]

// This resource group must already exist before deployment (Bicep never creates it).
// The CI/CD pipeline pre-creates it via `az group create` before invoking this template.
param resourceGroupName = 'dev-mfd-foundry-standard-rg'

// Microsoft Foundry resource configuration (Microsoft Entra ID / AAD authentication only)
param foundryName = 'devmfdstdfoundry001'
param foundrySubdomain = 'devmfdstdfoundry001'

// Model Deployments hosted on the Foundry resource
param foundryModelDeployments = [
  {
    name: 'gpt-4o'
    model: {
      name: 'gpt-4o'
      version: '2024-05-13'
    }
    sku: {
      name: 'GlobalStandard'
      capacity: 10
    }
  }
  {
    // OpenAI's newest frontier model for the most complex professional work, with enhanced
    // reasoning and coding
    name: 'gpt-5.5'
    model: {
      name: 'gpt-5.5'
      version: '2026-04-24'
    }
    sku: {
      name: 'GlobalStandard'
      capacity: 10
    }
  }
  {
    // More affordable model for coding and professional work
    name: 'gpt-5.4'
    model: {
      name: 'gpt-5.4'
      version: '2026-03-05'
    }
    sku: {
      name: 'GlobalStandard'
      capacity: 10
    }
  }
  {
    // Optimized for ChatGPT-style conversational tasks
    name: 'gpt-chat-latest'
    model: {
      name: 'gpt-chat-latest'
      version: '2026-05-05'
    }
    sku: {
      name: 'GlobalStandard'
      capacity: 10
    }
  }
  {
    // Faster, cost-efficient version for well-defined tasks
    name: 'gpt-5-mini'
    model: {
      name: 'gpt-5-mini'
      version: '2025-08-07'
    }
    sku: {
      name: 'GlobalStandard'
      capacity: 10
    }
  }
  {
    // Fastest and most cost-effective, excellent for summarization and classification
    name: 'gpt-5-nano'
    model: {
      name: 'gpt-5-nano'
      version: '2025-08-07'
    }
    sku: {
      name: 'GlobalStandard'
      capacity: 10
    }
  }
  {
    name: 'text-embedding-ada-002'
    model: {
      name: 'text-embedding-ada-002'
      version: '2'
    }
    sku: {
      name: 'Standard'
      capacity: 10
    }
  }
]

// Application Insights
param appInsightsName = 'devmfdstdappins001'

// Role Assignments - set to true if service principal has Owner/User Access Administrator role
param deployRoleAssignments = true

// Standard Agent Setup (this repo deploys and owns the Key Vault, Cosmos DB, AI Search and
// Storage backing resources). All names below must be globally unique across Azure.
param agentSetupType = 'Standard'
param kvName = 'devmfdkv001'
param storageName = 'devmfdstor001'
param cosmosDBName = 'devmfdcosmos001'
// eastus is currently experiencing Cosmos DB capacity constraints (ServiceUnavailable on
// account creation) for this subscription. Override to a nearby region with available
// capacity; Cosmos DB connects to the Foundry project cross-region without issue.
param cosmosDBLocation = 'eastus2'
param aiSearchName = 'devmfdsearch001'
