# Hybrid Network AI Agent — Guided Setup

A step-by-step walkthrough for setting up and deploying the Hybrid Network AI Agent from scratch. This guide references the detailed [SKILL.md](SKILL.md) for deep-dive explanations and the automation scripts for hands-off deployment.

> **Time estimate**: 60-90 minutes for first-time setup (infrastructure provisioning takes ~15-20 minutes).

---

## How This Guide is Organized

| Document | Purpose |
|----------|---------|
| **This file (SETUP-GUIDE.md)** | Guided walkthrough — follow this end-to-end |
| [SKILL.md](SKILL.md) | Complete technical reference — architecture, module details, design decisions, troubleshooting |
| [deploy-all.ps1](deploy-all.ps1) | Automated 10-step deployment — runs everything after prerequisites are met |
| [deploy-terraform.ps1](deploy-terraform.ps1) | Infrastructure-only deployment — Terraform + app code publish (7 steps) |
| [scripts/create_or_update_agent.ps1](scripts/create_or_update_agent.ps1) | Foundry agent bootstrap — creates/updates the AI agent via REST API |
| [docs/azure-devops-deployment.md](docs/azure-devops-deployment.md) | CI/CD guide for deploying the Function App via Azure DevOps |

### Two Paths

- **Guided (this doc)**: Walk through each phase with portal screenshots context and manual checkpoints
- **Automated**: Complete prerequisites, then run `.\deploy-all.ps1` (see [Quick Start with Automation](#quick-start-with-automation))

---

## Phase 1: Prerequisites

### 1.1 Install Required Tools

Open a PowerShell terminal and verify each tool:

```powershell
# Core tools
az --version            # Azure CLI — need latest
terraform --version     # Terraform — need >= 1.5.0
func --version          # Azure Functions Core Tools — need v4
docker --version        # Docker Desktop — for local container builds
python --version        # Python — need 3.11+
ssh -V                  # SSH client

# For M365 / Teams agent deployment (Phase 7)
dotnet --version        # .NET SDK — need 8.0+
a365 --version          # A365 CLI — installed via dotnet tool
```

| Tool | Version | Purpose | Required For |
|------|---------|---------|-------------|
| **Azure CLI** | Latest | Authentication, Function/ACR deployment | All phases |
| **Terraform** | >= 1.5.0 | Infrastructure provisioning | Phase 3-4 |
| **Azure Functions Core Tools** | v4 | Function App publish | Phase 4 |
| **Docker Desktop** | Latest | Local container builds (MCP + Agent Webapp) | Phase 4, 7 |
| **Python** | 3.11+ | Application development, unit tests | All phases |
| **SSH client** | Any | Jump VM access | Phase 4-5 |
| **.NET SDK** | 8.0+ | A365 CLI prerequisite | Phase 7 |
| **A365 CLI** | Latest (prerelease) | Teams/M365 agent registration & publishing | Phase 7 |
| **Git** | Latest | Version control, push to remote | All phases |

**Install links** (if missing):
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-windows)
- [Terraform](https://developer.hashicorp.com/terraform/install)
- [Azure Functions Core Tools](https://learn.microsoft.com/en-us/azure/azure-functions/functions-run-local#install-the-azure-functions-core-tools)
- [Docker Desktop](https://docs.docker.com/desktop/install/windows-install/)
- [Python 3.11](https://www.python.org/downloads/)
- [.NET SDK 8.0](https://dotnet.microsoft.com/download/dotnet/8.0)
- [A365 CLI](https://www.nuget.org/packages/Microsoft.Agents.A365.DevTools.Cli) — install via `dotnet tool install --global Microsoft.Agents.A365.DevTools.Cli --prerelease`

### 1.1b Azure Subscription & Permissions Requirements

| Requirement | Details |
|-------------|--------|
| Azure subscription | With **Contributor** + **User Access Administrator** roles |
| Microsoft 365 tenant | Same tenant as Azure — needed for Teams agent |
| Teams admin access | To approve custom app sideloading or org-wide publishing |
| Sufficient quota | Standard_B1s VM, Flex Consumption FC1, 2× Container App Environments, AI Services S0 |
| Region | **eastus2** recommended (supports AI Foundry agent networking) |

### 1.2 Azure Login

```powershell
az login --use-device-code
az account set --subscription "<your-subscription-id>"
az account show --query "{subscription:name, id:id, tenant:tenantId}" -o table
```

Confirm the output shows your expected subscription and tenant.

### 1.3 Generate SSH Key (if you don't have one)

```powershell
# Check if key exists
Test-Path "$HOME\.ssh\id_rsa.pub"

# Generate if needed
ssh-keygen -t rsa -b 4096 -f "$HOME\.ssh\id_rsa" -N '""'
```

### 1.4 Create a Service Principal

The service principal (SP) is used for Terraform authentication, EasyAuth on the Function App, and agent creation. You have two options:

#### Option A: Via Azure Portal (Recommended)

> **Reference**: [SKILL.md — Create Service Principal → Option A](SKILL.md#create-service-principal)

1. Navigate to **Microsoft Entra ID** → **App registrations** → **New registration**
2. Name: `idp4functionapp`
3. Supported account types: **Accounts in this organizational directory only**
4. Click **Register**

**Record these values from the Overview page:**

| Value | Where to find it | Example |
|-------|-------------------|---------|
| Application (client) ID | Overview → Essentials | `dfe36927-3171-4c66-8370-26840f0ab080` |
| Directory (tenant) ID | Overview → Essentials | `5d0245d3-4d99-44f5-82d3-28c83aeda726` |
| Object ID | Overview → Essentials | `cae9f66d-e8ed-4ce0-9999-d0a7cab13d8a` |

5. Go to **Certificates & secrets** → **New client secret**
   - Description: `hybrid-network-deploy`
   - Expiry: 6 months (or as needed)
   - **Copy the secret Value immediately** — you won't see it again

6. Go to **Expose an API**:
   - Click **Set** next to Application ID URI → Accept the default (`api://<client-id>`)
   - Click **Add a scope** → Scope name: `Files.Read`, Who can consent: `Admins and users`, State: `Enabled`

7. Assign **Contributor** role on your subscription:
   - Go to **Subscriptions** → your subscription → **Access control (IAM)** → **Add role assignment**
   - Role: `Contributor`
   - Members: search for `idp4functionapp`

#### Option B: Via Azure CLI

```powershell
$sp = az ad sp create-for-rbac --name "idp4functionapp" --role Contributor `
    --scopes "/subscriptions/<YOUR_SUBSCRIPTION_ID>" `
    --query "{clientId: appId, secret: password, tenant: tenant}" -o json | ConvertFrom-Json

# Record these:
Write-Host "Client ID:     $($sp.clientId)"
Write-Host "Client Secret: $($sp.secret)"
Write-Host "Tenant ID:     $($sp.tenant)"

# Get SP Object ID
$spObjectId = az ad sp show --id $sp.clientId --query id -o tsv
Write-Host "SP Object ID:  $spObjectId"
```

### 1.5 Clone / Create the Project

```powershell
# If starting from a cloned repo:
cd C:\FY26\AIGuild\projects\hybrid-network

# Create Python virtual environment
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

### 1.6 Create a Blueprint App Registration (for Microsoft Agents SDK)

The Agent Webapp uses the Microsoft Agents SDK which requires its own Entra app registration (separate from the Function App SP).

1. Go to **Microsoft Entra ID** → **App registrations** → **New registration**
2. Name: `hybrid-agent-blueprint` (or similar)
3. Supported account types: **Accounts in any organizational directory and personal Microsoft accounts**
4. Click **Register**
5. Record the **Application (client) ID** — this is `sdk_client_id`
6. Go to **Certificates & secrets** → **New client secret** → copy the value — this is `sdk_client_secret`

> **Note**: This app is used for Bot Framework channel auth. The `idp4functionapp` SP is for Terraform + EasyAuth.

### 1.7 Install A365 CLI

```powershell
dotnet tool install --global Microsoft.Agents.A365.DevTools.Cli --prerelease
a365 --version
```

**Checkpoint**: All tools installed, Azure CLI authenticated, SSH key exists, both SPs created with values recorded.

---

## Phase 2: Configure Environment Files

### 2.1 Create .env

Create `.env` at the project root. Replace `<placeholders>` with your values:

```env
# Azure Configuration
AZURE_SUBSCRIPTION_ID=<your-subscription-id>
AZURE_TENANT_ID=<your-tenant-id>

# Service Principal (for deploy-all.ps1 and agent scripts)
AZURE_CLIENT_ID=<your-sp-client-id>
AZURE_CLIENT_SECRET=<your-sp-client-secret>

# Resource Group
RESOURCE_GROUP=rg-hybrid-agent
LOCATION=eastus2

# VNet Configuration
VNET_NAME=agent-vnet
AGENT_SUBNET_NAME=agent-subnet
PE_SUBNET_NAME=pe-subnet
MCP_SUBNET_NAME=mcp-subnet
FUNC_INTEGRATION_SUBNET_NAME=func-integration-subnet

# AI Services
AI_SERVICES_NAME=aiservices
MODEL_NAME=gpt-4o-mini
MODEL_FORMAT=OpenAI
MODEL_VERSION=2024-07-18
MODEL_SKU=GlobalStandard
MODEL_CAPACITY=30

# Function App
FUNCTION_APP_NAME=weather-func
```

### 2.2 Create terraform.tfvars

Create `infra-terraform/terraform.tfvars`:

```hcl
subscription_id = "<your-subscription-id>"
tenant_id       = "<your-tenant-id>"
client_id       = "<your-sp-client-id>"
# client_secret passed via TF_VAR_client_secret environment variable

resource_group_name = "rg-hybrid-agent"
location            = "eastus2"

# AI Services
ai_services_name = "aiservices"
model_name       = "gpt-4o-mini"
model_format     = "OpenAI"
model_version    = "2024-07-18"
model_sku_name   = "GlobalStandard"
model_capacity   = 30

# Networking
vnet_name                    = "agent-vnet"
agent_subnet_name            = "agent-subnet"
pe_subnet_name               = "pe-subnet"
mcp_subnet_name              = "mcp-subnet"
func_integration_subnet_name = "func-integration-subnet"
```

Set secrets as environment variables (not in the file):

```powershell
$env:TF_VAR_client_secret     = "<your-sp-client-secret>"      # idp4functionapp secret
$env:TF_VAR_sdk_client_secret = "<your-blueprint-app-secret>"  # Blueprint app secret
```

> **Important**: Also add these to your `terraform.tfvars` (non-secret values only):
> ```hcl
> sdk_client_id          = "<your-blueprint-app-client-id>"
> foundry_agent_id       = ""   # Set after Step 4.6
> agent_webapp_mi_app_id = ""   # Set after Phase 7 first deploy
> ```

**Checkpoint**: `.env` and `terraform.tfvars` configured with your values. Secrets are in env vars, not committed to files.

---

## Phase 3: Choose Your Deployment Path

### Path A: Fully Automated (Recommended)

The `deploy-all.ps1` script runs all 10 steps automatically:

```powershell
cd C:\FY26\AIGuild\projects\hybrid-network

# Dry run first — see what it will do without making changes
.\deploy-all.ps1 -DryRun

# Full deployment
.\deploy-all.ps1
```

**What deploy-all.ps1 does** (10 steps):

| Step | What | Automated? |
|------|------|------------|
| 1 | Validate prerequisites (tools, Azure login, SSH key) | Yes |
| 2 | Terraform init, plan, apply (~45 resources) | Yes |
| 3 | Deploy Weather Function code (`func publish`) | Yes |
| 4 | Build & push MCP Docker image to ACR, update Container App | Yes |
| 5 | Configure EasyAuth on Weather Function | Yes |
| 6 | Configure managed identity RBAC (Foundry project MI → Function App, Function App MI → Storage) | Yes |
| 7 | Create Foundry agent via REST API | Yes |
| 8 | Set up Jump VM (install deps, upload client, create .env) | Yes |
| 9 | Run verification tests (Weather Function, MCP Server, agent) | Yes |
| 10 | Print deployment summary | Yes |

**Script parameters for partial runs:**

```powershell
# Infrastructure already deployed — skip Terraform
.\deploy-all.ps1 -SkipInfra

# Agent already exists — pass the ID
.\deploy-all.ps1 -SkipInfra -AgentId "asst_fAVIpp16oVnfHaBuCo1BtvJ9"

# Skip Jump VM setup
.\deploy-all.ps1 -SkipJumpVM

# Combine flags
.\deploy-all.ps1 -SkipInfra -SkipAgent -SkipJumpVM  # Only runs verification
```

**Skip to** [Phase 5: Verify & Test](#phase-5-verify--test) after the script completes.

---

### Path B: Step-by-Step Manual

Follow each phase below in order.

---

## Phase 4: Manual Deployment Steps

### 4.1 Deploy Infrastructure with Terraform

> **Reference**: [SKILL.md — Step 6: Deploy Infrastructure](SKILL.md#step-6-deploy-infrastructure)

```powershell
cd infra-terraform

# Set the client secret
$env:TF_VAR_client_secret = "<your-sp-client-secret>"

# Initialize
terraform init -upgrade

# Plan — review the output carefully
terraform plan -out=tfplan

# Apply (~15-20 minutes for first deploy)
terraform apply tfplan
```

After apply completes, capture the outputs:

```powershell
# Save key outputs to variables
$funcName  = terraform output -raw weather_function_name
$funcHost  = terraform output -raw weather_function_hostname
$acrName   = terraform output -raw datetime_mcp_acr_name
$mcpApp    = terraform output -raw datetime_mcp_app_name
$mcpFqdn   = terraform output -raw datetime_mcp_fqdn
$aiAccount = terraform output -raw ai_account_name
$project   = terraform output -raw project_name
$jumpIp    = terraform output -raw jumpbox_public_ip

# Print them for reference
Write-Host "Function App:  $funcName ($funcHost)"
Write-Host "ACR:           $acrName"
Write-Host "MCP App:       $mcpApp ($mcpFqdn)"
Write-Host "AI Account:    $aiAccount"
Write-Host "Project:       $project"
Write-Host "Jump VM IP:    $jumpIp"
```

### 4.2 Deploy Weather Function Code

> **Reference**: [SKILL.md — Step 3: Build the Weather Function](SKILL.md#step-3-build-the-weather-function-azure-function)

```powershell
cd ../azure-function-server
func azure functionapp publish $funcName --python
```

Quick verification:

```powershell
# Health check (no auth needed for healthz)
Invoke-RestMethod "https://$funcHost/api/healthz"
```

### 4.3 Build and Deploy MCP Server

> **Reference**: [SKILL.md — Step 4: Build the MCP Server](SKILL.md#step-4-build-the-mcp-server-datetime-tools)

```powershell
cd ../mcp-server

# Build and push in one step using ACR Build
az acr build --registry $acrName --image datetime-mcp:latest .

# Update Container App to use the real image (replaces the placeholder)
az containerapp update --name $mcpApp `
    --resource-group rg-hybrid-agent `
    --image "$acrName.azurecr.io/datetime-mcp:latest"
```

### 4.4 Configure Managed Identities and RBAC

> **Reference**: [SKILL.md — Step 7: Configure Managed Identities and RBAC](SKILL.md#step-7-configure-managed-identities-and-rbac)

#### 4.4a Foundry Project MI → Function App (Website Contributor)

**Via Azure Portal:**
1. Go to **Resource Group** → `rg-hybrid-agent`
2. Find the AI Foundry project resource → note its **Managed identity** Principal ID in the Essentials panel
3. Go to the **Weather Function App** → **Access control (IAM)**
4. **Add role assignment** → Role: `Website Contributor` → Members: Select **Managed identity** → pick the AI Foundry project
5. **Review + assign**

**Via CLI:**

```powershell
$projectResId = az resource list -g rg-hybrid-agent `
    --resource-type "Microsoft.CognitiveServices/accounts/projects" `
    --query "[0].id" -o tsv
$projectPrincipalId = az resource show --ids $projectResId --query "identity.principalId" -o tsv
$funcAppId = az functionapp show --name $funcName -g rg-hybrid-agent --query id -o tsv

az role assignment create --assignee-object-id $projectPrincipalId `
    --assignee-principal-type ServicePrincipal `
    --role "Website Contributor" `
    --scope $funcAppId
```

#### 4.4b Function App MI → Storage (Storage Blob Data Contributor)

**Via Azure Portal:**
1. Go to **Weather Function App** → **Identity** → **System assigned** tab
2. Confirm Status is **On**, note the Object (principal) ID
3. Go to the **dependent storage account** (not the function's runtime storage) → **Access control (IAM)**
4. **Add role assignment** → Role: `Storage Blob Data Contributor` → Members: Select **Managed identity** → pick the Function App
5. **Review + assign**

**Via CLI:**

```powershell
$funcPrincipalId = az functionapp identity show --name $funcName -g rg-hybrid-agent --query principalId -o tsv

# Find the dependent storage (exclude function runtime storage and tool queue storage)
$storageId = az storage account list -g rg-hybrid-agent `
    --query "[?!contains(name, 'weather') && !contains(name, 'toolq')].id" -o tsv

az role assignment create --assignee-object-id $funcPrincipalId `
    --assignee-principal-type ServicePrincipal `
    --role "Storage Blob Data Contributor" `
    --scope $storageId
```

### 4.5 Configure EasyAuth on Weather Function

> **Reference**: [SKILL.md — Step 8: Configure EasyAuth](SKILL.md#step-8-configure-easyauth-on-weather-function)

**Via Azure Portal:**
1. Go to `weatherk71j-func` → **Authentication**
2. Click **Add identity provider** → **Microsoft**
3. Select **Pick an existing app registration** → choose `idp4functionapp`
4. **Restrict access**: `Require authentication`
5. **Unauthenticated requests**: `Return HTTP 401`
6. **Token store**: Enabled
7. Click **Add**

**Via CLI:**

```powershell
$clientId = "<your-sp-client-id>"
$tenantId = "<your-tenant-id>"

az webapp auth microsoft update --name $funcName `
    --resource-group rg-hybrid-agent `
    --client-id $clientId `
    --issuer "https://sts.windows.net/$tenantId/" `
    --yes

az webapp auth update --name $funcName `
    --resource-group rg-hybrid-agent `
    --enabled true `
    --action Return401
```

**Verify EasyAuth:**

```powershell
# Should return 401 (no token)
try { Invoke-RestMethod "https://$funcHost/api/weather?city=Seattle" } catch { $_.Exception.Response.StatusCode }

# Should succeed with token
$token = az account get-access-token --resource $clientId --query accessToken -o tsv
Invoke-RestMethod "https://$funcHost/api/weather?city=Seattle" `
    -Headers @{ Authorization = "Bearer $token" }
```

### 4.6 Create the Foundry Agent

> **Reference**: [SKILL.md — Step 9: Create the Foundry Agent](SKILL.md#step-9-create-the-foundry-agent)

```powershell
cd ..

$spObjectId = az ad sp show --id $clientId --query id -o tsv

.\scripts\create_or_update_agent.ps1 `
    -ClientId $clientId `
    -ClientSecret "<your-sp-client-secret>" `
    -TenantId $tenantId `
    -AccountEndpoint "https://$aiAccount.cognitiveservices.azure.com/" `
    -ProjectName $project `
    -ModelDeploymentName "gpt-4.1-mini" `
    -AgentName "pce" `
    -SubscriptionId "<your-subscription-id>" `
    -AccountName $aiAccount `
    -SpObjectId $spObjectId `
    -ResourceGroupName "rg-hybrid-agent"
```

**Record the Agent ID** from the output — format: `asst_xxxxx`

### 4.7 Set Up the Jump VM

> **Reference**: [SKILL.md — Step 10: Set Up the Jump VM](SKILL.md#step-10-set-up-the-jump-vm)

```powershell
# SSH in
ssh azureuser@$jumpIp
```

> **If SSH times out**: Both the NIC-level NSG and subnet-level NSG must have AllowSSH rules. See [SKILL.md — Troubleshooting: SSH Connection Timeout](SKILL.md#ssh-connection-timeout-to-jump-vm).

Once connected to the VM:

```bash
# Install dependencies
sudo apt update && sudo apt install -y python3-pip python3-venv curl jq
mkdir -p ~/agent && cd ~/agent
python3 -m venv .venv
source .venv/bin/activate
pip install azure-identity python-dotenv requests
```

From your local machine (in another terminal), upload the agent client:

```powershell
scp ai-agent/foundry_agent.py azureuser@${jumpIp}:~/agent/
```

Create `.env` on the Jump VM:

```bash
cat > ~/agent/.env << 'EOF'
FOUNDRY_ENDPOINT=https://<ai-account>.services.ai.azure.com/api/projects/<project-name>
AGENT_ID=<your-agent-id>
AGENT_API_VERSION=v1
WEATHER_BASE_URL=https://<function-hostname>
WEATHER_AUTH_CLIENT_ID=<your-sp-client-id>
MCP_BASE_URL=https://<mcp-fqdn>
AZURE_CLIENT_ID=<your-sp-client-id>
AZURE_CLIENT_SECRET=<your-sp-client-secret>
AZURE_TENANT_ID=<your-tenant-id>
EOF
```

> **Important**: MCP_BASE_URL must use `https://` — the Container App redirects HTTP to HTTPS (301).

---

## Phase 5: Verify & Test

### 5.1 Run Unit Tests (Local)

```powershell
# From project root with .venv activated
cd C:\FY26\AIGuild\projects\hybrid-network
.\.venv\Scripts\Activate.ps1

python -m pytest azure-function-server/test_function_app.py -v   # 13 tests
python -m pytest mcp-server/test_server.py -v                     # 19 tests
python -m pytest ai-agent/test_agent.py -v                        # 16 tests
# Total: 48 unit tests — ALL should pass
```

### 5.2 Verify Weather Function

```powershell
# Get EasyAuth token
$token = az account get-access-token --resource <your-sp-client-id> --query accessToken -o tsv

# Health check
Invoke-RestMethod "https://<func-hostname>/api/healthz" -Headers @{ Authorization = "Bearer $token" }

# Weather query
Invoke-RestMethod "https://<func-hostname>/api/weather?city=Seattle" -Headers @{ Authorization = "Bearer $token" }

# Forecast
Invoke-RestMethod "https://<func-hostname>/api/weather/forecast?city=Tokyo&days=3" -Headers @{ Authorization = "Bearer $token" }
```

### 5.3 Verify MCP Server (From Jump VM)

The MCP server is VNet-internal only — test from the Jump VM:

```bash
ssh azureuser@<jump-vm-ip>

# Health check
curl -s https://<mcp-fqdn>/healthz

# List tools
curl -s -X POST https://<mcp-fqdn>/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
```

### 5.4 Run the Agent End-to-End

From the Jump VM:

```bash
cd ~/agent
source .venv/bin/activate

# Single query mode
python foundry_agent.py "What's the weather in Seattle?"

# Interactive mode
python foundry_agent.py
```

### 5.5 Sample Queries to Test All 6 Tools

| Query | Expected Tool(s) |
|-------|-------------------|
| `What's the weather in Seattle?` | get_weather |
| `Give me a 5-day forecast for Tokyo` | get_weather_forecast |
| `What time is it in PST?` | get_current_time |
| `What day of the week is 2025-12-25?` | get_date_info |
| `Convert 3pm EST to JST` | convert_timezone |
| `How many days between 2025-01-01 and 2025-12-31?` | time_difference |
| `What's the weather in London and what time is it there?` | get_weather + get_current_time |

---

## Phase 6: View Resources in Azure Portal

### Find the Agent

The agent is a data-plane object — it's **not** visible as an ARM resource:

1. Go to [ai.azure.com](https://ai.azure.com)
2. Select your project (e.g. `projectk71j`)
3. Click **Agents** in the left nav
4. You'll see **pce** with its model (gpt-4.1-mini) and 6 tools

> **Note**: The agent playground won't work because tools are `function` type (client-executed). Use the `foundry_agent.py` client on the Jump VM.

### View Infrastructure

In the Azure Portal → **Resource Group** → `rg-hybrid-agent`, you'll see ~45 resources including:

| Resource | Type |
|----------|------|
| `aiservicesXXXX` | AI Services account |
| `projectXXXX` | AI Foundry project |
| `weatherXXXX-func` | Function App (Flex Consumption) |
| `dtmcpXXXX-app` | Container App (MCP server) |
| `jumpbox-vm` | Virtual Machine |
| `agent-vnet` | Virtual Network (5 subnets) |
| Various `*-pe` | Private Endpoints |
| Various `privatelink.*` | Private DNS Zones |

---

## Phase 6b: Deploy Agent Webapp to Teams (M365 via A365)

This phase deploys the Agent Webapp as a Teams-accessible bot using the Microsoft Agents SDK and A365 tooling.

### 6b.1 Build and Push Agent Webapp Container

```powershell
$ACR = terraform -chdir=infra-terraform output -raw datetime_mcp_acr_name

# Login to ACR
az acr login --name $ACR

# Build locally (preferred over az acr build to avoid encoding issues on Windows)
cd agent-webapp
docker build -t "$ACR.azurecr.io/agent-webapp:latest" .
docker push "$ACR.azurecr.io/agent-webapp:latest"
cd ..
```

### 6b.2 Register the Agent with A365

```powershell
# Login to A365 CLI
a365 auth login --tenant-id <your-tenant-id>

# Setup permissions and bot registration
cd agent-webapp/manifest
a365 setup all --skip-infrastructure --config a365.config.json --verbose
```

The `a365.config.json` should contain:

```json
{
  "name": "PCE Agent",
  "description": "Hybrid Network AI Agent with Weather and DateTime tools",
  "needDeployment": false,
  "messagingEndpoint": "https://<agent-webapp-fqdn>/api/messages",
  "appRegistration": {
    "clientId": "<blueprint-app-client-id>"
  }
}
```

### 6b.3 Publish to Teams

```powershell
a365 publish
```

This uploads the Teams app manifest and makes the agent available in your organization's Teams app catalog.

### 6b.4 Configure RBAC for Agent Webapp Managed Identity

After deploying the Container App, the system-assigned managed identity needs these roles (defined in `main.tf`):

| Role | Scope | Purpose |
|------|-------|---------|
| Cognitive Services OpenAI User | AI Services account | OpenAI model access |
| Azure AI Developer | AI Services account | Foundry development actions |
| Cognitive Services User | AI Services account | Wildcard CognitiveServices access |
| Cognitive Services User | Foundry project | Agents API data-plane access |
| Azure AI Developer | Foundry project | Agents API project operations |

These are provisioned by Terraform. Additionally, update EasyAuth `allowedApplications` on the Weather Function to include the MI's appId:

```powershell
# Get MI appId
$principalId = az containerapp show --name <agent-app-name> `
    --resource-group rg-hybrid-agent --query "identity.principalId" -o tsv
$miAppId = az ad sp show --id $principalId --query appId -o tsv

# Add to EasyAuth via Terraform (azapi_resource in main.tf) or manually
```

> **Key insight**: Use the MI's **Application (client) ID** — not its principal/object ID — in `allowedApplications`.

### 6b.5 Test in Teams

1. Open **Microsoft Teams** → search for **PCE Agent** in the app catalog
2. Start a personal chat with the agent
3. Send: `hey there` → should get a greeting response
4. Send: `what is the pacific time now and weather in Seattle, WA?`
5. Expected: Combined response with current Pacific time and Seattle weather data

---

## Phase 6c: Verify App Insights Telemetry

All three services (Agent Webapp, Weather Function, MCP Server) are instrumented with Azure Monitor OpenTelemetry.

### View Telemetry

1. Go to **Azure Portal** → **Application Insights** (`hybrid-agent-<suffix>-appinsights`)
2. **Overview**: Check failed requests (should be 0), server response time, and server request count
3. **Live Metrics**: See real-time requests as you interact with the agent in Teams
4. **Metrics** → select `agents.adapter.process.duration` to see agent processing times
5. **Transaction Search**: View end-to-end distributed traces across all services

### Expected Metrics After Testing

| Metric | Healthy Range |
|--------|---------------|
| Failed requests | 0 |
| Server response time (avg) | 1-3 seconds |
| Server requests | Increases with each Teams message |
| `agents.adapter.process.duration` | 3-20k ms (includes Foundry + tool calls) |

---

## Quick Start with Automation

For returning users or those comfortable with the prerequisites:

```powershell
# 1. Clone/navigate to project
cd C:\FY26\AIGuild\projects\hybrid-network

# 2. Set up Python environment
python -m venv .venv; .\.venv\Scripts\Activate.ps1; pip install -r requirements.txt

# 3. Configure environment files (see Phase 2)
# Edit .env and infra-terraform/terraform.tfvars with your values

# 4. Set Terraform secret
$env:TF_VAR_client_secret = "<your-sp-client-secret>"

# 5. Run everything
.\deploy-all.ps1

# 6. Use the agent
$jumpIp = terraform -chdir=infra-terraform output -raw jumpbox_public_ip
ssh azureuser@$jumpIp
# Then: cd ~/agent && source .venv/bin/activate && python foundry_agent.py
```

---

## Script Reference

### deploy-all.ps1

Full 10-step automated deployment. Run from project root.

```
Usage:  .\deploy-all.ps1 [flags]

Flags:
  -DryRun       Show what would happen, don't change anything
  -SkipInfra    Skip Terraform (infrastructure already deployed)
  -SkipAgent    Skip Foundry agent creation
  -SkipJumpVM   Skip Jump VM setup
  -AgentId      Use an existing agent ID instead of creating one

Examples:
  .\deploy-all.ps1                                  # Full deploy
  .\deploy-all.ps1 -DryRun                          # Preview only
  .\deploy-all.ps1 -SkipInfra                       # App deploy only
  .\deploy-all.ps1 -SkipInfra -AgentId "asst_xxx"   # Re-configure Jump VM
```

### deploy-terraform.ps1

Infrastructure-only deployment (7 steps). Handles Terraform init/plan/apply, then publishes the Function App and MCP container.

```
Usage:  .\deploy-terraform.ps1
```

### scripts/create_or_update_agent.ps1

Idempotent Foundry agent bootstrap. Authenticates the SP, ensures RBAC, creates/updates the agent with 6 function tools.

```
Usage:  .\scripts\create_or_update_agent.ps1 `
          -ClientId <sp-client-id> `
          -ClientSecret <sp-secret> `
          -TenantId <tenant-id> `
          -AccountEndpoint <https://account.cognitiveservices.azure.com/> `
          -ProjectName <project-name> `
          -ModelDeploymentName "gpt-4.1-mini" `
          -AgentName "pce"
```

---

## Troubleshooting Quick Reference

| Problem | Solution | Details |
|---------|----------|---------|
| SSH timeout to Jump VM | Add AllowSSH rules to **both** NIC-level and subnet-level NSGs | [SKILL.md → Troubleshooting](SKILL.md#ssh-connection-timeout-to-jump-vm) |
| MCP server connection refused | Use `https://` not `http://` (CAE redirects 301) | [SKILL.md → Troubleshooting](SKILL.md#mcp-server-returns-connection-refused) |
| Weather Function returns 401 | Get bearer token: `az account get-access-token --resource <sp-client-id>` | [SKILL.md → Troubleshooting](SKILL.md#weather-function-returns-401) |
| Agent playground doesn't work | Expected — tools are `function` type (client-executed). Use `foundry_agent.py` | [SKILL.md → Troubleshooting](SKILL.md#agent-playground-doesnt-work) |
| Terraform CAE drift | Use `terraform apply -target=module.foundry_agent` | [SKILL.md → Troubleshooting](SKILL.md#terraform-cae-drift) |
| Private DNS not resolving | Verify DNS zones have `*` and `@` A records pointing to CAE static IP | [SKILL.md → Troubleshooting](SKILL.md#private-dns-resolution-issues) |

---

## Cleanup

```powershell
cd infra-terraform
terraform destroy

# Delete the Entra ID app registration
az ad app delete --id <your-sp-client-id>
```

---

## Further Reading

- [SKILL.md](SKILL.md) — Full architecture details, module-by-module Terraform breakdown, all code explanations, lessons learned
- [docs/azure-devops-deployment.md](docs/azure-devops-deployment.md) — CI/CD pipeline for the Function App via Azure DevOps
- [diagrams/architecture-diagrams.md](diagrams/architecture-diagrams.md) — Mermaid architecture diagrams
