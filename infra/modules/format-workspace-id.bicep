// Formats a Foundry project's internalId (32-char hex, no dashes) into standard GUID form
// (8-4-4-4-12). The Agents capability host uses this workspace ID as a naming prefix for the
// Cosmos DB database/containers and Storage containers it auto-provisions for the project.
targetScope = 'resourceGroup'

@description('Project internalId (32-char hex string, no dashes)')
param projectWorkspaceId string

var g1 = substring(projectWorkspaceId, 0, 8)
var g2 = substring(projectWorkspaceId, 8, 4)
var g3 = substring(projectWorkspaceId, 12, 4)
var g4 = substring(projectWorkspaceId, 16, 4)
var g5 = substring(projectWorkspaceId, 20, 12)

@description('Project workspace ID formatted as a standard GUID')
output workspaceIdGuid string = '${g1}-${g2}-${g3}-${g4}-${g5}'
