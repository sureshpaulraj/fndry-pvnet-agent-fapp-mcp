# ─── Foundry Agent Module ────────────────────────────────────────────────────
# Deploys into the EXISTING Foundry project:
#   1. gpt-4.1-mini model deployment
#   2. Storage queues for agent-to-function tool integration
#   3. Queue DNS zone + VNet link + PE
#   4. RBAC: agent identity + function identity → queue access
#   5. Capability host (if not already present)
#
# The agent itself is created via bootstrap script (data-plane API).
# ═══════════════════════════════════════════════════════════════════════════════

terraform {
  required_providers {
    azapi = {
      source = "azure/azapi"
    }
    azurerm = {
      source = "hashicorp/azurerm"
    }
  }
}

# ─── Variables ───────────────────────────────────────────────────────────────

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "subscription_id" {
  type = string
}

variable "ai_account_id" {
  description = "Resource ID of the existing AI Services account"
  type        = string
}

variable "ai_account_name" {
  description = "Name of the existing AI Services account"
  type        = string
}

variable "ai_account_principal_id" {
  description = "System-assigned managed identity principal ID of the AI Services account"
  type        = string
}

variable "project_id" {
  description = "Resource ID of the existing Foundry project"
  type        = string
}

variable "project_principal_id" {
  description = "System-assigned managed identity principal ID of the project"
  type        = string
}

variable "model_deployment_name" {
  description = "Deployment name for gpt-4.1-mini"
  type        = string
  default     = "gpt-4.1-mini"
}

variable "model_name" {
  description = "Model name from catalog"
  type        = string
  default     = "gpt-4.1-mini"
}

variable "model_version" {
  description = "Model version"
  type        = string
  default     = "2025-04-14"
}

variable "model_format" {
  description = "Model format"
  type        = string
  default     = "OpenAI"
}

variable "model_sku_name" {
  description = "Model SKU: Standard, GlobalStandard, DataZoneStandard"
  type        = string
  default     = "GlobalStandard"
}

variable "model_capacity" {
  description = "TPM capacity for the model"
  type        = number
  default     = 30
}

variable "vnet_id" {
  description = "ID of the existing VNet"
  type        = string
}

variable "pe_subnet_id" {
  description = "ID of the existing PE subnet"
  type        = string
}

variable "agent_subnet_id" {
  description = "ID of the existing agent subnet (for capability host)"
  type        = string
}

variable "weather_function_app_id" {
  description = "Resource ID of the existing Weather Function App"
  type        = string
}

variable "weather_function_principal_id" {
  description = "Principal ID of the Weather Function App managed identity"
  type        = string
}

variable "weather_function_hostname" {
  description = "Default hostname of the Weather Function App"
  type        = string
}

variable "suffix" {
  description = "Random suffix from the root module"
  type        = string
}

variable "existing_queue_dns_zone_id" {
  description = "ID of existing privatelink.queue.core.windows.net DNS zone (from weather-function module)"
  type        = string
}

variable "existing_blob_dns_zone_id" {
  description = "ID of existing privatelink.blob.core.windows.net DNS zone (from private-endpoints module)"
  type        = string
}

# ═══════════════════════════════════════════════════════════════════════════════
# 1. Model Deployment — gpt-4.1-mini into existing account
# ═══════════════════════════════════════════════════════════════════════════════

resource "azapi_resource" "model_deployment" {
  type      = "Microsoft.CognitiveServices/accounts/deployments@2025-04-01-preview"
  name      = var.model_deployment_name
  parent_id = var.ai_account_id

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

# ═══════════════════════════════════════════════════════════════════════════════
# 2. Storage Account + Queues for Agent ↔ Function tool integration
#    Pattern: Agent sends request → input queue → Function triggers → output queue → Agent reads
# ═══════════════════════════════════════════════════════════════════════════════

resource "azurerm_storage_account" "tool_queues" {
  name                            = "toolq${var.suffix}st"
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  https_traffic_only_enabled      = true
  public_network_access_enabled   = false
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
}

resource "azurerm_storage_queue" "weather_input" {
  name               = "weather-input"
  storage_account_id = azurerm_storage_account.tool_queues.id
}

resource "azurerm_storage_queue" "weather_output" {
  name               = "weather-output"
  storage_account_id = azurerm_storage_account.tool_queues.id
}

# ═══════════════════════════════════════════════════════════════════════════════
# 3. Private Endpoint for Queue Storage (reuses existing DNS zone)
# ═══════════════════════════════════════════════════════════════════════════════

resource "azurerm_private_endpoint" "tool_queue" {
  name                = "toolq-${var.suffix}-queue-pe"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.pe_subnet_id

  private_service_connection {
    name                           = "queue"
    private_connection_resource_id = azurerm_storage_account.tool_queues.id
    subresource_names              = ["queue"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.existing_queue_dns_zone_id]
  }
}

resource "azurerm_private_endpoint" "tool_blob" {
  name                = "toolq-${var.suffix}-blob-pe"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.pe_subnet_id

  private_service_connection {
    name                           = "blob"
    private_connection_resource_id = azurerm_storage_account.tool_queues.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.existing_blob_dns_zone_id]
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# 4. RBAC — Least privilege for queue-based tool integration
# ═══════════════════════════════════════════════════════════════════════════════

# --- AI Services account identity → Storage Queue Data Contributor
# The agent runtime (via AI Services capability host) writes to input queue, reads from output queue
resource "azurerm_role_assignment" "ai_account_queue_contributor" {
  scope                = azurerm_storage_account.tool_queues.id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = var.ai_account_principal_id
}

# --- Project identity → Storage Queue Data Contributor
resource "azurerm_role_assignment" "project_queue_contributor" {
  scope                = azurerm_storage_account.tool_queues.id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = var.project_principal_id
}

# --- Weather Function identity → Storage Queue Data Contributor
# Function reads from input queue (trigger), writes to output queue
resource "azurerm_role_assignment" "func_queue_contributor" {
  scope                = azurerm_storage_account.tool_queues.id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = var.weather_function_principal_id
}

# --- AI Services account identity → Storage Blob Data Contributor (for any blob-based tool state)
resource "azurerm_role_assignment" "ai_account_blob_contributor" {
  scope                = azurerm_storage_account.tool_queues.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = var.ai_account_principal_id
}

# ═══════════════════════════════════════════════════════════════════════════════
# 5. Connection: Tool queue storage → Foundry project
# ═══════════════════════════════════════════════════════════════════════════════

resource "azapi_resource" "queue_storage_connection" {
  type      = "Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview"
  name      = "toolQueueStorage"
  parent_id = var.project_id

  body = {
    properties = {
      category = "AzureBlob"
      target   = "https://${azurerm_storage_account.tool_queues.name}.blob.core.windows.net"
      authType = "AAD"
      metadata = {
        ResourceId    = azurerm_storage_account.tool_queues.id
        AccountName   = azurerm_storage_account.tool_queues.name
        ContainerName = "default"
      }
    }
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Outputs
# ═══════════════════════════════════════════════════════════════════════════════

output "model_deployment_name" {
  value = azapi_resource.model_deployment.name
}

output "model_deployment_id" {
  value = azapi_resource.model_deployment.id
}

output "tool_queue_storage_account_name" {
  value = azurerm_storage_account.tool_queues.name
}

output "tool_queue_storage_account_id" {
  value = azurerm_storage_account.tool_queues.id
}

output "weather_input_queue_name" {
  value = azurerm_storage_queue.weather_input.name
}

output "weather_output_queue_name" {
  value = azurerm_storage_queue.weather_output.name
}
