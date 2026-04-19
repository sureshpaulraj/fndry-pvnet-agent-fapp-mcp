# ─── AI Account Module ───────────────────────────────────────────────────────
# AI Services with public network access ENABLED (portal-based development)
# disableLocalAuth = true — enforces managed identity / DefaultAzureCredential
# Network injection for agent subnet (Data Proxy)
# Uses azapi for preview API features (networkInjections, allowProjectManagement)

terraform {
  required_providers {
    azapi = {
      source = "azure/azapi"
    }
  }
}

variable "account_name" {
  type = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "model_name" {
  type = string
}

variable "model_format" {
  type = string
}

variable "model_version" {
  type = string
}

variable "model_sku_name" {
  type = string
}

variable "model_capacity" {
  type = number
}

variable "agent_subnet_id" {
  type = string
}

# Use azapi for preview API (2025-04-01-preview) — supports networkInjections + allowProjectManagement
resource "azapi_resource" "ai_account" {
  type      = "Microsoft.CognitiveServices/accounts@2025-04-01-preview"
  name      = var.account_name
  location  = var.location
  parent_id = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${var.resource_group_name}"

  identity {
    type = "SystemAssigned"
  }

  body = {
    kind = "AIServices"
    sku = {
      name = "S0"
    }
    properties = {
      allowProjectManagement = true
      customSubDomainName    = var.account_name
      publicNetworkAccess    = "Enabled"
      disableLocalAuth       = true
      networkAcls = {
        defaultAction      = "Allow"
        virtualNetworkRules = []
        ipRules             = []
        bypass              = "AzureServices"
      }
      networkInjections = [
        {
          scenario                  = "agent"
          subnetArmId               = var.agent_subnet_id
          useMicrosoftManagedNetwork = false
        }
      ]
    }
  }
}

data "azurerm_subscription" "current" {}

# Model deployment
resource "azapi_resource" "model_deployment" {
  type      = "Microsoft.CognitiveServices/accounts/deployments@2025-04-01-preview"
  name      = var.model_name
  parent_id = azapi_resource.ai_account.id

  body = {
    sku = {
      capacity = var.model_capacity
      name     = var.model_sku_name
    }
    properties = {
      model = {
        name    = var.model_name
        format  = var.model_format
        version = var.model_version
      }
    }
  }
}

# ─── Outputs ─────────────────────────────────────────────────────────────────
output "account_name" {
  value = azapi_resource.ai_account.name
}

output "account_id" {
  value = azapi_resource.ai_account.id
}

output "account_endpoint" {
  value = azapi_resource.ai_account.output.properties.endpoint
}

output "account_principal_id" {
  value = azapi_resource.ai_account.identity[0].principal_id
}
