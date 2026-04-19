# ─── Dependent Resources Module ──────────────────────────────────────────────
# AI Search (basic, private), Cosmos DB (private), Storage (private)

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
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

variable "search_location" {
  type    = string
  default = "eastus"
}

# ─── AI Search ───────────────────────────────────────────────────────────────
resource "azurerm_search_service" "main" {
  name                          = var.ai_search_name
  resource_group_name           = var.resource_group_name
  location                      = var.search_location
  sku                           = "free"
  public_network_access_enabled = true
}

# ─── Cosmos DB ───────────────────────────────────────────────────────────────
resource "azurerm_cosmosdb_account" "main" {
  name                          = var.cosmos_db_name
  location                      = var.location
  resource_group_name           = var.resource_group_name
  offer_type                    = "Standard"
  kind                          = "GlobalDocumentDB"
  public_network_access_enabled = false

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = var.location
    failover_priority = 0
  }
}

# ─── Storage Account ────────────────────────────────────────────────────────
resource "azurerm_storage_account" "main" {
  name                            = var.storage_name
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  https_traffic_only_enabled      = true
  public_network_access_enabled   = false
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false

  network_rules {
    default_action = "Deny"
  }
}

# ─── Outputs ─────────────────────────────────────────────────────────────────
output "ai_search_name" {
  value = azurerm_search_service.main.name
}

output "ai_search_id" {
  value = azurerm_search_service.main.id
}

output "cosmos_db_name" {
  value = azurerm_cosmosdb_account.main.name
}

output "cosmos_db_id" {
  value = azurerm_cosmosdb_account.main.id
}

output "storage_name" {
  value = azurerm_storage_account.main.name
}

output "storage_id" {
  value = azurerm_storage_account.main.id
}
