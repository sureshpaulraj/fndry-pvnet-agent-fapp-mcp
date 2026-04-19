// DateTime MCP Server — Container App on VNet (internal only)
// Deployed on the mcp-subnet, accessible by agents via Data Proxy
//
// The MCP server runs as a Container App with internal-only ingress,
// meaning it's only reachable from within the VNet. Agents access it
// through the Data Proxy's network injection into the VNet.

@description('Azure region')
param location string = resourceGroup().location

@description('MCP subnet resource ID')
param mcpSubnetId string

@description('Base name for resources')
@minLength(5)
param baseName string = 'dtmcp${uniqueString(resourceGroup().id)}'

var acrName = 'acr${replace(baseName, '-', '')}'

// --- Container Registry (to host the MCP server image) ---
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  #disable-next-line BCP334
  name: acrName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: true
  }
}

// --- Container Apps Environment (internal only, on mcp-subnet) ---
resource containerAppEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: '${baseName}-env'
  location: location
  properties: {
    vnetConfiguration: {
      infrastructureSubnetId: mcpSubnetId
      internal: true
    }
  }
}

// --- DateTime MCP Container App ---
resource mcpApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: '${baseName}-app'
  location: location
  properties: {
    managedEnvironmentId: containerAppEnv.id
    configuration: {
      ingress: {
        external: true  // external within the Container Apps Env, but env is internal-only
        targetPort: 8080
        transport: 'http'
      }
      registries: [
        {
          server: acr.properties.loginServer
          username: acr.listCredentials().username
          passwordSecretRef: 'acr-password'
        }
      ]
      secrets: [
        {
          name: 'acr-password'
          value: acr.listCredentials().passwords[0].value
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'datetime-mcp'
          image: '${acr.properties.loginServer}/datetime-mcp:latest'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            {
              name: 'PORT'
              value: '8080'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 3
      }
    }
  }
}

output mcpAppName string = mcpApp.name
output mcpFqdn string = mcpApp.properties.configuration.ingress.fqdn
output mcpUrl string = 'https://${mcpApp.properties.configuration.ingress.fqdn}'
output acrLoginServer string = acr.properties.loginServer
output acrName string = acr.name
output containerAppEnvName string = containerAppEnv.name
