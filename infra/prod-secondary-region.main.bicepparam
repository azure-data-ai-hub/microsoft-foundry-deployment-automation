using './main.bicep'

// SECONDARY-REGION EXAMPLE: demonstrates deploying the same production configuration to a
// second Azure region (westus2) for multi-region resilience / regional failover / model
// quota distribution. Deploy this in addition to prod.main.bicepparam (eastus) - it targets a
// separate resource group so both can coexist. Promote traffic between regions at the gateway
// layer (e.g. Apigee target routing / Azure Front Door) - this template does not manage traffic
// steering itself.
param namePrefix = 'prod-wus2'
param location = 'westus2'

param tags = {
  env: 'production'
  region: 'secondary'
  owner: 'ai-team@contoso.com'
  costCenter: 'CC-AI-PROD'
}

param projects = [
  {
    name: 'chatbot'
    description: 'Production chatbot AI project (westus2 secondary region)'
  }
  {
    name: 'analytics'
    description: 'Production analytics AI project (westus2 secondary region)'
  }
  {
    name: 'recommendations'
    description: 'Production recommendations AI project (westus2 secondary region)'
  }
]

// NOTE: Key Vault, Storage, Cosmos DB and AI Search resource names must be globally unique.
param kvName = 'prodmfdkvwus2001'
param storageName = 'prodmfdstorwus2001'
param cosmosDBName = 'prodmfdcosmoswus2001'
param aiSearchName = 'prodmfdsearchwus2001'
param resourceGroupName = 'prod-mfd-wus2-foundry-rg'

// Microsoft Foundry resource configuration (Microsoft Entra ID / AAD authentication only)
param foundryName = 'prodmfdfoundrywus2001'
param foundrySubdomain = 'prodmfdfoundrywus2001'

// Model Deployments hosted on the Foundry resource - kept identical to prod.main.bicepparam
// (eastus) so both regions serve the same model catalog. Adjust capacity per-region based on
// regional quota if needed.
param foundryModelDeployments = [
  {
    name: 'gpt-4o'
    model: {
      name: 'gpt-4o'
      version: '2024-05-13'
    }
    sku: {
      name: 'GlobalStandard'
      capacity: 50
    }
  }
  {
    name: 'gpt-4o-mini'
    model: {
      name: 'gpt-4o-mini'
      version: '2024-07-18'
    }
    sku: {
      name: 'GlobalStandard'
      capacity: 50
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
      capacity: 50
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
      capacity: 50
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
      capacity: 50
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
      capacity: 50
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
      capacity: 50
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
      capacity: 50
    }
  }
]

// Application Insights
param appInsightsName = 'prodmfdappinswus2001'

// Role Assignments - set to true if service principal has Owner/User Access Administrator role
param deployRoleAssignments = true

// Standard Agent Setup, matching the primary (eastus) production environment.
param agentSetupType = 'Standard'
