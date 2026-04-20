# Troubleshooting Guide

A step-by-step troubleshooting reference for common issues encountered when deploying and operating the Hybrid Network AI Agent. For full deployment instructions, see the [Setup Guide](SETUP-GUIDE.md).

---

## Table of Contents

1. [Agent Webapp Won't Start](#1-agent-webapp-wont-start)
2. [Webapp Returns 401/403 to Bot Framework](#2-webapp-returns-401403-to-bot-framework)
3. [Foundry Agent API Returns 403 Forbidden](#3-foundry-agent-api-returns-403-forbidden)
4. [Weather Function Returns 401 from Agent Webapp](#4-weather-function-returns-401-from-agent-webapp)
5. [MCP Server Unreachable from Agent Webapp](#5-mcp-server-unreachable-from-agent-webapp)
6. [AGENT_ID is Empty — Agent Runs Fail](#6-agent_id-is-empty--agent-runs-fail)
7. [Docker Build / ACR Push Fails on Windows](#7-docker-build--acr-push-fails-on-windows)
8. [Terraform Apply Errors](#8-terraform-apply-errors)
9. [Jump VM Cannot SSH](#9-jump-vm-cannot-ssh)
10. [App Insights Shows No Telemetry](#10-app-insights-shows-no-telemetry)
11. [Teams Shows No Response from Agent](#11-teams-shows-no-response-from-agent)
12. [Weather Function Healthy but Returns Errors](#12-weather-function-healthy-but-returns-errors)

---

## 1. Agent Webapp Won't Start

**Symptom:** Container App shows `CrashLoopBackOff` or restarts repeatedly. Logs show `ValueError` or `KeyError` at startup.

**Root Cause:** Missing Microsoft Agents SDK environment variables.

**Diagnosis:**
```powershell
# Check container logs
az containerapp logs show --name agentappk71j-app --resource-group rg-hybrid-agent --tail 50

# Check env vars are set
az containerapp show --name agentappk71j-app --resource-group rg-hybrid-agent \
    --query "properties.template.containers[0].env[].name" -o tsv
```

**Required env vars (all must be present):**
| Variable | Value |
|----------|-------|
| `CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTID` | Blueprint app registration client ID |
| `CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTSECRET` | Blueprint app secret |
| `CONNECTIONS__SERVICE_CONNECTION__SETTINGS__TENANTID` | Entra tenant ID |
| `CONNECTIONSMAP__0__SERVICEURL` | `*` |
| `CONNECTIONSMAP__0__CONNECTION` | `SERVICE_CONNECTION` |
| `AUTH_HANDLER_NAME` | `AGENTIC` |
| `AGENT_ID` | Foundry agent ID (e.g. `asst_fAVIpp16...`) |
| `FOUNDRY_ENDPOINT` | Full Foundry project endpoint URL |

**Fix:** Update Terraform `terraform.tfvars` with correct values and re-apply, or update the Container App directly:
```powershell
az containerapp update --name agentappk71j-app --resource-group rg-hybrid-agent \
    --set-env-vars "CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTID=<value>" ...
```

> See [Setup Guide — Phase 5: Deploy Agent Webapp](SETUP-GUIDE.md) for the full env var list.

---

## 2. Webapp Returns 401/403 to Bot Framework

**Symptom:** Teams shows "Sorry, something went wrong" or no response. Container logs show authentication validation failures.

**Root Cause:** Blueprint app registration misconfigured, or the Bot Framework Connector can't validate the channel token.

**Diagnosis:**
```powershell
# Check container logs for auth errors
az containerapp logs show --name agentappk71j-app --resource-group rg-hybrid-agent --tail 100 \
    | Select-String -Pattern "401|403|auth|token|unauthorized"
```

**Checklist:**
1. Blueprint app `CLIENTID` matches what's registered in the A365/Bot Framework manifest
2. Blueprint `CLIENTSECRET` is not expired
3. `TENANTID` is the correct Entra tenant
4. The app registration has `BotFramework` API permissions granted
5. `CONNECTIONSMAP__0__SERVICEURL` is set to `*` (accepts all Bot Connector service URLs)

**Fix:** Verify app registration in Azure Portal → Entra ID → App registrations → find the Blueprint app → check Certificates & secrets for expiry. Re-generate if needed and update Terraform/Container App.

---

## 3. Foundry Agent API Returns 403 Forbidden

**Symptom:** Agent webapp logs show `403` when calling Foundry Assistants API (`POST /threads`, `POST /runs`). Error message mentions insufficient permissions.

**Root Cause:** `Azure AI Developer` role alone does NOT cover `AIServices/agents/*` data actions. You need `Cognitive Services User` at **project scope**.

**Diagnosis:**
```powershell
# Check current role assignments for the managed identity
$principalId = az containerapp show --name agentappk71j-app --resource-group rg-hybrid-agent \
    --query "identity.principalId" -o tsv

az role assignment list --assignee $principalId --all -o table
```

**Required roles (at BOTH account AND project scope):**
| Role | Scope |
|------|-------|
| `Cognitive Services User` | AI Services account |
| `Azure AI Developer` | AI Services account |
| `Cognitive Services User` | Foundry project |
| `Azure AI Developer` | Foundry project |
| `Cognitive Services OpenAI User` | AI Services account |

**Fix:** Assign missing roles at project scope:
```powershell
$projectScope = "/subscriptions/<sub-id>/resourceGroups/rg-hybrid-agent/providers/Microsoft.CognitiveServices/accounts/<ai-svc-name>/projects/<project-name>"

az role assignment create --assignee $principalId --role "Cognitive Services User" --scope $projectScope
az role assignment create --assignee $principalId --role "Azure AI Developer" --scope $projectScope
```

> **Key insight:** Account-level roles are insufficient for Foundry Agents API. You must assign at the project scope.

---

## 4. Weather Function Returns 401 from Agent Webapp

**Symptom:** Weather tool calls fail with 401 Unauthorized. Jump VM calls (with client secret credential) work fine, but the agent webapp's managed identity is rejected.

**Root Cause:** The managed identity's **Application (client) ID** is not in EasyAuth's `allowedApplications` list.

**Diagnosis:**
```powershell
# Get the MI's application ID (NOT the principal ID)
$principalId = az containerapp show --name agentappk71j-app --resource-group rg-hybrid-agent \
    --query "identity.principalId" -o tsv

$miAppId = az ad sp show --id $principalId --query appId -o tsv
Write-Host "MI App ID: $miAppId"

# Check current EasyAuth config
az rest --method get \
    --url "/subscriptions/<sub-id>/resourceGroups/rg-hybrid-agent/providers/Microsoft.Web/sites/<func-name>/config/authsettingsV2?api-version=2022-03-01" \
    --query "properties.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedApplications"
```

**Fix:** Add the MI's `appId` to `allowedApplications` in the EasyAuth config. Create `easyauth-fix.json` with both the EasyAuth client ID and the MI appId, then apply with `PUT`:
```powershell
az rest --method put \
    --url "/subscriptions/<sub-id>/resourceGroups/rg-hybrid-agent/providers/Microsoft.Web/sites/<func-name>/config/authsettingsV2?api-version=2022-03-01" \
    --body "@easyauth-fix.json"
```

> **Critical:** Use `PUT` not `PATCH` — the authsettingsV2 endpoint does not support PATCH. Include the **full** configuration or missing fields will be reset.

> See [Setup Guide — Step 8b](SETUP-GUIDE.md) and [SKILL.md — Lesson #20](SKILL.md) for the full `easyauth-fix.json` template.

---

## 5. MCP Server Unreachable from Agent Webapp

**Symptom:** DateTime tool calls time out or return connection errors. The MCP server is healthy when tested from the Jump VM.

**Root Cause:** Private DNS resolution. The agent webapp's external CAE must be able to resolve the internal CAE's FQDN via VNet DNS.

**Diagnosis:**
```powershell
# Test from Jump VM (should work since it's on the same VNet)
ssh azureuser@<jumpbox-ip> "curl -s https://dtmcpk71j-app.niceriver-877b9fd9.eastus2.azurecontainerapps.io/healthz"

# Check the Private DNS zone has VNet link
az network private-dns link vnet list \
    --zone-name "niceriver-877b9fd9.eastus2.azurecontainerapps.io" \
    --resource-group rg-hybrid-agent -o table

# Check A records exist
az network private-dns record-set a list \
    --zone-name "niceriver-877b9fd9.eastus2.azurecontainerapps.io" \
    --resource-group rg-hybrid-agent -o table
```

**Required DNS configuration:**
- Private DNS zone for the internal CAE domain (e.g. `niceriver-877b9fd9.eastus2.azurecontainerapps.io`)
- Wildcard `*` A record → CAE static IP (e.g. `10.0.2.160`)
- Root `@` A record → CAE static IP
- VNet link connecting the DNS zone to `agent-vnet`

**Fix:** If the VNet link is missing, create it:
```powershell
az network private-dns link vnet create \
    --zone-name "niceriver-877b9fd9.eastus2.azurecontainerapps.io" \
    --resource-group rg-hybrid-agent \
    --name cae-vnet-link \
    --virtual-network agent-vnet \
    --registration-enabled false
```

---

## 6. AGENT_ID is Empty — Agent Runs Fail

**Symptom:** Agent webapp starts but every message fails with "agent not found" or empty agent ID errors. Logs show `AGENT_ID=''`.

**Root Cause:** Terraform `default = ""` overrides Python's `os.getenv("AGENT_ID", "asst_xxx")` fallback — an empty string is still a value, not `None`.

**Diagnosis:**
```powershell
az containerapp show --name agentappk71j-app --resource-group rg-hybrid-agent \
    --query "properties.template.containers[0].env[?name=='AGENT_ID'].value" -o tsv
```

**Fix:** Set the actual Foundry agent ID in `terraform.tfvars`:
```hcl
agent_id = "asst_fAVIpp16oVnfHaBuCo1BtvJ9"
```

Then re-apply Terraform, or update directly:
```powershell
az containerapp update --name agentappk71j-app --resource-group rg-hybrid-agent \
    --set-env-vars "AGENT_ID=asst_fAVIpp16oVnfHaBuCo1BtvJ9"
```

> The Foundry agent ID is obtained after running the agent creation script. See [Setup Guide — Phase 4](SETUP-GUIDE.md).

---

## 7. Docker Build / ACR Push Fails on Windows

**Symptom:** `az acr build` fails with `charmap` codec / `UnicodeDecodeError` on Windows.

**Root Cause:** The `az acr build` command streams Docker build output through Windows' default `charmap` codec, which cannot handle certain Unicode characters in build logs.

**Fix:** Use local Docker build + push instead:
```powershell
# Login to ACR
az acr login --name acrdtmcpk71j

# Build locally
cd mcp-server
docker build -t acrdtmcpk71j.azurecr.io/datetime-mcp:latest .

# Push to ACR
docker push acrdtmcpk71j.azurecr.io/datetime-mcp:latest

# Same for agent-webapp
cd ..\agent-webapp
docker build -t acrdtmcpk71j.azurecr.io/agent-webapp:latest .
docker push acrdtmcpk71j.azurecr.io/agent-webapp:latest
```

> **Prerequisite:** Docker Desktop must be installed and running. See [Setup Guide — Prerequisites](SETUP-GUIDE.md).

---

## 8. Terraform Apply Errors

### 8a. Container App Environment `infrastructure_resource_group_name` drift

**Symptom:** Terraform wants to destroy and recreate the CAE because `infrastructure_resource_group_name` changed.

**Fix:** Add lifecycle ignore to the CAE resource:
```hcl
lifecycle {
  ignore_changes = [infrastructure_resource_group_name]
}
```

### 8b. "Resource already exists" on import

**Symptom:** Terraform fails because Azure resources were created outside Terraform (e.g. via portal or CLI).

**Fix:** Import existing resources into state:
```powershell
terraform import "module.<module>.azurerm_<type>.<name>" "<azure-resource-id>"
```

### 8c. Missing `TF_VAR_client_secret` or `TF_VAR_sdk_client_secret`

**Symptom:** Terraform plan/apply fails with "No value for required variable".

**Fix:** Set both secrets before running Terraform:
```powershell
$env:TF_VAR_client_secret = "<bot-app-secret>"
$env:TF_VAR_sdk_client_secret = "<blueprint-app-secret>"
terraform apply
```

### 8d. `azapi_resource` for EasyAuth — wrong API version

**Symptom:** EasyAuth PUT via `azapi_resource` fails with 404 or schema errors.

**Fix:** Use API version `2022-03-01` and resource type `Microsoft.Web/sites/config`:
```hcl
resource "azapi_resource" "weather_easyauth" {
  type      = "Microsoft.Web/sites/config@2022-03-01"
  name      = "authsettingsV2"
  parent_id = module.weather_function.function_app_id
  body      = jsonencode({ properties = { ... } })
}
```

---

## 9. Jump VM Cannot SSH

**Symptom:** `ssh azureuser@<public-ip>` times out or is refused.

**Diagnosis:**
```powershell
Test-NetConnection <public-ip> -Port 22
```

**Checklist:**
1. **NIC-level NSG** (`jumpbox-vm-nsg`) has `AllowSSH` rule: TCP/22, Priority 100
2. **Subnet-level NSG** (`agent-vnet-jumpbox-subnet-nsg-eastus2`) also has `AllowSSH` rule
3. VM is running: `az vm show -g rg-hybrid-agent --name jumpbox-vm --query "powerState"`
4. Public IP is assigned: `az vm show -g rg-hybrid-agent --name jumpbox-vm -d --query publicIps`

> **Key insight:** Both NIC-level and subnet-level NSGs must independently allow SSH. If either blocks it, the connection fails.

---

## 10. App Insights Shows No Telemetry

**Symptom:** Application Insights blade shows no requests, traces, or metrics.

**Diagnosis:**
```powershell
# Check the connection string is set on each service
az containerapp show --name agentappk71j-app --resource-group rg-hybrid-agent \
    --query "properties.template.containers[0].env[?name=='APPLICATIONINSIGHTS_CONNECTION_STRING'].value" -o tsv

az functionapp config appsettings list --name weatherk71j-func --resource-group rg-hybrid-agent \
    --query "[?name=='APPLICATIONINSIGHTS_CONNECTION_STRING'].value" -o tsv
```

**Checklist:**
1. `APPLICATIONINSIGHTS_CONNECTION_STRING` is set and not `"placeholder"` on all 3 services
2. `azure-monitor-opentelemetry` package is in each service's `requirements.txt`
3. `configure_azure_monitor()` is called **before** other imports in each service's entry point
4. The `logger_name` is set per service (`agent-webapp`, `weather-function`, `datetime-mcp`)

**Fix:** If the connection string is `placeholder` or empty, update it from the App Insights resource:
```powershell
$connStr = az monitor app-insights component show --app hybrid-agent-k71j-appinsights \
    --resource-group rg-hybrid-agent --query connectionString -o tsv

az containerapp update --name agentappk71j-app --resource-group rg-hybrid-agent \
    --set-env-vars "APPLICATIONINSIGHTS_CONNECTION_STRING=$connStr"
```

> Telemetry may take 2-5 minutes to appear. Check **Live Metrics** first for real-time data.

---

## 11. Teams Shows No Response from Agent

**Symptom:** Messages sent in Teams never get a reply. No typing indicator appears.

**Diagnosis — work through in order:**

1. **Is the Container App running?**
   ```powershell
   az containerapp show --name agentappk71j-app --resource-group rg-hybrid-agent \
       --query "properties.runningStatus" -o tsv
   ```

2. **Is the messaging endpoint correct?**
   ```powershell
   # Should return a JSON response
   Invoke-RestMethod "https://agentappk71j-app.wonderfulplant-f418865a.eastus2.azurecontainerapps.io/healthz"
   ```

3. **Check container logs for incoming requests:**
   ```powershell
   az containerapp logs show --name agentappk71j-app --resource-group rg-hybrid-agent --tail 100
   ```

4. **Is the A365 manifest published?**
   ```powershell
   cd agent-webapp\manifest
   a365 publish
   ```

5. **Is the app approved in Teams Admin Center?** The admin must approve the custom app upload.

**Common fixes:**
- Re-publish the manifest: `a365 publish` from the manifest directory
- Ensure `messagingEndpoint` in `a365.config.json` matches the Container App's FQDN
- Ensure the Blueprint app's `CLIENTSECRET` hasn't expired
- Check that `needDeployment: false` is set (self-hosted mode)

---

## 12. Weather Function Healthy but Returns Errors

**Symptom:** `/api/healthz` returns 200, but `/api/weather?city=Seattle` returns 500 or empty results.

**Diagnosis:**
```powershell
# Test directly (bypasses EasyAuth if testing from public)
Invoke-RestMethod "https://weatherk71j-func.azurewebsites.net/api/weather?city=Seattle"

# Check function logs
az functionapp log tail --name weatherk71j-func --resource-group rg-hybrid-agent
```

**Checklist:**
1. Function has VNet integration enabled (outbound calls to external weather APIs need internet)
2. `FUNCTIONS_WORKER_RUNTIME` is set to `python`
3. Python version is 3.11 (matching the Flex Consumption runtime)
4. Dependencies in `requirements.txt` are deployed (check via Kudu or SCM)

---

## Quick Reference: Diagnostic Commands

```powershell
# Container App logs
az containerapp logs show --name <app-name> --resource-group rg-hybrid-agent --tail 100

# Function App logs  
az functionapp log tail --name <func-name> --resource-group rg-hybrid-agent

# Check role assignments for an identity
az role assignment list --assignee <principal-id> --all -o table

# Check EasyAuth config
az rest --method get --url "/subscriptions/<sub>/resourceGroups/rg-hybrid-agent/providers/Microsoft.Web/sites/<func>/config/authsettingsV2?api-version=2022-03-01"

# Test connectivity from Jump VM
ssh azureuser@<jumpbox-ip> "curl -s https://<internal-fqdn>/healthz"

# Check DNS resolution from Jump VM
ssh azureuser@<jumpbox-ip> "nslookup <internal-fqdn>"

# Terraform state check
cd infra-terraform
terraform state list | Select-String "<resource-keyword>"
```

---

**Related Documentation:**
- [Setup Guide](SETUP-GUIDE.md) — Full deployment walkthrough
- [SKILL.md](SKILL.md) — Technical reference with 24 lessons learned
- [Architecture Diagrams](diagrams/architecture-diagrams.md) — Network and data flow diagrams
