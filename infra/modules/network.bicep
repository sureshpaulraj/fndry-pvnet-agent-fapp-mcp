@description('Azure region')
param location string

@description('VNet name')
param vnetName string

@description('Agent subnet name')
param agentSubnetName string = 'agent-subnet'

@description('Private endpoint subnet name')
param peSubnetName string = 'pe-subnet'

@description('MCP subnet name')
param mcpSubnetName string = 'mcp-subnet'

@description('Function integration subnet name')
param funcIntegrationSubnetName string = 'func-integration-subnet'

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: agentSubnetName
        properties: {
          addressPrefix: '10.0.0.0/24'
          delegations: [
            {
              name: 'Microsoft.App.environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
      {
        name: peSubnetName
        properties: {
          addressPrefix: '10.0.1.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: mcpSubnetName
        properties: {
          addressPrefix: '10.0.2.0/24'
          delegations: [
            {
              name: 'Microsoft.App.environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
      {
        name: funcIntegrationSubnetName
        properties: {
          addressPrefix: '10.0.3.0/24'
          delegations: [
            {
              name: 'Microsoft.Web.serverFarms'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
    ]
  }
}

output vnetName string = vnet.name
output vnetId string = vnet.id
output agentSubnetId string = vnet.properties.subnets[0].id
output peSubnetId string = vnet.properties.subnets[1].id
output mcpSubnetId string = vnet.properties.subnets[2].id
output funcIntegrationSubnetId string = vnet.properties.subnets[3].id
