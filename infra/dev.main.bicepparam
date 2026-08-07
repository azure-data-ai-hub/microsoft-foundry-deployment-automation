using './main.bicep'

// Minimal Basic Agent Setup for DEV: Foundry resource + Projects + model deployments +
// Application Insights only. Microsoft manages Cosmos DB, AI Search, and Storage for
// Agents automatically behind the scenes -- no Key Vault/Storage/Cosmos DB/AI Search
// parameters needed here.
//
// Need the full BYO-storage (Standard Agent Setup) variant instead? Use
// dev-standard.main.bicepparam, which has the additional Key Vault/Storage/Cosmos DB/
// AI Search parameters required for that mode.
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
param resourceGroupName = 'dev-mfd-foundry-rg'

// Microsoft Foundry resource configuration (Microsoft Entra ID / AAD authentication only)
param foundryName = 'devmfdfoundry001'
param foundrySubdomain = 'devmfdfoundry001'

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

// agentSetupType defaults to 'Basic' in main.bicep -- no override needed here.
