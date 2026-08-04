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
// This resource group must already exist before deployment (Bicep never creates it).
// The CI/CD pipeline pre-creates it via `az group create` before invoking this template.
param resourceGroupName = 'prod-mfd-wus2-foundry-rg'

// Microsoft Foundry resource configuration (Microsoft Entra ID / AAD authentication only)
param foundryName = 'prodmfdfoundrywus2001'
param foundrySubdomain = 'prodmfdfoundrywus2001'

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
      version: '2026-04-24'
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
    name: 'gpt-chat-latest'
    model: {
      name: 'gpt-chat-latest'
      version: '2026-05-05'
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
