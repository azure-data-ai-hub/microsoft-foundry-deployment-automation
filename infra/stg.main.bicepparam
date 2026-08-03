using './main.bicep'

param namePrefix = 'stg-mfd'
param location = 'eastus'

param tags = {
  env: 'staging'
  owner: 'ai-team@contoso.com'
  costCenter: 'CC-AI-STG'
}

param projects = [
  {
    name: 'chatbot'
    description: 'Staging chatbot AI project for pre-production testing'
  }
  {
    name: 'analytics'
    description: 'Staging analytics AI project for pre-production testing'
  }
]

// This resource group must already exist before deployment (Bicep never creates it).
// The CI/CD pipeline pre-creates it via `az group create` before invoking this template.
param resourceGroupName = 'stg-mfd-foundry-rg'

// Microsoft Foundry resource configuration (Microsoft Entra ID / AAD authentication only)
param foundryName = 'stgmfdfoundry001'
param foundrySubdomain = 'stgmfdfoundry001'

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
      capacity: 20
    }
  }
  {
    // OpenAI's newest frontier model for the most complex professional work, with enhanced
    // reasoning and coding
    name: 'gpt-5.5'
    model: {
      name: 'gpt-5.5'
      version: '2026-04-23'
    }
    sku: {
      name: 'GlobalStandard'
      capacity: 20
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
      capacity: 20
    }
  }
  {
    // Optimized for ChatGPT-style conversational tasks
    name: 'gpt-5.3'
    model: {
      name: 'gpt-5.3'
      version: 'chat-latest'
    }
    sku: {
      name: 'GlobalStandard'
      capacity: 20
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
      capacity: 20
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
      capacity: 20
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
      capacity: 20
    }
  }
]

// Application Insights
param appInsightsName = 'stgmfdappins001'

// Role Assignments - set to true if service principal has Owner/User Access Administrator role
param deployRoleAssignments = true

// NOTE: AI Agents use Basic Agent Setup (Microsoft-managed infrastructure)
// Create agents via Azure AI Foundry portal or SDK - no additional Bicep deployment needed
// Key Vault and Storage are NOT deployed in Basic mode - they are only needed (and only
// deployed) as Standard Agent Setup backing resources.
//
// To switch to Standard Agent Setup (this repo deploys and owns the Key Vault, Cosmos DB,
// AI Search and Storage backing resources), uncomment the lines below and set globally-unique
// names (all four must be globally unique across Azure):
// param agentSetupType = 'Standard'
// param kvName = 'stgmfdkv001'
// param storageName = 'stgmfdstor001'
// param cosmosDBName = 'stgmfdcosmos001'
// param aiSearchName = 'stgmfdsearch001'
