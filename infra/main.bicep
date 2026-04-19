/*
  Hybrid Private Resources Agent Setup — Public Foundry Access Mode
  Based on: https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/19-hybrid-private-resources-agent-setup

  Architecture:
    - AI Services: publicNetworkAccess = Enabled (portal-based development)
    - Backend resources: Private (AI Search, Cosmos DB, Storage)
    - Data Proxy: networkInjections configured to route to private VNet
    - Weather Azure Function: VNet Integration for outbound to private resources
    - DateTime MCP Server: Container App on mcp-subnet (internal only)
*/

@description('Location for all resources.')
@allowed([
  'westus'
  'westus2'
  'eastus'
  'eastus2'
  'japaneast'
  'francecentral'
  'swedencentral'
  'uksouth'
  'australiaeast'
  'southcentralus'
])
param location string = 'eastus2'

@description('Name for your AI Services resource.')
param aiServices string = 'aiservices'

@description('The name of the model to deploy')
param modelName string = 'gpt-4o-mini'

@description('The provider of your model')
param modelFormat string = 'OpenAI'

@description('The version of your model')
param modelVersion string = '2024-07-18'

@description('The sku of your model deployment')
param modelSkuName string = 'GlobalStandard'

@description('The TPM capacity of your model deployment')
param modelCapacity int = 30

@description('Name for your project resource.')
param firstProjectName string = 'project'

@description('Project description')
param projectDescription string = 'Hybrid agent project with Weather Function and DateTime MCP Server'

@description('Display name of the project')
param displayName string = 'hybrid-agent-project'

@description('VNet name')
param vnetName string = 'agent-vnet'

@description('Agent subnet name (reserved for AI Foundry)')
param agentSubnetName string = 'agent-subnet'

@description('Private endpoint subnet name')
param peSubnetName string = 'pe-subnet'

@description('MCP subnet name for Container Apps')
param mcpSubnetName string = 'mcp-subnet'

@description('Function integration subnet name')
param funcIntegrationSubnetName string = 'func-integration-subnet'

// Unique suffix
param deploymentTimestamp string = utcNow('yyyyMMddHHmmss')
var uniqueSuffix = substring(uniqueString('${resourceGroup().id}-${deploymentTimestamp}'), 0, 4)
var accountName = toLower('${aiServices}${uniqueSuffix}')
var projectName = toLower('${firstProjectName}${uniqueSuffix}')
var cosmosDBName = toLower('${aiServices}${uniqueSuffix}cosmosdb')
var aiSearchName = toLower('${aiServices}${uniqueSuffix}search')
var azureStorageName = toLower('${aiServices}${uniqueSuffix}st')

// =============================================
// VNet with 4 subnets
// =============================================
module network 'modules/network.bicep' = {
  name: 'network-${uniqueSuffix}'
  params: {
    location: location
    vnetName: vnetName
    agentSubnetName: agentSubnetName
    peSubnetName: peSubnetName
    mcpSubnetName: mcpSubnetName
    funcIntegrationSubnetName: funcIntegrationSubnetName
  }
}

// =============================================
// AI Services Account — PUBLIC access for portal-based development
// =============================================
module aiAccount 'modules/ai-account.bicep' = {
  name: 'ai-account-${uniqueSuffix}'
  params: {
    accountName: accountName
    location: location
    modelName: modelName
    modelFormat: modelFormat
    modelVersion: modelVersion
    modelSkuName: modelSkuName
    modelCapacity: modelCapacity
    agentSubnetId: network.outputs.agentSubnetId
  }
}

// =============================================
// Dependent Resources: AI Search, Cosmos DB, Storage
// =============================================
module dependencies 'modules/dependent-resources.bicep' = {
  name: 'dependencies-${uniqueSuffix}'
  params: {
    location: location
    aiSearchName: aiSearchName
    cosmosDBName: cosmosDBName
    azureStorageName: azureStorageName
  }
}

// =============================================
// Private Endpoints and DNS
// =============================================
module privateEndpoints 'modules/private-endpoints.bicep' = {
  name: 'private-endpoints-${uniqueSuffix}'
  params: {
    location: location
    vnetName: vnetName
    peSubnetName: peSubnetName
    aiAccountName: aiAccount.outputs.accountName
    aiSearchName: dependencies.outputs.aiSearchName
    storageName: dependencies.outputs.storageName
    cosmosDBName: dependencies.outputs.cosmosDBName
    suffix: uniqueSuffix
  }
}

// =============================================
// AI Project
// =============================================
module aiProject 'modules/ai-project.bicep' = {
  name: 'ai-project-${uniqueSuffix}'
  params: {
    projectName: projectName
    projectDescription: projectDescription
    displayName: displayName
    location: location
    accountName: aiAccount.outputs.accountName
    aiSearchName: dependencies.outputs.aiSearchName
    cosmosDBName: dependencies.outputs.cosmosDBName
    azureStorageName: dependencies.outputs.storageName
  }
  dependsOn: [
    privateEndpoints
  ]
}

// =============================================
// Weather Azure Function (VNet integrated)
// =============================================
module weatherFunction 'modules/weather-function.bicep' = {
  name: 'weather-function-${uniqueSuffix}'
  params: {
    location: location
    vnetName: vnetName
    integrationSubnetName: funcIntegrationSubnetName
    privateEndpointSubnetName: peSubnetName
    baseName: 'weather${uniqueSuffix}'
  }
  dependsOn: [
    network
  ]
}

// =============================================
// DateTime MCP Server (Container App on mcp-subnet)
// =============================================
module dateTimeMcp 'modules/datetime-mcp.bicep' = {
  name: 'datetime-mcp-${uniqueSuffix}'
  params: {
    location: location
    mcpSubnetId: network.outputs.mcpSubnetId
    baseName: 'dtmcp${uniqueSuffix}'
  }
}

// =============================================
// Outputs
// =============================================
output aiAccountName string = aiAccount.outputs.accountName
output aiAccountEndpoint string = aiAccount.outputs.accountEndpoint
output projectName string = aiProject.outputs.projectName
output vnetName string = network.outputs.vnetName
output weatherFunctionName string = weatherFunction.outputs.functionAppName
output weatherFunctionHostname string = weatherFunction.outputs.functionAppHostname
output dateTimeMcpFqdn string = dateTimeMcp.outputs.mcpFqdn
output dateTimeMcpUrl string = dateTimeMcp.outputs.mcpUrl
output dateTimeMcpAcrName string = dateTimeMcp.outputs.acrName
output dateTimeMcpAppName string = dateTimeMcp.outputs.mcpAppName
