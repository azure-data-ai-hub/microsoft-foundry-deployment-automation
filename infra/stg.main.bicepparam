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

// ---------------------------------------------------------------------------
// foundryModelDeployments field reference (commented out - not a live entry)
// ---------------------------------------------------------------------------
// Each array entry becomes a Microsoft.CognitiveServices/accounts/deployments child resource.
// Fields below are everything modules/types.bicep's modelDeploymentType currently supports;
// copy/uncomment as a starting point for a new deployment.
//
// {
//   name: 'my-deployment-name'   // Deployment name used in inference API calls (any string; becomes part of the API path/endpoint)
//   model: {
//     name: 'gpt-4o'             // Model name from the Foundry/Azure OpenAI model catalog
//                                // (check availability first: az cognitiveservices account list-models --name <foundryName> --resource-group <rg>)
//     version: '2024-05-13'      // Specific model version to pin. Omitting relies on a Microsoft-assigned default that can drift over time.
//   }
//   sku: {
//     name: 'GlobalStandard'     // Deployment/throughput type. Common values:
//                                //   'GlobalStandard'    - global routing, highest availability/quota headroom (preferred default)
//                                //   'Standard'           - regional routing; required for some models (e.g. embeddings) that lack GlobalStandard
//                                //   'GlobalBatch'        - global routing for the Batch API (async, lower cost, higher latency)
//                                //   'DataZoneStandard'   - data-zone-scoped routing (data residency within a geography, not a single region)
//                                //   'DataZoneBatch'      - data-zone-scoped Batch API routing
//                                //   'ProvisionedManaged' - reserved throughput (PTUs) instead of pay-as-you-go TPM
//     capacity: 10               // Throughput quota: units of 1,000 TPM (tokens-per-minute) for Standard/GlobalStandard/Batch SKUs,
//                                // or PTUs for ProvisionedManaged. Draws from the subscription's regional model quota.
//   }
// }
//
// Additional ARM properties exist on this resource type but are not yet exposed by
// modules/types.bicep + modules/foundry.bicep (extend both if you need them):
//   - properties.raiPolicyName           - Named Responsible AI content-filter policy to apply to this deployment
//   - properties.versionUpgradeOption    - 'OnceNewDefaultVersionAvailable' | 'OnceCurrentVersionExpired' | 'NoAutoUpgrade'
//   - properties.parentDeploymentName    - Name of a parent deployment, for spillover/fallback chaining
//   - properties.spilloverDeploymentName - Deployment to route to when this one is throttled
//   - sku.tier                           - 'Free' | 'Basic' | 'Standard' | 'Premium' | 'Enterprise' (rarely set explicitly for OpenAI deployments)
//   - sku.family / sku.size              - Hardware generation/size variants (not used by current OpenAI model SKUs)
// ---------------------------------------------------------------------------

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
      version: '2026-04-24'
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
    name: 'gpt-chat-latest'
    model: {
      name: 'gpt-chat-latest'
      version: '2026-05-05'
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
