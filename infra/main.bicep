// Main Bicep Orchestrator - Microsoft Foundry Deployment
targetScope = 'subscription'

import { tagsType, modelDeploymentType, projectType } from 'modules/types.bicep'

@description('Name prefix for resources')
@minLength(2)
@maxLength(10)
param namePrefix string

@description('Azure region for resources')
param location string

@description('Environment tags')
param tags tagsType = {}

@description('Array of projects to create')
param projects projectType[] = []

@description('Key Vault name (only required when agentSetupType is Standard)')
param kvName string = ''

@description('Storage account name (only required when agentSetupType is Standard)')
param storageName string = ''

@description('Microsoft Foundry resource name (Cognitive Services account)')
param foundryName string

@description('Microsoft Foundry resource custom subdomain')
param foundrySubdomain string = ''

@description('Model deployments (e.g. GPT-4o, embeddings) to host on the Foundry resource')
param foundryModelDeployments modelDeploymentType[] = []

@description('Application Insights name')
param appInsightsName string = ''

@description('''Agent setup type for Foundry Projects:
- Basic: Microsoft manages the backing Cosmos DB/AI Search/Storage for Agents automatically.
- Standard: this repo deploys and owns the Cosmos DB, AI Search and Storage backing resources,
  wired to each project via AAD-authenticated connections and Agents capability hosts.''')
@allowed([
  'Basic'
  'Standard'
])
param agentSetupType string = 'Basic'

@description('Cosmos DB account name (only required when agentSetupType is Standard)')
param cosmosDBName string = ''

@description('Azure AI Search service name (only required when agentSetupType is Standard)')
param aiSearchName string = ''

@description('SKU for the Azure AI Search service (only used when agentSetupType is Standard)')
param aiSearchSku string = 'standard'

@description('Resource group name')
param resourceGroupName string = '${namePrefix}-foundry-rg'

@description('Deploy role assignments (Key Vault/Storage access for Foundry) and, when agentSetupType is Standard, the Standard Agent Setup RBAC and capability hosts. Requires Owner or User Access Administrator role')
param deployRoleAssignments bool = false

@description('''Deploy an Entra ID (AAD) App Registration + Service Principal for an API gateway
(e.g. Apigee) to use as an OAuth2 client-credentials client when calling this Foundry resource,
plus grant it the Cognitive Services OpenAI User role on the Foundry resource. Requires the
deploying principal to hold an Entra ID directory role capable of creating Applications/Service
Principals (e.g. Application Administrator or Cloud Application Administrator), in addition to
the Azure RBAC Owner/User Access Administrator role already required by deployRoleAssignments.''')
param deployApigeeIntegration bool = false

@description('Display name for the Apigee gateway Entra ID App Registration (only used when deployApigeeIntegration is true)')
param apigeeGatewayAppDisplayName string = '${namePrefix}-apigee-gateway'

// Variables
var mergedTags = union(
  {
    deployedBy: 'Bicep'
    iac: 'bicep'
  },
  tags
)

var isStandardAgentSetup = agentSetupType == 'Standard'

// RBAC role definition IDs (built-in roles)
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var cosmosDbOperatorRoleId = '230815da-be43-4aae-9cb4-875f7bd000aa'
var searchIndexDataContributorRoleId = '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
var searchServiceContributorRoleId = '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
var cognitiveServicesOpenAIUserRoleId = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'

// Create Resource Group
resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: mergedTags
}

// Deploy Application Insights (if name provided)
module appInsights 'modules/appinsights.bicep' = if (!empty(appInsightsName)) {
  name: 'deploy-appinsights-${uniqueString(rg.id)}'
  scope: resourceGroup(rg.name)
  params: {
    appInsightsName: appInsightsName
    location: location
    tags: mergedTags
  }
}

// Deploy Key Vault (Standard Agent Setup secret storage backing resource) - only when
// agentSetupType is Standard
module keyVault 'modules/kv.bicep' = if (isStandardAgentSetup) {
  name: 'deploy-keyvault-${uniqueString(rg.id)}'
  scope: resourceGroup(rg.name)
  params: {
    kvName: kvName
    location: location
    tags: mergedTags
    enableRbacAuthorization: true
    enablePurgeProtection: true   // Must match existing vault
    softDeleteRetentionInDays: 90 // Must match existing vault
  }
}

// Deploy Storage Account (Standard Agent Setup file storage backing resource) - only when
// agentSetupType is Standard
module storage 'modules/storage.bicep' = if (isStandardAgentSetup) {
  name: 'deploy-storage-${uniqueString(rg.id)}'
  scope: resourceGroup(rg.name)
  params: {
    storageName: storageName
    location: location
    tags: mergedTags
    skuName: 'Standard_LRS'
    enableHierarchicalNamespace: false
  }
}

