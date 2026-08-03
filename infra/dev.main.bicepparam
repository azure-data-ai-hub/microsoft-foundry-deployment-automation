using './main.bicep'

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
param foundryName = 'devmfdfoundry001'
param foundrySubdomain = 'devmfdfoundry001'

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
param appInsightsName = 'devmfdappins001'

// Role Assignments - set to true if service principal has Owner/User Access Administrator role
param deployRoleAssignments = true

// NOTE: AI Agents use Basic Agent Setup (Microsoft-managed infrastructure)
// Create agents via Azure AI Foundry portal or SDK - no additional Bicep deployment needed
// Microsoft automatically manages Cosmos DB, AI Search, and Storage for agents.
// Key Vault and Storage are NOT deployed in Basic mode - they are only needed (and only
// deployed) as Standard Agent Setup backing resources.
//
// To switch to Standard Agent Setup (this repo deploys and owns the Key Vault, Cosmos DB,
// AI Search and Storage backing resources), uncomment the lines below and set globally-unique
// names (all four must be globally unique across Azure):
param agentSetupType = 'Standard'
param kvName = 'devmfdkv001'
param storageName = 'devmfdstor001'
param cosmosDBName = 'devmfdcosmos001'
param aiSearchName = 'devmfdsearch001'
// See: https://learn.microsoft.com/en-us/azure/ai-foundry/agents/concepts/capability-hosts
