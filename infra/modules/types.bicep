// Shared user-defined types for the Microsoft Foundry deployment framework.
// Centralizing these types gives compile-time validation of .bicepparam files
// (e.g. a missing sku.capacity or a typo'd model property fails `bicep build`
// instead of failing at deployment time).

@export()
@description('Free-form resource tags (string key/value pairs)')
type tagsType = {
  *: string
}

@export()
@description('A single model deployment on the Microsoft Foundry resource')
type modelDeploymentType = {
  @description('Deployment name (used in inference API calls)')
  name: string

  @description('Underlying model identity in the Azure AI Foundry model catalog')
  model: {
    name: string
    version: string
  }

  @description('Deployment SKU (throughput type and capacity)')
  sku: {
    name: string
    capacity: int
  }
}

@export()
@description('A Foundry Project to create under the Foundry resource')
type projectType = {
  @description('Project name')
  name: string

  @description('Project description')
  description: string?
}
