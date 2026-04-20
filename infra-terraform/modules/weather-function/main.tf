# ─── Weather Function Module ─────────────────────────────────────────────────
# Python 3.11 Function App on Flex Consumption (FC1)
# Uses azapi_resource for Flex Consumption support
# Storage Private Endpoints (Blob + Queue + File)

terraform {
  required_providers {
    azapi = {
      source = "azure/azapi"
    }
  }
}

variable "location" {
  type = string
}

variable "func_location" {
  type        = string
  default     = "eastus"
  description = "Location for the function app and service plan (separate from storage/PE region)"
}

variable "resource_group_name" {
  type = string
}

variable "vnet_id" {
  type = string
}

variable "vnet_name" {
  type = string
}

variable "integration_subnet_id" {
  type = string
}

variable "pe_subnet_id" {
  type = string
}

variable "base_name" {
  type    = string
  default = "weather"
}

variable "blob_dns_zone_id" {
  type        = string
  description = "ID of the privatelink.blob.core.windows.net DNS zone from private-endpoints module"
}

variable "blob_dns_zone_name" {
  type        = string
  description = "Name of the blob DNS zone from private-endpoints module"
}

variable "appinsights_connection_string" {
  type        = string
  description = "Application Insights connection string for telemetry"
  default     = ""
  sensitive   = true
}

# ─── Storage Account (for Functions runtime) ────────────────────────────────
resource "azurerm_storage_account" "func" {
  name                            = "${substr(var.base_name, 0, min(length(var.base_name), 20))}stor"
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  https_traffic_only_enabled      = true
  public_network_access_enabled   = false
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
}

# ─── Blob container for Flex Consumption deployment ─────────────────────────
resource "azurerm_storage_container" "deployment" {
  name                  = "app-package"
  storage_account_id    = azurerm_storage_account.func.id
  container_access_type = "private"
}

# ─── Storage Private Endpoints (Blob + Queue + File) ────────────────────────

resource "azurerm_private_endpoint" "func_blob" {
  name                = "${var.base_name}-blob-pe"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.pe_subnet_id

  private_service_connection {
    name                           = "blob"
    private_connection_resource_id = azurerm_storage_account.func.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "default"
    private_dns_zone_ids = [
      var.blob_dns_zone_id,
    ]
  }
}

