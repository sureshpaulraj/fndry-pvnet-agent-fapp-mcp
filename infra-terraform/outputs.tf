# ═══════════════════════════════════════════════════════════════════════════════
# Outputs
# ═══════════════════════════════════════════════════════════════════════════════

output "ai_account_name" {
  value = module.ai_account.account_name
}

output "ai_account_endpoint" {
  value = module.ai_account.account_endpoint
}

output "project_name" {
  value = module.ai_project.project_name
}

output "vnet_name" {
  value = module.network.vnet_name
}

output "weather_function_name" {
  value = module.weather_function.function_app_name
}

output "weather_function_hostname" {
  value = module.weather_function.function_app_hostname
}

output "datetime_mcp_fqdn" {
  value = module.datetime_mcp.mcp_fqdn
}

output "datetime_mcp_url" {
  value = module.datetime_mcp.mcp_url
}

output "datetime_mcp_acr_name" {
  value = module.datetime_mcp.acr_name
}

output "datetime_mcp_app_name" {
  value = module.datetime_mcp.mcp_app_name
}

# ─── Jump VM ─────────────────────────────────────────────────────────────────
output "jumpbox_public_ip" {
  value = module.jump_vm.public_ip
}

output "jumpbox_ssh_command" {
  value = "ssh ${module.jump_vm.admin_username}@${module.jump_vm.public_ip}"
}

# ─── Foundry Agent ───────────────────────────────────────────────────────────
output "foundry_model_deployment_name" {
  value = module.foundry_agent.model_deployment_name
}

output "tool_queue_storage_account" {
  value = module.foundry_agent.tool_queue_storage_account_name
}

output "weather_input_queue" {
  value = module.foundry_agent.weather_input_queue_name
}

output "weather_output_queue" {
  value = module.foundry_agent.weather_output_queue_name
}

# ─── Agent Webapp ────────────────────────────────────────────────────────────
output "agent_webapp_url" {
  value = module.agent_webapp.agent_app_url
}

output "agent_webapp_fqdn" {
  value = module.agent_webapp.agent_app_fqdn
}

output "agent_webapp_messaging_endpoint" {
  value = module.agent_webapp.messaging_endpoint
}

output "agent_webapp_principal_id" {
  value = module.agent_webapp.agent_app_principal_id
}
