// Entra ID App Registration Module - Apigee Gateway Integration
//
// Creates a Microsoft Entra ID (AAD) application + service principal that an API gateway
// (e.g. Apigee) uses as an OAuth2 client-credentials client to obtain access tokens for calling
// the Microsoft Foundry resource. Apigee validates/exchanges caller identity and then uses this
// app's credentials to request an Entra ID access token (aud = https://cognitiveservices.azure.com)
// which is forwarded to Foundry - Foundry validates the token via Entra ID (no API keys involved).
//
// Requires the Microsoft Graph Bicep extension and a deploying principal with Entra ID permissions
// to create Applications/Service Principals (e.g. Application Administrator or Cloud Application
// Administrator directory role - this is separate from, and in addition to, the Azure RBAC
// Owner/User Access Administrator role used for the rest of this framework).
extension 'br:mcr.microsoft.com/bicep/extensions/microsoftgraph/v1.0:1.0.0'

targetScope = 'resourceGroup'

@description('Display name for the Entra ID App Registration used by the API gateway (e.g. Apigee)')
param appDisplayName string

@description('Unique name identifier for the application (used to avoid duplicate app registrations on redeploy)')
param appUniqueName string = appDisplayName

@description('Tags to apply as free-text application tags (Entra ID apps do not support ARM tags)')
param appTags array = []

// App Registration - signInAudience restricted to this tenant only (single-tenant gateway client)
resource gatewayApp 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: appUniqueName
  displayName: appDisplayName
  signInAudience: 'AzureADMyOrg'
  tags: appTags
  description: 'Client credentials app used by the API gateway (e.g. Apigee) to obtain Entra ID access tokens for calling the Microsoft Foundry resource on behalf of upstream API consumers.'
}

// Service principal for the app - this is the identity that gets Azure RBAC role assignments
resource gatewayServicePrincipal 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: gatewayApp.appId
  accountEnabled: true
}

@description('Application (client) ID - used by Apigee as the OAuth2 client_id for the client-credentials grant')
output appId string = gatewayApp.appId

@description('Application object ID')
output applicationObjectId string = gatewayApp.id

@description('Service principal object ID - used for Azure RBAC role assignments')
output servicePrincipalId string = gatewayServicePrincipal.id

@description('Service principal display name')
output servicePrincipalDisplayName string = appDisplayName