// Deploy Cosmos DB (Standard Agent Setup thread/conversation storage) - only when
// agentSetupType is Standard
module cosmosDB 'modules/cosmosdb.bicep' = if (isStandardAgentSetup) {
  name: 'deploy-cosmosdb-${uniqueString(rg.id)}'
  scope: resourceGroup(rg.name)
  params: {
    cosmosDBName: cosmosDBName
    location: location
    tags: mergedTags
  }
}

// Deploy Azure AI Search (Standard Agent Setup vector store) - only when agentSetupType is
// Standard
module aiSearch 'modules/aisearch.bicep' = if (isStandardAgentSetup) {
  name: 'deploy-aisearch-${uniqueString(rg.id)}'
  scope: resourceGroup(rg.name)
  params: {
    aiSearchName: aiSearchName
    location: location
    tags: mergedTags
    skuName: aiSearchSku
  }
}

// Deploy the Microsoft Foundry resource (Cognitive Services account with
// allowProjectManagement: true). This is the modern Foundry resource model,
// replacing the legacy Hub/Project ML workspace pattern.
// Authentication is Microsoft Entra ID (AAD) only - local (API key) auth is disabled.
// The account-level Agents capability host is deployed only for the Standard Agent Setup.
module foundry 'modules/foundry.bicep' = {
  name: 'deploy-foundry-${uniqueString(rg.id)}'
  scope: resourceGroup(rg.name)
  params: {
    foundryName: foundryName
    location: location
    tags: mergedTags
    customSubDomainName: !empty(foundrySubdomain) ? foundrySubdomain : foundryName
    disableLocalAuth: true
    deployments: foundryModelDeployments
    enableAgentCapabilityHost: isStandardAgentSetup && deployRoleAssignments
  }
}

// Grant the Foundry resource's managed identity access to Key Vault (Key Vault Secrets User)
// Only relevant when agentSetupType is Standard (Key Vault is not deployed for Basic).
// Requires Owner or User Access Administrator role on the resource group
module kvRoleAssignment 'modules/role-assignment.bicep' = if (deployRoleAssignments && isStandardAgentSetup) {
  name: 'assign-kv-role-${uniqueString(rg.id)}'
  scope: resourceGroup(rg.name)
  params: {
    principalId: foundry.outputs.principalId
    roleDefinitionId: keyVaultSecretsUserRoleId
    principalType: 'ServicePrincipal'
    resourceId: keyVault.?outputs.?id ?? ''
  }
}

// Grant the Foundry resource's managed identity access to Storage (Storage Blob Data Contributor)
// Only relevant when agentSetupType is Standard (Storage is not deployed for Basic).
// Requires Owner or User Access Administrator role on the resource group
module storageRoleAssignment 'modules/role-assignment.bicep' = if (deployRoleAssignments && isStandardAgentSetup) {
  name: 'assign-storage-role-${uniqueString(rg.id)}'
  scope: resourceGroup(rg.name)
  params: {
    principalId: foundry.outputs.principalId
    roleDefinitionId: storageBlobDataContributorRoleId
    principalType: 'ServicePrincipal'
    resourceId: storage.?outputs.?id ?? ''
  }
}

// Entra ID App Registration + Service Principal for an API gateway (e.g. Apigee) that calls this
// Foundry resource using Entra ID (AAD) authentication only - no API keys involved. Optional;
// requires the deploying principal to hold an Entra ID directory role capable of creating
// Applications/Service Principals, in addition to Azure RBAC Owner/User Access Administrator.
module apigeeGatewayIdentity 'modules/entra-app-registration.bicep' = if (deployApigeeIntegration) {
  name: 'deploy-apigee-identity-${uniqueString(rg.id)}'
  scope: resourceGroup(rg.name)
  params: {
    appDisplayName: apigeeGatewayAppDisplayName
    appTags: [for tagItem in items(mergedTags): '${tagItem.key}=${tagItem.value}']
  }
}

// Grant the Apigee gateway's service principal the Cognitive Services OpenAI User role on the
// Foundry resource, so the gateway can call model inference endpoints using an Entra ID
// access token obtained via its own OAuth2 client-credentials flow.
module apigeeGatewayRoleAssignment 'modules/role-assignment.bicep' = if (deployApigeeIntegration) {
  name: 'assign-apigee-role-${uniqueString(rg.id)}'
  scope: resourceGroup(rg.name)
  params: {
    principalId: apigeeGatewayIdentity.?outputs.?servicePrincipalId ?? ''
    roleDefinitionId: cognitiveServicesOpenAIUserRoleId
    principalType: 'ServicePrincipal'
    resourceId: foundry.outputs.id
  }
}

