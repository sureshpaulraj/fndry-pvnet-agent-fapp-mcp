# ─── Network Module ──────────────────────────────────────────────────────────
# VNet with 6 subnets:
#   agent-subnet           (10.0.0.0/24) — delegated to Microsoft.App/environments
#   pe-subnet              (10.0.1.0/24) — private endpoints
#   mcp-subnet             (10.0.2.0/24) — delegated to Microsoft.App/environments
#   func-integration-subnet(10.0.3.0/24) — delegated to Microsoft.Web/serverFarms
#   jumpbox-subnet         (10.0.4.0/24) — no delegation
#   agent-app-subnet       (10.0.5.0/23) — delegated to Microsoft.App/environments (external)

variable "location" {
  type = string
}

variable "vnet_name" {
  type = string
}

variable "agent_subnet_name" {
  type    = string
  default = "agent-subnet"
}

variable "pe_subnet_name" {
  type    = string
  default = "pe-subnet"
}

variable "mcp_subnet_name" {
  type    = string
  default = "mcp-subnet"
}

variable "func_integration_subnet_name" {
  type    = string
  default = "func-integration-subnet"
}

variable "agent_app_subnet_name" {
  type    = string
  default = "agent-app-subnet"
}

variable "resource_group_name" {
  type = string
}

resource "azurerm_virtual_network" "main" {
  name                = var.vnet_name
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "agent" {
  name                 = var.agent_subnet_name
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.0.0/24"]

  delegation {
    name = "Microsoft-App-environments"
    service_delegation {
      name = "Microsoft.App/environments"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

resource "azurerm_subnet" "pe" {
  name                              = var.pe_subnet_name
  resource_group_name               = var.resource_group_name
  virtual_network_name              = azurerm_virtual_network.main.name
  address_prefixes                  = ["10.0.1.0/24"]
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_subnet" "mcp" {
  name                 = var.mcp_subnet_name
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.2.0/24"]

  delegation {
    name = "Microsoft-App-environments"
    service_delegation {
      name = "Microsoft.App/environments"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

resource "azurerm_subnet" "func_integration" {
  name                 = var.func_integration_subnet_name
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.3.0/24"]

  delegation {
    name = "Microsoft-Web-serverFarms"
    service_delegation {
      name = "Microsoft.Web/serverFarms"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

resource "azurerm_subnet" "jumpbox" {
  name                 = "jumpbox-subnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.4.0/24"]
}

resource "azurerm_subnet" "agent_app" {
  name                 = var.agent_app_subnet_name
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.6.0/23"]

  delegation {
    name = "Microsoft-App-environments"
    service_delegation {
      name = "Microsoft.App/environments"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

# ─── Outputs ─────────────────────────────────────────────────────────────────
output "vnet_name" {
  value = azurerm_virtual_network.main.name
}

output "vnet_id" {
  value = azurerm_virtual_network.main.id
}

output "agent_subnet_id" {
  value = azurerm_subnet.agent.id
}

output "pe_subnet_id" {
  value = azurerm_subnet.pe.id
}

output "mcp_subnet_id" {
  value = azurerm_subnet.mcp.id
}

output "func_integration_subnet_id" {
  value = azurerm_subnet.func_integration.id
}

output "jumpbox_subnet_id" {
  value = azurerm_subnet.jumpbox.id
}

output "agent_app_subnet_id" {
  value = azurerm_subnet.agent_app.id
}
