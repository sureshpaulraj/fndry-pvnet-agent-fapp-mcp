# ─── Private Endpoints Module ────────────────────────────────────────────────
# Private endpoints + DNS zones + VNet links for:
#   AI Services, Storage Blob, Cosmos DB
# Note: AI Search uses free tier (no PE support), so it's excluded here.

variable "location" {
  type = string
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

variable "pe_subnet_id" {
  type = string
}

variable "ai_account_id" {
  type = string
}

variable "storage_id" {
  type = string
}

variable "cosmos_db_id" {
  type = string
}

variable "suffix" {
  type = string
}

# ═══════════════════════════════════════════════════════════════════════════════
# Private Endpoints
# ═══════════════════════════════════════════════════════════════════════════════

resource "azurerm_private_endpoint" "ai_services" {
  name                = "${var.suffix}-ai-pe"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.pe_subnet_id

  private_service_connection {
    name                           = "aiservices"
    private_connection_resource_id = var.ai_account_id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "default"
    private_dns_zone_ids = [
      azurerm_private_dns_zone.cognitive.id,
    ]
  }
}

resource "azurerm_private_endpoint" "storage_blob" {
  name                = "${var.suffix}-blob-pe"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.pe_subnet_id

  private_service_connection {
    name                           = "blob"
    private_connection_resource_id = var.storage_id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "default"
    private_dns_zone_ids = [
      azurerm_private_dns_zone.blob.id,
    ]
  }
}

resource "azurerm_private_endpoint" "cosmos_db" {
  name                = "${var.suffix}-cosmos-pe"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.pe_subnet_id

  private_service_connection {
    name                           = "cosmos"
    private_connection_resource_id = var.cosmos_db_id
    subresource_names              = ["Sql"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "default"
    private_dns_zone_ids = [
      azurerm_private_dns_zone.cosmos.id,
    ]
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Private DNS Zones
# ═══════════════════════════════════════════════════════════════════════════════

resource "azurerm_private_dns_zone" "cognitive" {
  name                = "privatelink.cognitiveservices.azure.com"
  resource_group_name = var.resource_group_name
}

resource "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = var.resource_group_name
}

resource "azurerm_private_dns_zone" "cosmos" {
  name                = "privatelink.documents.azure.com"
  resource_group_name = var.resource_group_name
}

# ═══════════════════════════════════════════════════════════════════════════════
# DNS Zone VNet Links
# ═══════════════════════════════════════════════════════════════════════════════

resource "azurerm_private_dns_zone_virtual_network_link" "cognitive" {
  name                  = "${var.vnet_name}-ai-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.cognitive.name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob" {
  name                  = "${var.vnet_name}-blob-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.blob.name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false
}

resource "azurerm_private_dns_zone_virtual_network_link" "cosmos" {
  name                  = "${var.vnet_name}-cosmos-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.cosmos.name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false
}

# ═══════════════════════════════════════════════════════════════════════════════
# Outputs
# ═══════════════════════════════════════════════════════════════════════════════

output "blob_dns_zone_id" {
  value = azurerm_private_dns_zone.blob.id
}

output "blob_dns_zone_name" {
  value = azurerm_private_dns_zone.blob.name
}
