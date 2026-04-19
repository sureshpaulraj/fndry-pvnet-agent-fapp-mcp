# ─── DateTime MCP Server Module ──────────────────────────────────────────────
# Container Registry + Container Apps Environment (internal) + Container App
# Deployed on mcp-subnet, accessible by agents via Data Proxy

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "mcp_subnet_id" {
  type = string
}

variable "vnet_id" {
  type        = string
  description = "VNet ID for private DNS zone link"
}

variable "base_name" {
  type    = string
  default = "dtmcp"

  validation {
    condition     = length(var.base_name) >= 3
    error_message = "base_name must be at least 3 characters."
  }
}

# ─── Container Registry ─────────────────────────────────────────────────────
resource "azurerm_container_registry" "mcp" {
  name                = "acr${replace(var.base_name, "-", "")}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Basic"
  admin_enabled       = true
}

# ─── Container Apps Environment (internal only, on mcp-subnet) ──────────────
resource "azurerm_container_app_environment" "mcp" {
  name                           = "${var.base_name}-env"
  location                       = var.location
  resource_group_name            = var.resource_group_name
  infrastructure_subnet_id       = var.mcp_subnet_id
  internal_load_balancer_enabled = true
}

# ─── DateTime MCP Container App ─────────────────────────────────────────────
resource "azurerm_container_app" "mcp" {
  name                         = "${var.base_name}-app"
  container_app_environment_id = azurerm_container_app_environment.mcp.id
  resource_group_name          = var.resource_group_name
  revision_mode                = "Single"

  registry {
    server               = azurerm_container_registry.mcp.login_server
    username             = azurerm_container_registry.mcp.admin_username
    password_secret_name = "acr-password"
  }

  secret {
    name  = "acr-password"
    value = azurerm_container_registry.mcp.admin_password
  }

  ingress {
    external_enabled = true # external within the env, but env is internal-only
    target_port      = 8080
    transport        = "http"

    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  template {
    min_replicas = 1
    max_replicas = 3

    container {
      name   = "datetime-mcp"
      image  = "mcr.microsoft.com/azuredocs/containerapps-helloworld:latest"
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "PORT"
        value = "8080"
      }
    }
  }
}

# ─── Private DNS Zone for internal Container App Environment ─────────────────
resource "azurerm_private_dns_zone" "cae" {
  name                = azurerm_container_app_environment.mcp.default_domain
  resource_group_name = var.resource_group_name
}

resource "azurerm_private_dns_a_record" "cae_wildcard" {
  name                = "*"
  zone_name           = azurerm_private_dns_zone.cae.name
  resource_group_name = var.resource_group_name
  ttl                 = 300
  records             = [azurerm_container_app_environment.mcp.static_ip_address]
}

resource "azurerm_private_dns_a_record" "cae_root" {
  name                = "@"
  zone_name           = azurerm_private_dns_zone.cae.name
  resource_group_name = var.resource_group_name
  ttl                 = 300
  records             = [azurerm_container_app_environment.mcp.static_ip_address]
}

resource "azurerm_private_dns_zone_virtual_network_link" "cae" {
  name                  = "cae-vnet-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.cae.name
  virtual_network_id    = var.vnet_id
}

# ─── Outputs ─────────────────────────────────────────────────────────────────
output "mcp_app_name" {
  value = azurerm_container_app.mcp.name
}

output "mcp_fqdn" {
  value = azurerm_container_app.mcp.ingress[0].fqdn
}

output "mcp_url" {
  value = "https://${azurerm_container_app.mcp.ingress[0].fqdn}"
}

output "acr_login_server" {
  value = azurerm_container_registry.mcp.login_server
}

output "acr_name" {
  value = azurerm_container_registry.mcp.name
}

output "container_app_env_name" {
  value = azurerm_container_app_environment.mcp.name
}
