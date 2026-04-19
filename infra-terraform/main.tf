# ═══════════════════════════════════════════════════════════════════════════════
# Hybrid Private Resources Agent Setup — Terraform
# Based on: 19-hybrid-private-resources-agent-setup
#
# Architecture:
#   - AI Services: publicNetworkAccess = Enabled (portal-based development)
#   - Backend resources: Private (AI Search, Cosmos DB, Storage)
#   - Data Proxy: networkInjections configured to route to private VNet
#   - Weather Azure Function: VNet Integration for outbound to private resources
#   - DateTime MCP Server: Container App on mcp-subnet (internal only)
#   - Agent Webapp: Container App on agent-app-subnet (external, M365 accessible)
#
# Subscription: ME-MngEnvMCAP687688-surep-1 (2588d490-7849-4b98-9b57-8309b012872b)
# Tenant: 5d0245d3-4d99-44f5-82d3-28c83aeda726
# ═══════════════════════════════════════════════════════════════════════════════

resource "random_string" "suffix" {
  length  = 4
  special = false
  upper   = false
}

locals {
  suffix       = random_string.suffix.result
  account_name = lower("${var.ai_services_name}${local.suffix}")
  project_name = lower("${var.project_name}${local.suffix}")
  cosmos_name  = lower("${var.ai_services_name}${local.suffix}cosmosdb")
  search_name  = lower("${var.ai_services_name}${local.suffix}search")
  storage_name = lower("${var.ai_services_name}${local.suffix}st")
}

# ─── Resource Group ──────────────────────────────────────────────────────────
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
}

# ═══════════════════════════════════════════════════════════════════════════════
# VNet with 4 subnets
# ═══════════════════════════════════════════════════════════════════════════════
module "network" {
  source = "./modules/network"

  resource_group_name          = azurerm_resource_group.main.name
  location                     = var.location
  vnet_name                    = var.vnet_name
  agent_subnet_name            = var.agent_subnet_name
  pe_subnet_name               = var.pe_subnet_name
  mcp_subnet_name              = var.mcp_subnet_name
  func_integration_subnet_name = var.func_integration_subnet_name
  agent_app_subnet_name        = var.agent_app_subnet_name
}

# ═══════════════════════════════════════════════════════════════════════════════
# AI Services Account — PUBLIC access for portal-based development
# ═══════════════════════════════════════════════════════════════════════════════
module "ai_account" {
  source = "./modules/ai-account"

  account_name        = local.account_name
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  model_name          = var.model_name
  model_format        = var.model_format
  model_version       = var.model_version
  model_sku_name      = var.model_sku_name
  model_capacity      = var.model_capacity
  agent_subnet_id     = module.network.agent_subnet_id
}

# ═══════════════════════════════════════════════════════════════════════════════
# Dependent Resources: AI Search, Cosmos DB, Storage
# ═══════════════════════════════════════════════════════════════════════════════
module "dependencies" {
  source = "./modules/dependent-resources"

  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  ai_search_name      = local.search_name
  cosmos_db_name      = local.cosmos_name
  storage_name        = local.storage_name
}

# ═══════════════════════════════════════════════════════════════════════════════
# Private Endpoints and DNS
# ═══════════════════════════════════════════════════════════════════════════════
module "private_endpoints" {
  source = "./modules/private-endpoints"

  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  vnet_id             = module.network.vnet_id
  vnet_name           = module.network.vnet_name
  pe_subnet_id        = module.network.pe_subnet_id
  ai_account_id       = module.ai_account.account_id
  storage_id          = module.dependencies.storage_id
  cosmos_db_id        = module.dependencies.cosmos_db_id
  suffix              = local.suffix
}

# ═══════════════════════════════════════════════════════════════════════════════
# AI Foundry Project
# ═══════════════════════════════════════════════════════════════════════════════
module "ai_project" {
  source = "./modules/ai-project"

  project_name        = local.project_name
  project_description = var.project_description
  display_name        = var.project_display_name
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  account_id          = module.ai_account.account_id
  ai_search_name      = module.dependencies.ai_search_name
  cosmos_db_name      = module.dependencies.cosmos_db_name
  storage_name        = module.dependencies.storage_name
  subscription_id     = var.subscription_id

  depends_on = [module.private_endpoints]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Weather Azure Function (VNet integrated)
# ═══════════════════════════════════════════════════════════════════════════════
module "weather_function" {
  source = "./modules/weather-function"

