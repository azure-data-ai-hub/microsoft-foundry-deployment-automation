// Grants the Foundry project's managed identity Storage Blob Data Owner access, scoped via an
// ABAC condition to only the containers that the Agents capability host provisions for this
// project (named with the project's workspace ID prefix and an '-azureml-agent' suffix).
targetScope = 'resourceGroup'

@description('Storage account name')
param storageName string

@description('Principal ID of the Foundry project managed identity')
param projectPrincipalId string

@description('Project workspace ID (standard GUID form) used to scope the condition to the project containers')
param workspaceId string

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageName
}

// Storage Blob Data Owner (built-in role)
resource storageBlobDataOwner 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
}

var actionRead = 'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags/read'
var actionFilter = 'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/filter/action'
var actionWrite = 'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags/write'
var containerNameField = 'Microsoft.Storage/storageAccounts/blobServices/containers:name'

// ABAC condition: full access except tag read/write and filter actions, OR any action on
// containers whose name starts with this project's workspace ID and ends with '-azureml-agent'
// (the naming convention used by the containers the Agents capability host auto-provisions).
var conditionStr = '((!(ActionMatches{\'${actionRead}\'})  AND  !(ActionMatches{\'${actionFilter}\'}) AND  !(ActionMatches{\'${actionWrite}\'}) ) OR (@Resource[${containerNameField}] StringStartsWithIgnoreCase \'${workspaceId}\' AND @Resource[${containerNameField}] StringLikeIgnoreCase \'*-azureml-agent\'))'

resource storageBlobDataOwnerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, projectPrincipalId, storageBlobDataOwner.id, workspaceId)
  properties: {
    principalId: projectPrincipalId
    roleDefinitionId: storageBlobDataOwner.id
    principalType: 'ServicePrincipal'
    conditionVersion: '2.0'
    condition: conditionStr
  }
}