// Deploy Foundry Projects as child resources of the Foundry resource. When agentSetupType is
// Standard, each project also gets Cosmos DB / Storage / AI Search connections.
module foundryProjects 'modules/project.bicep' = [for (project, index) in projects: {
  name: 'deploy-project-${project.name}-${uniqueString(rg.id, string(index))}'
  scope: resourceGroup(rg.name)
  params: {
    foundryName: foundry.outputs.name
    projectName: project.name
    location: location
    tags: mergedTags
    displayName: project.name
    projectDescription: project.?description ?? ''
    standardAgentSetup: isStandardAgentSetup
    cosmosDBName: cosmosDB.?outputs.?name ?? ''
    cosmosDBEndpoint: cosmosDB.?outputs.?documentEndpoint ?? ''
    cosmosDBResourceId: cosmosDB.?outputs.?id ?? ''
    azureStorageName: storage.?outputs.?name ?? ''
    azureStorageBlobEndpoint: storage.?outputs.?primaryEndpoints.?blob ?? ''
    azureStorageResourceId: storage.?outputs.?id ?? ''
    aiSearchName: aiSearch.?outputs.?name ?? ''
    aiSearchEndpoint: aiSearch.?outputs.?endpoint ?? ''
    aiSearchResourceId: aiSearch.?outputs.?id ?? ''
  }
}]

// Standard Agent Setup - per-project RBAC + capability host wiring (only deployed when
// agentSetupType is Standard and deployRoleAssignments is true).
// Ordering mirrors the Microsoft reference implementation: grant data-plane roles first,
// then create the project capability host, then grant the container/database-scoped roles
// for the containers the capability host automatically provisions.
// Requires Owner or User Access Administrator role on the resource group.
var deployStandardAgentSetupResources = isStandardAgentSetup && deployRoleAssignments

// 1) Storage Blob Data Contributor for each project's managed identity
module projectStorageRoleAssignment 'modules/role-assignment.bicep' = [for (project, index) in projects: if (deployStandardAgentSetupResources) {
  name: 'assign-proj-storage-${index}-${uniqueString(rg.id, string(index))}'
  scope: resourceGroup(rg.name)
  params: {
    principalId: foundryProjects[index].outputs.principalId
    roleDefinitionId: storageBlobDataContributorRoleId
    principalType: 'ServicePrincipal'
    resourceId: storage.?outputs.?id ?? ''
  }
}]

// 2) Cosmos DB Operator for each project's managed identity
module projectCosmosRoleAssignment 'modules/role-assignment.bicep' = [for (project, index) in projects: if (deployStandardAgentSetupResources) {
  name: 'assign-proj-cosmos-${index}-${uniqueString(rg.id, string(index))}'
  scope: resourceGroup(rg.name)
  params: {
    principalId: foundryProjects[index].outputs.principalId
    roleDefinitionId: cosmosDbOperatorRoleId
    principalType: 'ServicePrincipal'
    resourceId: cosmosDB.?outputs.?id ?? ''
  }
  dependsOn: [
    projectStorageRoleAssignment[index]
  ]
}]

// 3) Search Index Data Contributor + Search Service Contributor for each project's managed identity
module projectSearchIndexRoleAssignment 'modules/role-assignment.bicep' = [for (project, index) in projects: if (deployStandardAgentSetupResources) {
  name: 'assign-proj-search-idx-${index}-${uniqueString(rg.id, string(index))}'
  scope: resourceGroup(rg.name)
  params: {
    principalId: foundryProjects[index].outputs.principalId
    roleDefinitionId: searchIndexDataContributorRoleId
    principalType: 'ServicePrincipal'
    resourceId: aiSearch.?outputs.?id ?? ''
  }
  dependsOn: [
    projectCosmosRoleAssignment[index]
    projectStorageRoleAssignment[index]
  ]
}]

module projectSearchServiceRoleAssignment 'modules/role-assignment.bicep' = [for (project, index) in projects: if (deployStandardAgentSetupResources) {
  name: 'assign-proj-search-svc-${index}-${uniqueString(rg.id, string(index))}'
  scope: resourceGroup(rg.name)
  params: {
    principalId: foundryProjects[index].outputs.principalId
    roleDefinitionId: searchServiceContributorRoleId
    principalType: 'ServicePrincipal'
    resourceId: aiSearch.?outputs.?id ?? ''
  }
  dependsOn: [
    projectCosmosRoleAssignment[index]
    projectStorageRoleAssignment[index]
  ]
}]

