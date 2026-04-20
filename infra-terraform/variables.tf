# ─── Identity ────────────────────────────────────────────────────────────────
variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
}

variable "tenant_id" {
  description = "Azure Tenant ID"
  type        = string
}

variable "client_id" {
  description = "Service Principal Application (client) ID"
  type        = string
  default     = ""
}

variable "client_secret" {
  description = "Service Principal client secret"
  type        = string
  sensitive   = true
  default     = ""
}

# ─── Resource Group & Location ───────────────────────────────────────────────
variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
  default     = "rg-hybrid-agent"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "eastus2"

  validation {
    condition     = contains(["westus", "westus2", "eastus", "eastus2", "japaneast", "francecentral", "swedencentral", "uksouth", "australiaeast", "southcentralus"], var.location)
    error_message = "Location must be one of the supported regions."
  }
}

# ─── AI Services ─────────────────────────────────────────────────────────────
variable "ai_services_name" {
  description = "Name prefix for AI Services"
  type        = string
  default     = "aiservices"
}

variable "model_name" {
  description = "Model to deploy"
  type        = string
  default     = "gpt-4o-mini"
}

variable "model_format" {
  description = "Model provider format"
  type        = string
  default     = "OpenAI"
}

variable "model_version" {
  description = "Model version"
  type        = string
  default     = "2024-07-18"
}

variable "model_sku_name" {
  description = "Model SKU"
  type        = string
  default     = "GlobalStandard"
}

variable "model_capacity" {
  description = "TPM capacity"
  type        = number
  default     = 30
}

# ─── AI Project ──────────────────────────────────────────────────────────────
variable "project_name" {
  description = "AI Foundry project name prefix"
  type        = string
  default     = "project"
}

variable "project_description" {
  description = "Project description"
  type        = string
  default     = "Hybrid agent project with Weather Function and DateTime MCP Server"
}

variable "project_display_name" {
  description = "Display name of the project"
  type        = string
  default     = "hybrid-agent-project"
}

# ─── Networking ──────────────────────────────────────────────────────────────
variable "vnet_name" {
  description = "VNet name"
  type        = string
  default     = "agent-vnet"
}

variable "agent_subnet_name" {
  description = "Agent subnet name"
  type        = string
  default     = "agent-subnet"
}

variable "pe_subnet_name" {
  description = "Private endpoint subnet name"
  type        = string
  default     = "pe-subnet"
}

variable "mcp_subnet_name" {
  description = "MCP Container Apps subnet name"
  type        = string
  default     = "mcp-subnet"
}

variable "func_integration_subnet_name" {
  description = "Function app VNet integration subnet name"
  type        = string
  default     = "func-integration-subnet"
}

# ─── Jump VM ─────────────────────────────────────────────────────────────────
variable "ssh_public_key_path" {
  description = "Path to SSH public key for Jump VM"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

# ─── Foundry Agent (gpt-4.1-mini) ───────────────────────────────────────────
variable "foundry_model_deployment_name" {
  description = "Deployment name for the agent model"
  type        = string
  default     = "gpt-4.1-mini"
}

variable "foundry_model_name" {
  description = "Model catalog name"
  type        = string
  default     = "gpt-4.1-mini"
}

variable "foundry_model_version" {
  description = "Model version"
  type        = string
  default     = "2025-04-14"
}

variable "foundry_model_sku_name" {
  description = "SKU: Standard, GlobalStandard, DataZoneStandard"
  type        = string
  default     = "GlobalStandard"
}

variable "foundry_model_capacity" {
  description = "TPM capacity"
  type        = number
  default     = 30
}

# ─── Agent Webapp (A365) ─────────────────────────────────────────────────────
variable "foundry_agent_id" {
  description = "Foundry Agent ID (from create_or_update_agent.ps1)"
  type        = string
  default     = ""
}

variable "bot_app_id" {
  description = "A365 Blueprint App ID (set after a365 setup)"
  type        = string
  default     = ""
}

variable "bot_app_secret" {
  description = "A365 Blueprint App secret (set after a365 setup)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "sdk_client_id" {
  description = "Microsoft Agents SDK service connection client ID (Blueprint App ID)"
  type        = string
  default     = ""
}

variable "sdk_client_secret" {
  description = "Microsoft Agents SDK service connection client secret"
  type        = string
  sensitive   = true
  default     = ""
}

variable "agent_app_subnet_name" {
  description = "Agent webapp Container Apps subnet name"
  type        = string
  default     = "agent-app-subnet"
}

# ─── EasyAuth for Weather Function ──────────────────────────────────────────
variable "agent_webapp_mi_app_id" {
  description = "Agent webapp managed identity Application (client) ID. Required for EasyAuth allowedApplications on weather function. Get via: az ad sp show --id <principalId> --query appId"
  type        = string
  default     = ""
}
