# ─── Application Insights Module ─────────────────────────────────────────────
# Log Analytics Workspace + Application Insights for unified observability
# across the Agent Webapp, Weather Function, and DateTime MCP Server.

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "base_name" {
  type    = string
  default = "hybrid-agent"
}

# ─── Log Analytics Workspace ────────────────────────────────────────────────
resource "azurerm_log_analytics_workspace" "main" {
  name                = "${var.base_name}-law"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

# ─── Application Insights ───────────────────────────────────────────────────
resource "azurerm_application_insights" "main" {
  name                = "${var.base_name}-appinsights"
  location            = var.location
  resource_group_name = var.resource_group_name
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = "web"
}

# ─── Outputs ─────────────────────────────────────────────────────────────────
output "instrumentation_key" {
  value     = azurerm_application_insights.main.instrumentation_key
  sensitive = true
}

output "connection_string" {
  value     = azurerm_application_insights.main.connection_string
  sensitive = true
}

output "app_insights_id" {
  value = azurerm_application_insights.main.id
}

output "app_insights_name" {
  value = azurerm_application_insights.main.name
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.main.id
}