// 4) Project-level Agents capability host - ties the three connections together
module projectCapabilityHost 'modules/project-capability-host.bicep' = [for (project, index) in projects: if (deployStandardAgentSetupResources) {
  name: 'caphost-project-${index}-${uniqueString(rg.id, string(index))}'
  scope: resourceGroup(rg.name)
  params: {
    foundryName: foundry.outputs.name
    projectName: foundryProjects[index].outputs.name
    cosmosDBConnectionName: foundryProjects[index].outputs.cosmosDBConnectionName
    storageConnectionName: foundryProjects[index].outputs.storageConnectionName
    aiSearchConnectionName: foundryProjects[index].outputs.aiSearchConnectionName
  }
  dependsOn: [
    projectSearchIndexRoleAssignment[index]
    projectSearchServiceRoleAssignment[index]
    projectCosmosRoleAssignment[index]
    projectStorageRoleAssignment[index]
  ]
}]

// Format each project's internalId into a standard GUID - used to scope the
// container/database-level role assignments below to this project only. Only needed for the
// Standard Agent Setup, but harmless to compute unconditionally.
module projectWorkspaceId 'modules/format-workspace-id.bicep' = [for (project, index) in projects: if (isStandardAgentSetup) {
  name: 'format-workspace-id-${index}-${uniqueString(rg.id, string(index))}'
  scope: resourceGroup(rg.name)
  params: {
    projectWorkspaceId: foundryProjects[index].outputs.workspaceId
  }
}]

// 5) Storage Blob Data Owner, scoped (via ABAC condition) to only the containers the
// capability host provisioned for this project
module projectStorageContainerRoleAssignment 'modules/storage-container-role-assignment.bicep' = [for (project, index) in projects: if (deployStandardAgentSetupResources) {
  name: 'assign-proj-storage-containers-${index}-${uniqueString(rg.id, string(index))}'
  scope: resourceGroup(rg.name)
  params: {
    storageName: storage.?outputs.?name ?? ''
    projectPrincipalId: foundryProjects[index].outputs.principalId
    workspaceId: projectWorkspaceId[index].?outputs.?workspaceIdGuid ?? ''
  }
  dependsOn: [
    projectCapabilityHost[index]
  ]
}]

// 6) Cosmos DB Built-in Data Contributor, scoped to the 'enterprise_memory' database
// the capability host provisioned for this project
module projectCosmosContainerRoleAssignment 'modules/cosmosdb-container-role-assignment.bicep' = [for (project, index) in projects: if (deployStandardAgentSetupResources) {
  name: 'assign-proj-cosmos-containers-${index}-${uniqueString(rg.id, string(index))}'
  scope: resourceGroup(rg.name)
  params: {
    cosmosDBName: cosmosDB.?outputs.?name ?? ''
    projectPrincipalId: foundryProjects[index].outputs.principalId
    projectWorkspaceId: projectWorkspaceId[index].?outputs.?workspaceIdGuid ?? ''
  }
  dependsOn: [
    projectCapabilityHost[index]
    projectStorageContainerRoleAssignment[index]
  ]
}]

// Outputs
@description('Resource Group name')
output resourceGroupName string = rg.name

@description('Microsoft Foundry resource ID')
output foundryId string = foundry.outputs.id

@description('Microsoft Foundry resource name')
output foundryName string = foundry.outputs.name

@description('Microsoft Foundry resource endpoint')
output foundryEndpoint string = foundry.outputs.endpoint

@description('Microsoft Foundry resource principal ID')
output foundryPrincipalId string = foundry.outputs.principalId

@description('Application Insights ID')
output appInsightsId string = appInsights.?outputs.?id ?? ''

@description('Key Vault ID (empty when agentSetupType is Basic)')
output keyVaultId string = keyVault.?outputs.?id ?? ''

@description('Storage Account ID (empty when agentSetupType is Basic)')
output storageAccountId string = storage.?outputs.?id ?? ''

@description('Cosmos DB account ID (empty when agentSetupType is Basic)')
output cosmosDBId string = cosmosDB.?outputs.?id ?? ''

@description('Azure AI Search service ID (empty when agentSetupType is Basic)')
output aiSearchId string = aiSearch.?outputs.?id ?? ''

@description('Apigee gateway Entra ID App (client) ID - configure as the OAuth2 client_id in Apigee (empty when deployApigeeIntegration is false)')
output apigeeGatewayAppId string = apigeeGatewayIdentity.?outputs.?appId ?? ''

@description('Apigee gateway service principal object ID (empty when deployApigeeIntegration is false)')
output apigeeGatewayServicePrincipalId string = apigeeGatewayIdentity.?outputs.?servicePrincipalId ?? ''

@description('Project IDs')
output projectIds array = [for (project, index) in projects: foundryProjects[index].outputs.id]

@description('Project names')
output projectNames array = [for (project, index) in projects: foundryProjects[index].outputs.name]
