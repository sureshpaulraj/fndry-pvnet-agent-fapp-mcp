@description('AI Services account name')
param accountName string

@description('Azure region')
param location string

@description('Model name')
param modelName string

@description('Model format')
param modelFormat string

@description('Model version')
param modelVersion string

@description('Model SKU')
param modelSkuName string

@description('Model TPM capacity')
param modelCapacity int

@description('Agent subnet resource ID for network injection')
param agentSubnetId string

// Public Foundry access — portal-based development
// Change publicNetworkAccess to 'Disabled' and defaultAction to 'Deny' for full private mode
#disable-next-line BCP036
resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' = {
  name: accountName
  location: location
  sku: {
    name: 'S0'
  }
  kind: 'AIServices'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    allowProjectManagement: true
    customSubDomainName: accountName
    networkAcls: {
      defaultAction: 'Allow'    // 'Deny' for private mode
      virtualNetworkRules: []
      ipRules: []
      bypass: 'AzureServices'
    }
    publicNetworkAccess: 'Enabled'  // 'Disabled' for private mode
    networkInjections: [
      {
        scenario: 'agent'
        subnetArmId: agentSubnetId
        useMicrosoftManagedNetwork: false
      }
    ]
    disableLocalAuth: false
  }
}

#disable-next-line BCP081
resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-04-01-preview' = {
  parent: account
  name: modelName
  sku: {
    capacity: modelCapacity
    name: modelSkuName
  }
  properties: {
    model: {
      name: modelName
      format: modelFormat
      version: modelVersion
    }
  }
}

output accountName string = account.name
output accountId string = account.id
output accountEndpoint string = account.properties.endpoint
output accountPrincipalId string = account.identity.principalId
