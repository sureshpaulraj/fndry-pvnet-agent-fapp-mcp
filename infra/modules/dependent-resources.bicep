@description('Azure region')
param location string

@description('AI Search name')
param aiSearchName string

@description('Cosmos DB name')
param cosmosDBName string

@description('Storage account name')
param azureStorageName string

// AI Search — private access only
resource aiSearch 'Microsoft.Search/searchServices@2023-11-01' = {
  name: aiSearchName
  location: location
  sku: {
    name: 'basic'
  }
  properties: {
    replicaCount: 1
    partitionCount: 1
    publicNetworkAccess: 'disabled'
  }
}

// Cosmos DB — private access only
resource cosmosDB 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = {
  name: cosmosDBName
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    locations: [
      {
        locationName: location
        failoverPriority: 0
      }
    ]
    publicNetworkAccess: 'Disabled'
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
  }
}

// Storage — private access only
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: azureStorageName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
    }
  }
}

output aiSearchName string = aiSearch.name
output cosmosDBName string = cosmosDB.name
output storageName string = storage.name
