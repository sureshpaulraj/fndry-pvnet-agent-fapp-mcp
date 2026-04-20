# ─── Agent Webapp Module ─────────────────────────────────────────────────────
# External Container App running the A365-compatible agent web service.
# VNet-integrated for connectivity to Weather Function (PE) and MCP Server
# (internal CAE), but externally accessible for M365 inbound messages.

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "vnet_id" {
  type        = string
  description = "VNet ID for private DNS zone link"
}

variable "agent_app_subnet_id" {
  type        = string
  description = "Subnet ID for the external Container App Environment"
}

variable "acr_login_server" {
  type        = string
  description = "ACR login server (reuse existing MCP ACR)"
}

variable "acr_admin_username" {
  type = string
}

variable "acr_admin_password" {
  type      = string
  sensitive = true
}

variable "base_name" {
  type    = string
  default = "agentapp"
}

variable "foundry_endpoint" {
  type        = string
  description = "Foundry project endpoint"
}

variable "agent_id" {
  type        = string
  description = "Foundry agent ID"
}

variable "weather_base_url" {
  type        = string
  description = "Weather Function base URL"
}

variable "weather_auth_client_id" {
  type        = string
  description = "Weather Function EasyAuth client ID"
}

variable "mcp_base_url" {
  type        = string
  description = "MCP Server base URL"
}

variable "bot_app_id" {
  type        = string
  description = "A365 Blueprint App ID (set after a365 setup)"
  default     = ""
}

variable "bot_app_secret" {
  type        = string
  description = "A365 Blueprint App secret (set after a365 setup)"
  default     = ""
  sensitive   = true
}

variable "tenant_id" {
  type = string
}

variable "appinsights_connection_string" {
  type        = string
  description = "Application Insights connection string for telemetry"
  default     = ""
  sensitive   = true
}

variable "sdk_client_id" {
  type        = string
  description = "Microsoft Agents SDK service connection client ID"
}

variable "sdk_client_secret" {
  type        = string
  description = "Microsoft Agents SDK service connection client secret"
  sensitive   = true
}

variable "sdk_auth_handler_name" {
  type        = string
  description = "Auth handler name for observability token exchange"
  default     = "AGENTIC"
}

# ─── Container Apps Environment (external, VNet-integrated) ─────────────────
resource "azurerm_container_app_environment" "agent" {
  name                           = "${var.base_name}-env"
  location                       = var.location
  resource_group_name            = var.resource_group_name
  infrastructure_subnet_id       = var.agent_app_subnet_id
  internal_load_balancer_enabled = false # External — M365 needs to reach us

  lifecycle {
    ignore_changes = [infrastructure_resource_group_name]
  }
}

# ─── Agent Webapp Container App ─────────────────────────────────────────────
resource "azurerm_container_app" "agent" {
  name                         = "${var.base_name}-app"
  container_app_environment_id = azurerm_container_app_environment.agent.id
  resource_group_name          = var.resource_group_name
  revision_mode                = "Single"

  identity {
    type = "SystemAssigned"
  }

  registry {
    server               = var.acr_login_server
    username             = var.acr_admin_username
    password_secret_name = "acr-password"
  }

  secret {
    name  = "acr-password"
    value = var.acr_admin_password
  }

  secret {
    name  = "bot-app-secret"
    value = var.bot_app_secret != "" ? var.bot_app_secret : "placeholder"
  }

  secret {
    name  = "sdk-client-secret"
    value = var.sdk_client_secret
  }

  secret {
    name  = "appinsights-connection-string"
    value = var.appinsights_connection_string != "" ? var.appinsights_connection_string : "placeholder"
  }

  ingress {
    external_enabled = true
    target_port      = 8080
    transport        = "http"

    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  template {
    min_replicas = 1
    max_replicas = 5

    container {
      name   = "agent-webapp"
      image  = "${var.acr_login_server}/agent-webapp:latest"
      cpu    = 1.0
      memory = "2Gi"

      env {
        name  = "PORT"
        value = "8080"
      }
      env {
        name  = "FOUNDRY_ENDPOINT"
        value = var.foundry_endpoint
      }
      env {
        name  = "AGENT_ID"
        value = var.agent_id
      }
      env {
        name  = "AGENT_API_VERSION"
        value = "v1"
      }
      env {
        name  = "WEATHER_BASE_URL"
        value = var.weather_base_url
      }
      env {
        name  = "WEATHER_AUTH_CLIENT_ID"
        value = var.weather_auth_client_id
      }
      env {
        name  = "MCP_BASE_URL"
        value = var.mcp_base_url
      }
      env {
        name  = "BOT_APP_ID"
        value = var.bot_app_id
      }
      env {
        name        = "BOT_APP_SECRET"
        secret_name = "bot-app-secret"
      }
      env {
        name  = "AZURE_TENANT_ID"
        value = var.tenant_id
      }
      env {
        name        = "APPLICATIONINSIGHTS_CONNECTION_STRING"
        secret_name = "appinsights-connection-string"
      }
      # Microsoft Agents SDK service connection
      env {
        name  = "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTID"
        value = var.sdk_client_id
      }
      env {
        name        = "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTSECRET"
        secret_name = "sdk-client-secret"
      }
      env {
        name  = "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__TENANTID"
        value = var.tenant_id
      }
      env {
        name  = "CONNECTIONSMAP__0__SERVICEURL"
        value = "*"
      }
      env {
        name  = "CONNECTIONSMAP__0__CONNECTION"
        value = "SERVICE_CONNECTION"
      }
      env {
        name  = "AUTH_HANDLER_NAME"
        value = var.sdk_auth_handler_name
      }

      liveness_probe {
        transport = "HTTP"
        path      = "/healthz"
        port      = 8080
      }

      readiness_probe {
        transport = "HTTP"
        path      = "/healthz"
        port      = 8080
      }
    }
  }
}

# ─── Private DNS zone link for internal MCP CAE ─────────────────────────────
# The agent-app CAE needs to resolve the internal MCP server's FQDN.
# The DNS zone already exists (created by datetime-mcp module) and is linked
# to the VNet, so any VNet-integrated workload can resolve it.
# No additional DNS config needed here — the VNet link handles it.

# ─── Outputs ─────────────────────────────────────────────────────────────────
output "agent_app_name" {
  value = azurerm_container_app.agent.name
}

output "agent_app_fqdn" {
  value = azurerm_container_app.agent.ingress[0].fqdn
}

output "agent_app_url" {
  value = "https://${azurerm_container_app.agent.ingress[0].fqdn}"
}

output "messaging_endpoint" {
  value = "https://${azurerm_container_app.agent.ingress[0].fqdn}/api/messages"
}

output "agent_app_principal_id" {
  value = azurerm_container_app.agent.identity[0].principal_id
}

output "container_app_env_name" {
  value = azurerm_container_app_environment.agent.name
}

output "container_app_env_static_ip" {
  value = azurerm_container_app_environment.agent.static_ip_address
}

output "container_app_env_default_domain" {
  value = azurerm_container_app_environment.agent.default_domain
}
