@description('Project name')
param projectName string

@description('Project description')
param projectDescription string

@description('Display name')
param displayName string

@description('Azure region')
param location string

@description('AI Account name')
param accountName string

@description('AI Search name')
param aiSearchName string

@description('Cosmos DB name')
param cosmosDBName string

@description('Storage account name')
param azureStorageName string

resource account 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: accountName
}

#disable-next-line BCP081
resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' = {
  parent: account
  name: projectName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    description: projectDescription
    displayName: displayName
  }
}

// Connection to AI Search
#disable-next-line BCP081
resource aiSearchConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = {
  parent: project
  name: 'aiSearch'
  properties: {
    category: 'CognitiveSearch'
    target: 'https://${aiSearchName}.search.windows.net'
    authType: 'AAD'
    metadata: {
      ApiType: 'Azure'
      ResourceId: resourceId('Microsoft.Search/searchServices', aiSearchName)
    }
  }
}

// Connection to Cosmos DB
#disable-next-line BCP081
resource cosmosDBConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = {
  parent: project
  name: 'cosmosDB'
  properties: {
    category: 'CosmosDB'
    target: 'https://${cosmosDBName}.documents.azure.com:443/'
    authType: 'AAD'
    metadata: {
      ResourceId: resourceId('Microsoft.DocumentDB/databaseAccounts', cosmosDBName)
    }
  }
}

// Connection to Storage
#disable-next-line BCP081
resource storageConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = {
  parent: project
  name: 'azureStorage'
  properties: {
    category: 'AzureBlob'
    target: 'https://${azureStorageName}.blob.${environment().suffixes.storage}'
    authType: 'AAD'
    metadata: {
      ResourceId: resourceId('Microsoft.Storage/storageAccounts', azureStorageName)
    }
  }
}

output projectName string = project.name
output projectWorkspaceId string = project.id
output projectPrincipalId string = project.identity.principalId
output aiSearchConnection string = aiSearchConnection.name
output cosmosDBConnection string = cosmosDBConnection.name
output azureStorageConnection string = storageConnection.name