  location              = var.location
  resource_group_name   = azurerm_resource_group.main.name
  vnet_id               = module.network.vnet_id
  vnet_name             = module.network.vnet_name
  integration_subnet_id = module.network.func_integration_subnet_id
  pe_subnet_id          = module.network.pe_subnet_id
  base_name             = "weather${local.suffix}"
  blob_dns_zone_id      = module.private_endpoints.blob_dns_zone_id
  blob_dns_zone_name    = module.private_endpoints.blob_dns_zone_name
}

# ═══════════════════════════════════════════════════════════════════════════════
# DateTime MCP Server (Container App on mcp-subnet)
# ═══════════════════════════════════════════════════════════════════════════════
module "datetime_mcp" {
  source = "./modules/datetime-mcp"

  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  mcp_subnet_id       = module.network.mcp_subnet_id
  vnet_id             = module.network.vnet_id
  base_name           = "dtmcp${local.suffix}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Jump VM (for testing VNet-internal resources)
# ═══════════════════════════════════════════════════════════════════════════════
module "jump_vm" {
  source = "./modules/jump-vm"

  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = module.network.jumpbox_subnet_id
  ssh_public_key      = file(var.ssh_public_key_path)
}

# ═══════════════════════════════════════════════════════════════════════════════
# Foundry Agent — gpt-4.1-mini deployment + queue-based tool integration
# Uses EXISTING Foundry account + project (no new account/project created)
# ═══════════════════════════════════════════════════════════════════════════════
module "foundry_agent" {
  source = "./modules/foundry-agent"

  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  subscription_id     = var.subscription_id
  suffix              = local.suffix

  # Existing Foundry resources
  ai_account_id           = module.ai_account.account_id
  ai_account_name         = module.ai_account.account_name
  ai_account_principal_id = module.ai_account.account_principal_id
  project_id              = module.ai_project.project_id
  project_principal_id    = module.ai_project.project_principal_id

  # Model deployment
  model_deployment_name = var.foundry_model_deployment_name
  model_name            = var.foundry_model_name
  model_version         = var.foundry_model_version
  model_format          = var.model_format
  model_sku_name        = var.foundry_model_sku_name
  model_capacity        = var.foundry_model_capacity

  # Networking
  vnet_id       = module.network.vnet_id
  pe_subnet_id  = module.network.pe_subnet_id
  agent_subnet_id = module.network.agent_subnet_id

  # Weather Function
  weather_function_app_id       = module.weather_function.function_app_id
  weather_function_principal_id = module.weather_function.function_app_principal_id
  weather_function_hostname     = module.weather_function.function_app_hostname

  # Reuse existing DNS zones
  existing_queue_dns_zone_id = module.weather_function.queue_dns_zone_id
  existing_blob_dns_zone_id  = module.private_endpoints.blob_dns_zone_id
}

# ═══════════════════════════════════════════════════════════════════════════════
# Agent Webapp (Container App — external, M365 accessible via A365)
# VNet-integrated for VNet-internal connectivity; internet-facing for M365 messages
# ═══════════════════════════════════════════════════════════════════════════════
module "agent_webapp" {
  source = "./modules/agent-webapp"

  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  vnet_id             = module.network.vnet_id
  agent_app_subnet_id = module.network.agent_app_subnet_id
  base_name           = "agentapp${local.suffix}"

  # Reuse the existing ACR from the MCP module
  acr_login_server = module.datetime_mcp.acr_login_server
  acr_admin_username = data.azurerm_container_registry.mcp.admin_username
  acr_admin_password = data.azurerm_container_registry.mcp.admin_password

  # Foundry agent config
  foundry_endpoint = "https://${module.ai_account.account_name}.services.ai.azure.com/api/projects/${module.ai_project.project_name}"
  agent_id         = var.foundry_agent_id

  # Tool backends
  weather_base_url       = "https://${module.weather_function.function_app_hostname}"
  weather_auth_client_id = var.client_id
  mcp_base_url           = module.datetime_mcp.mcp_url

  # A365 Bot Framework (set after a365 setup via tfvars)
  bot_app_id     = var.bot_app_id
  bot_app_secret = var.bot_app_secret
  tenant_id      = var.tenant_id

  depends_on = [module.datetime_mcp, module.weather_function, module.foundry_agent]
}

# ─── Data source: get ACR credentials (created by datetime_mcp module) ──────
data "azurerm_container_registry" "mcp" {
  name                = module.datetime_mcp.acr_name
  resource_group_name = azurerm_resource_group.main.name
}
