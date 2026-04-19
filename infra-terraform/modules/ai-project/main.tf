# ─── AI Project Module ───────────────────────────────────────────────────────
# AI Foundry project with connections to AI Search, Cosmos DB, Storage
# Uses azapi for preview API (2025-04-01-preview) — projects + connections

terraform {
  required_providers {
    azapi = {
      source = "azure/azapi"
    }
  }
}

variable "project_name" {
  type = string
}

variable "project_description" {
  type = string
}

variable "display_name" {
  type = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "account_id" {
  type        = string
  description = "Resource ID of the parent AI Services account"
}

variable "ai_search_name" {
  type = string
}

variable "cosmos_db_name" {
  type = string
}

variable "storage_name" {
  type = string
}

variable "subscription_id" {
  type = string
}

data "azurerm_search_service" "main" {
  name                = var.ai_search_name
  resource_group_name = var.resource_group_name
}

data "azurerm_cosmosdb_account" "main" {
  name                = var.cosmos_db_name
  resource_group_name = var.resource_group_name
}

data "azurerm_storage_account" "main" {
  name                = var.storage_name
  resource_group_name = var.resource_group_name
}

# ─── AI Foundry Project ─────────────────────────────────────────────────────
resource "azapi_resource" "project" {
  type      = "Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview"
  name      = var.project_name
  location  = var.location
  parent_id = var.account_id

  identity {
    type = "SystemAssigned"
  }

  body = {
    properties = {
      description = var.project_description
      displayName = var.display_name
    }
  }
}

# ─── Connection: AI Search ───────────────────────────────────────────────────
resource "azapi_resource" "search_connection" {
  type      = "Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview"
  name      = "aiSearch"
  parent_id = azapi_resource.project.id

  body = {
    properties = {
      category = "CognitiveSearch"
      target   = "https://${var.ai_search_name}.search.windows.net"
      authType = "AAD"
      metadata = {
        ApiType    = "Azure"
        ResourceId = data.azurerm_search_service.main.id
      }
    }
  }
}

# ─── Connection: Cosmos DB ───────────────────────────────────────────────────
resource "azapi_resource" "cosmos_connection" {
  type      = "Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview"
  name      = "cosmosDB"
  parent_id = azapi_resource.project.id

  body = {
    properties = {
      category = "CosmosDB"
      target   = "https://${var.cosmos_db_name}.documents.azure.com:443/"
      authType = "AAD"
      metadata = {
        ResourceId = data.azurerm_cosmosdb_account.main.id
      }
    }
  }
}

# ─── Connection: Azure Storage ───────────────────────────────────────────────
resource "azapi_resource" "storage_connection" {
  type      = "Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview"
  name      = "azureStorage"
  parent_id = azapi_resource.project.id

  body = {
    properties = {
      category = "AzureBlob"
      target   = "https://${var.storage_name}.blob.core.windows.net"
      authType = "AAD"
      metadata = {
        ResourceId    = data.azurerm_storage_account.main.id
        ContainerName = "default"
        AccountName   = var.storage_name
      }
    }
  }
}

# ─── Outputs ─────────────────────────────────────────────────────────────────
output "project_name" {
  value = azapi_resource.project.name
}

output "project_id" {
  value = azapi_resource.project.id
}

output "project_principal_id" {
  value = azapi_resource.project.identity[0].principal_id
}