resource "azurerm_private_endpoint" "func_queue" {
  name                = "${var.base_name}-queue-pe"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.pe_subnet_id

  private_service_connection {
    name                           = "queue"
    private_connection_resource_id = azurerm_storage_account.func.id
    subresource_names              = ["queue"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "default"
    private_dns_zone_ids = [
      azurerm_private_dns_zone.func_queue.id,
    ]
  }
}

resource "azurerm_private_endpoint" "func_file" {
  name                = "${var.base_name}-file-pe"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.pe_subnet_id

  private_service_connection {
    name                           = "file"
    private_connection_resource_id = azurerm_storage_account.func.id
    subresource_names              = ["file"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "default"
    private_dns_zone_ids = [
      azurerm_private_dns_zone.func_file.id,
    ]
  }
}

# ─── App Service Plan (Consumption/Serverless) ─────────────────────────────
resource "azurerm_service_plan" "func" {
  name                = "${var.base_name}-plan"
  resource_group_name = var.resource_group_name
  location            = var.location
  os_type             = "Linux"
  sku_name            = "FC1"
}

# ─── Function App (Flex Consumption via azapi) ──────────────────────────────
resource "azapi_resource" "func_app" {
  type      = "Microsoft.Web/sites@2024-04-01"
  name      = "${var.base_name}-func"
  location  = var.location
  parent_id = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${var.resource_group_name}"

  identity {
    type = "SystemAssigned"
  }

  body = {
    kind = "functionapp,linux"
    properties = {
      serverFarmId = azurerm_service_plan.func.id
      functionAppConfig = {
        deployment = {
          storage = {
            type  = "blobContainer"
            value = "https://${azurerm_storage_account.func.name}.blob.core.windows.net/${azurerm_storage_container.deployment.name}"
            authentication = {
              type = "SystemAssignedIdentity"
            }
          }
        }
        scaleAndConcurrency = {
          maximumInstanceCount = 40
          instanceMemoryMB    = 2048
        }
        runtime = {
          name    = "python"
          version = "3.11"
        }
      }
      siteConfig = {
        appSettings = [
          {
            name  = "AzureWebJobsStorage__accountName"
            value = azurerm_storage_account.func.name
          },
          {
            name  = "FUNCTIONS_EXTENSION_VERSION"
            value = "~4"
          },
          {
            name  = "APPLICATIONINSIGHTS_CONNECTION_STRING"
            value = var.appinsights_connection_string
          }
        ]
      }
      publicNetworkAccess = "Disabled"
      virtualNetworkSubnetId = var.integration_subnet_id
      vnetContentShareEnabled = true
      vnetRouteAllEnabled     = true
    }
  }

  response_export_values = ["properties.defaultHostName", "identity.principalId"]

  depends_on = [
    azurerm_private_endpoint.func_blob,
    azurerm_private_endpoint.func_queue,
    azurerm_private_endpoint.func_file,
  ]
}

data "azurerm_subscription" "current" {}


# ─── Role Assignments: Function App managed identity → Storage ───────────────
# Storage Blob Data Owner — required for Functions runtime blob triggers/state
resource "azurerm_role_assignment" "func_blob_owner" {
  scope                = azurerm_storage_account.func.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azapi_resource.func_app.identity[0].principal_id
}

# Storage Queue Data Contributor — required for Functions runtime queue processing
resource "azurerm_role_assignment" "func_queue_contributor" {
  scope                = azurerm_storage_account.func.id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = azapi_resource.func_app.identity[0].principal_id
}

# Storage Table Data Contributor — required for Functions runtime timer triggers
resource "azurerm_role_assignment" "func_table_contributor" {
  scope                = azurerm_storage_account.func.id
  role_definition_name = "Storage Table Data Contributor"
  principal_id         = azapi_resource.func_app.identity[0].principal_id
}

# Storage File Data SMB Share Contributor — for content share
resource "azurerm_role_assignment" "func_file_contributor" {
  scope                = azurerm_storage_account.func.id
  role_definition_name = "Storage File Data SMB Share Contributor"
  principal_id         = azapi_resource.func_app.identity[0].principal_id
}

# ─── Function App Private Endpoint ──────────────────────────────────────────
resource "azurerm_private_endpoint" "func_app" {
  name                = "${var.base_name}-func-pe"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.pe_subnet_id

  private_service_connection {
    name                           = "sites"
    private_connection_resource_id = azapi_resource.func_app.id
    subresource_names              = ["sites"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "default"
    private_dns_zone_ids = [
      azurerm_private_dns_zone.func_sites.id,
    ]
  }
}

# ─── Private DNS Zones ──────────────────────────────────────────────────────

resource "azurerm_private_dns_zone" "func_sites" {
  name                = "privatelink.azurewebsites.net"
  resource_group_name = var.resource_group_name
}

resource "azurerm_private_dns_zone_virtual_network_link" "func_sites" {
  name                  = "${var.vnet_name}-func-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.func_sites.name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false
}

resource "azurerm_private_dns_zone" "func_queue" {
  name                = "privatelink.queue.core.windows.net"
  resource_group_name = var.resource_group_name
}

resource "azurerm_private_dns_zone_virtual_network_link" "func_queue" {
  name                  = "${var.vnet_name}-func-queue-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.func_queue.name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false
}

resource "azurerm_private_dns_zone" "func_file" {
  name                = "privatelink.file.core.windows.net"
  resource_group_name = var.resource_group_name
}

resource "azurerm_private_dns_zone_virtual_network_link" "func_file" {
  name                  = "${var.vnet_name}-func-file-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.func_file.name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false
}

# ─── Outputs ─────────────────────────────────────────────────────────────────
output "function_app_name" {
  value = azapi_resource.func_app.name
}

output "function_app_hostname" {
  value = azapi_resource.func_app.output.properties.defaultHostName
}

output "function_app_id" {
  value = azapi_resource.func_app.id
}

output "function_app_principal_id" {
  value = azapi_resource.func_app.identity[0].principal_id
}

output "queue_dns_zone_id" {
  value = azurerm_private_dns_zone.func_queue.id
}
