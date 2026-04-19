# Hybrid Network AI Agent — Complete Build Guide

Build and deploy an AI agent that uses Azure Function and MCP Server tools running inside a VNet, orchestrated by Azure AI Foundry. The agent client runs on a jump VM inside the VNet, calling tools over private networking.

---

## Architecture Overview

```
User → Jump VM (VNet) → Foundry Agent (cloud, Assistants API)
                              ↓ requires_action
       Jump VM executes tool calls:
         ├── Weather Function (Azure Function + EasyAuth + Private Endpoint)
         └── DateTime MCP Server (Container App, VNet-internal only)
                              ↓
       Jump VM → submits tool outputs → Agent responds

User → M365 (Teams/Outlook) → Agent Webapp (Container App, external)
                                     ↓ POST /api/messages
                              Foundry Agent (Assistants API)
                                     ↓ requires_action
                              Agent Webapp calls tools:
                                ├── Weather Function (via VNet)
                                └── MCP Server (via VNet, internal CAE DNS)
                                     ↓
                              Agent Webapp → Bot Connector → M365 reply
```

**Two access patterns**:
1. **Jump VM** (original): Direct CLI interaction via `foundry_agent.py`
2. **M365 via A365** (new): Bot Framework Activities → Agent Webapp Container App → Foundry Agent → Tool calls → Response via Bot Connector

### Network Topology

| Subnet | CIDR | Purpose | Delegation |
|--------|------|---------|------------|
| agent-subnet | 10.0.0.0/24 | AI Foundry Data Proxy | Microsoft.App/environments |
| pe-subnet | 10.0.1.0/24 | Private Endpoints | None |
| mcp-subnet | 10.0.2.0/24 | MCP Container App Environment | Microsoft.App/environments |
| func-integration-subnet | 10.0.3.0/24 | Function App VNet Integration | Microsoft.Web/serverFarms |
| jumpbox-subnet | 10.0.4.0/24 | Jump VM for testing | None |
| agent-app-subnet | 10.0.6.0/23 | Agent Webapp Container App (external) | Microsoft.App/environments |

### Resources Created (~55+)

- VNet with 6 subnets
- AI Services account (S0, disableLocalAuth=true)
- AI Foundry project with 3 connections (AI Search, Cosmos DB, Storage)
- Cosmos DB (private), Storage Account (private), AI Search (free tier, public)
- 9 Private Endpoints with 7 Private DNS Zones
- Azure Function (Flex Consumption, Python 3.11) with EasyAuth + VNet Integration + PE
- Container App Environment (internal) + Container App (MCP server)
- Container App Environment (external) + Container App (Agent Webapp for A365)
- ACR (Basic) for MCP and Agent Webapp Docker images
- Jump VM (Ubuntu 24.04, Standard_B1s) with public IP
- gpt-4.1-mini model deployment
- Tool queue storage account with weather-input/weather-output queues
- Multiple RBAC role assignments

---

## Prerequisites

### Required Tools

| Tool | Version | Purpose |
|------|---------|---------|
| **Terraform** | >= 1.5.0 | Infrastructure provisioning |
| **Azure CLI** | Latest | Authentication, Function/ACR deployment |
| **Azure Functions Core Tools** | v4 | Function app local dev and publish |
| **Docker Desktop** | Latest | MCP server container build (local testing) |
| **Python** | 3.11+ | Application development |
| **SSH Key Pair** | RSA | Jump VM authentication |
| **VS Code** | Latest | Development (optional but recommended) |

### Azure Requirements

- Azure subscription with Contributor + User Access Administrator roles
- Service Principal with Client ID and Secret (for Terraform and EasyAuth)
- Sufficient quota for: Standard_B1s VM, Flex Consumption Function, Container App, AI Services S0
- Region that supports AI Foundry agent networking (eastus2 recommended)

### Generate SSH Key (if needed)

```powershell
ssh-keygen -t rsa -b 4096 -f "$HOME\.ssh\id_rsa" -N '""'
```

### Create Service Principal

#### Option A: Via Azure Portal (Recommended)

1. Go to **Microsoft Entra ID** → **App registrations** → **New registration**
2. Set the name to `idp4functionapp`
3. Set **Supported account types** to `Accounts in this organizational directory only`
4. Click **Register**
5. On the app's **Overview** page, note:
   - **Application (client) ID**: e.g. `dfe36927-3171-4c66-8370-26840f0ab080`
   - **Directory (tenant) ID**: e.g. `5d0245d3-4d99-44f5-82d3-28c83aeda726`
   - **Object ID**: e.g. `cae9f66d-e8ed-4ce0-9999-d0a7cab13d8a`
6. Go to **Certificates & secrets** → **New client secret**
   - Set a description and expiry, click **Add**
   - **Copy the secret Value immediately** (it won't be shown again)
7. Go to **Expose an API** → **Set** the Application ID URI (defaults to `api://<client-id>`)
   - Click **Add a scope** → Name: `Files.Read`, Who can consent: `Admins and users`, State: `Enabled`
8. Assign the SP the **Contributor** role on your subscription:
   - Go to **Subscriptions** → your subscription → **Access control (IAM)** → **Add role assignment**
   - Role: `Contributor`, Members: select `idp4functionapp`

#### Option B: Via Azure CLI

```powershell
# Create SP and capture output
$sp = az ad sp create-for-rbac --name "idp4functionapp" --role Contributor `
    --scopes "/subscriptions/<YOUR_SUBSCRIPTION_ID>" --query "{clientId: appId, secret: password, tenant: tenant}" -o json | ConvertFrom-Json

# Note these values — you'll need them
# Client ID:     $sp.clientId
# Client Secret: $sp.secret
# Tenant ID:     $sp.tenant

# Get the SP Object ID (needed for RBAC)
$spObjectId = az ad sp show --id $sp.clientId --query id -o tsv
```

---

## Step 1: Project Structure Setup

Create the project directory structure:

```
hybrid-network/
├── .env
├── requirements.txt
├── deploy-terraform.ps1
├── ai-agent/
│   ├── foundry_agent.py
│   ├── test_agent.py
│   └── smoke_test.py
├── agent-webapp/
│   ├── app.py                    # FastAPI web service (/api/messages, /healthz)
│   ├── bot.py                    # Foundry Assistants API handler
│   ├── tools.py                  # Weather Function & MCP Server tool calls
│   ├── config.py                 # Environment-based configuration
│   ├── requirements.txt
│   ├── Dockerfile
│   ├── test_app.py               # 14 unit tests
│   └── manifest/
│       ├── manifest.json         # Teams app manifest (devPreview)
│       └── a365.config.json      # A365 self-hosted config
├── azure-function-server/
│   ├── function_app.py
│   ├── host.json
│   ├── local.settings.json
│   ├── requirements.txt
│   ├── test_function_app.py
│   └── weather_openapi.json
├── mcp-server/
│   ├── server.py
│   ├── Dockerfile
│   └── test_server.py
├── scripts/
│   ├── create_or_update_agent.ps1
│   ├── setup-a365-permissions.ps1
│   ├── deploy-agent-webapp.ps1
│   └── add-vnet-integration.ps1
└── infra-terraform/
    ├── main.tf
    ├── variables.tf
    ├── versions.tf
    ├── terraform.tfvars
    ├── outputs.tf
    └── modules/
        ├── network/
        ├── ai-account/
        ├── ai-project/
        ├── dependent-resources/
        ├── private-endpoints/
        ├── weather-function/
        ├── datetime-mcp/
        ├── agent-webapp/
        ├── jump-vm/
        └── foundry-agent/
```

---

## Step 2: Environment Configuration

### .env File

Create `.env` at the project root with your values:

```env
# Azure Configuration
AZURE_SUBSCRIPTION_ID=<your-subscription-id>
AZURE_TENANT_ID=<your-tenant-id>

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

### terraform.tfvars

Create `infra-terraform/terraform.tfvars`:

```hcl
subscription_id = "<your-subscription-id>"
tenant_id       = "<your-tenant-id>"
client_id       = "<your-sp-client-id>"
client_secret   = "<your-sp-client-secret>"
location        = "eastus2"
```

### Python Requirements (root)

```
azure-identity
azure-ai-projects
azure-ai-inference
openai
azure-functions
azure-mgmt-resource
azure-mgmt-cognitiveservices
azure-storage-blob
python-dotenv
requests
```

---

## Step 3: Build the Weather Function (Azure Function)

### azure-function-server/function_app.py

A simulated weather API with 3 HTTP endpoints:
- `GET /api/weather?city=Seattle` — Current weather (temp, conditions, humidity, wind)
- `GET /api/weather/forecast?city=Seattle&days=3` — Multi-day forecast (up to 7 days)
- `GET /api/healthz` — Health check

Key design decisions:
- **Auth level: ANONYMOUS** — EasyAuth (AAD) handles authentication at the platform level
- Deterministic RNG seeded by `city+hour` for consistent responses within the same hour
- 10 hardcoded cities with base temperatures; unknown cities get defaults

### azure-function-server/host.json

```json
{
  "version": "2.0",
  "extensionBundle": {
    "id": "Microsoft.Azure.Functions.ExtensionBundle",
    "version": "[4.*, 5.0.0)"
  }
}
```

### azure-function-server/requirements.txt

```
azure-functions
```

### Local Testing

```powershell
cd azure-function-server
func start
# Test: curl http://localhost:7071/api/weather?city=Seattle
```

---

## Step 4: Build the MCP Server (DateTime Tools)

### mcp-server/server.py

A JSON-RPC MCP server providing 4 date/time tools:
- `get_current_time` — Current time in any timezone (18 supported abbreviations)
- `get_date_info` — Day of week, week number, quarter, leap year, etc.
- `convert_timezone` — Convert datetime between timezones
- `time_difference` — Calculate difference between two datetimes

Key design:
- Plain Python `http.server.HTTPServer` on port 8080 (no framework dependencies)
- MCP endpoint: `POST /mcp` (JSON-RPC 2.0)
- Health check: `GET /healthz`
- Supports `initialize`, `tools/list`, and `tools/call` methods

### mcp-server/Dockerfile

```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY server.py .
EXPOSE 8080
ENV PORT=8080
CMD ["python", "server.py"]
```

### Local Testing

```powershell
cd mcp-server
docker build -t datetime-mcp .
docker run -p 8080:8080 datetime-mcp
# Test: curl -X POST http://localhost:8080/mcp -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
```

---

## Step 5: Write the Terraform Infrastructure

The infrastructure is organized into 9 modules called from a root `main.tf`. The root module:
1. Generates a random 4-character suffix for unique resource names
2. Creates the resource group
3. Calls modules in dependency order

### Provider Configuration (versions.tf)

```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
    azapi   = { source = "azure/azapi", version = "~> 2.0" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

provider "azurerm" {
  features {}
  subscription_id     = var.subscription_id
  tenant_id           = var.tenant_id
  client_id           = var.client_id
  client_secret       = var.client_secret
  storage_use_azuread = true  # REQUIRED — all storage uses AAD, no shared keys
}

provider "azapi" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
  client_id       = var.client_id
  client_secret   = var.client_secret
}
```

> **Critical**: `storage_use_azuread = true` is mandatory because all storage accounts have `shared_access_key_enabled = false`.

> **Critical**: azapi provider v2.x — `.output` is already an object. Do NOT use `jsondecode()`.

### Module Dependency Chain

```
network
  ├── ai_account (needs agent_subnet_id)
  ├── dependencies (standalone)
  │     └── private_endpoints (needs vnet, pe_subnet, ai_account, dependencies)
  │           └── ai_project (needs account, dependencies; depends_on private_endpoints)
  ├── weather_function (needs vnet, subnets, blob_dns_zone from private_endpoints)
  ├── datetime_mcp (needs mcp_subnet, vnet)
  ├── jump_vm (needs jumpbox_subnet)
  └── foundry_agent (needs ai_account, ai_project, weather_function, network, private_endpoints)
```

### Module Details

#### network/
- VNet `10.0.0.0/16` with 5 subnets
- Subnet delegations for Microsoft.App/environments and Microsoft.Web/serverFarms
- pe-subnet has `private_endpoint_network_policies = Disabled`

#### ai-account/
- Uses `azapi_resource` (API version `2025-04-01-preview`)
- Kind: `AIServices`, SKU: `S0`
- `publicNetworkAccess: Enabled` (for portal access)
- `disableLocalAuth: true` (managed identity only, no API keys)
- Network injection: `scenario: "agent"` pointing to `agent_subnet_id`
- Deploys initial model (gpt-4o-mini)

#### ai-project/
- Foundry project as child of AI Services account (via azapi)
- Creates 3 connections (AAD auth): AI Search, Cosmos DB, Storage

#### dependent-resources/
- AI Search: `free` SKU, public (no PE support on free tier), **location: eastus** (different from main region if needed for free tier availability)
- Cosmos DB: `Session` consistency, `public_network_access_enabled: false`
- Storage: Standard LRS, `public_network_access_enabled: false`, `shared_access_key_enabled: false`

#### private-endpoints/
- 3 PEs: AI Services (`account`), Storage (`blob`), Cosmos DB (`Sql`)
- 3 Private DNS Zones with VNet links
- AI Search excluded (free tier doesn't support PEs)

#### weather-function/
- Dedicated storage account for function runtime (public for deployment, private endpoints for blob/queue/file)
- Service Plan: FC1 (Flex Consumption), Linux
- Function App via `azapi_resource`: Python 3.11, Functions v4, blob-based deployment
- VNet Integration to `func-integration-subnet`
- 4 RBAC roles (Storage Blob Data Owner, Queue Data Contributor, Table Data Contributor, File Data SMB Share Contributor) for function MI on its storage
- Function App Private Endpoint with `privatelink.azurewebsites.net` DNS zone
- Creates 2 additional DNS zones: `privatelink.queue.core.windows.net`, `privatelink.file.core.windows.net`

#### datetime-mcp/
- ACR (Basic SKU, admin enabled) for MCP Docker image
- Container App Environment: `internal_load_balancer_enabled: true` on mcp-subnet
- Container App: placeholder helloworld image (updated after build), 0.5 CPU / 1Gi, 1-3 replicas, ingress on port 8080
- Private DNS zone matching CAE's default domain, A records for `*` and `@` pointing to CAE static IP

#### jump-vm/
- Standard_B1s, Ubuntu 24.04 LTS
- SSH key auth only (no password)
- Public IP (Static, Standard) for SSH access
- NSG: Allow SSH (port 22) from any source
- custom_data installs `curl` and `jq`

#### foundry-agent/
- Deploys gpt-4.1-mini model (GlobalStandard, 30 TPM) into existing AI Services account
- Tool queue storage account (private, no shared keys): `weather-input` and `weather-output` queues
- 2 PEs for queue storage (queue + blob subresources), reusing existing DNS zones
- 4 RBAC assignments: AI Account identity, Project identity, and Weather Function identity get `Storage Queue Data Contributor`; AI Account gets `Storage Blob Data Contributor`
- Foundry connection (`toolQueueStorage`) linking project to queue storage

---

## Step 6: Deploy Infrastructure

### Option A: Using deploy-terraform.ps1

The script automates the full pipeline:

```powershell
cd hybrid-network
.\deploy-terraform.ps1
```

What it does:
1. Loads `.env` and verifies Azure CLI subscription/tenant match
2. `terraform init -upgrade` in infra-terraform/
3. `terraform plan -out=tfplan`
4. `terraform apply tfplan`
5. Deploys Weather Function code: `func azure functionapp publish <name> --python`
6. Builds and pushes MCP Docker image: `az acr build --registry <acr> --image datetime-mcp:latest`
7. Prints Terraform outputs

### Option B: Manual Steps

```powershell
# 1. Initialize Terraform
cd infra-terraform
terraform init -upgrade

# 2. Plan
terraform plan -out=tfplan

# 3. Apply
terraform apply tfplan

# 4. Capture outputs
$suffix = terraform output -raw ai_account_name | Select-String -Pattern '\w{4}$' | ForEach-Object { $_.Matches.Value }
$funcName = terraform output -raw weather_function_name
$acrName = terraform output -raw datetime_mcp_acr_name
$mcpApp = terraform output -raw datetime_mcp_app_name

# 5. Deploy Weather Function
cd ../azure-function-server
func azure functionapp publish $funcName --python

# 6. Build & push MCP container
cd ../mcp-server
az acr build --registry $acrName --image datetime-mcp:latest .

# 7. Update Container App to use the real image
az containerapp update --name $mcpApp `
    --resource-group rg-hybrid-agent `
    --image "$acrName.azurecr.io/datetime-mcp:latest"
```

---

## Step 7: Configure Managed Identities and RBAC

After Terraform deploys the infrastructure, several identity assignments need to be configured to allow secure service-to-service communication without secrets.

### 7a. Grant Foundry Project Managed Identity Access to the Function App

The Foundry project has a system-assigned managed identity that needs access to call the Weather Function. This allows the agent's runtime to invoke the function through the VNet.

#### Via Azure Portal

1. Go to **Resource Group** → `rg-hybrid-agent` → **AI Foundry project** resource (`projectk71j`)
2. In the **Overview** → **Essentials**, note the **Managed identity** (Principal ID)
   - e.g. `a3a1d472-d01b-4938-910e-815238469b8c`
3. Go to the **Weather Function App** (`weatherk71j-func`) → **Access control (IAM)**
4. Click **Add** → **Add role assignment**
5. Role: `Website Contributor` (or `Contributor` if broader access is needed)
6. Members: Select **Managed identity** → **AI Foundry project** → select your project
7. Click **Review + assign**

#### Via Azure CLI

```powershell
# Get the Foundry project managed identity principal ID
$projectPrincipalId = az resource show --ids "<project-resource-id>" --query "identity.principalId" -o tsv

# Get the Function App resource ID
$funcAppId = az functionapp show --name <func-app-name> -g rg-hybrid-agent --query id -o tsv

# Assign Website Contributor role
az role assignment create --assignee-object-id $projectPrincipalId `
    --assignee-principal-type ServicePrincipal `
    --role "Website Contributor" `
    --scope $funcAppId
```

### 7b. Grant Function App Managed Identity Access to Storage Account

The Function App has a system-assigned managed identity that needs `Storage Blob Data Contributor` on the dependent storage account (the shared project storage, not the function's own runtime storage — Terraform handles those 4 roles automatically).

#### Via Azure Portal

1. Go to the **Weather Function App** (`weatherk71j-func`) → **Identity** → **System assigned**
2. Verify **Status** is `On` and note the **Object (principal) ID**
3. Go to the **Storage account** (the dependent-resources storage account) → **Access control (IAM)**
4. Click **Add** → **Add role assignment**
5. Role: `Storage Blob Data Contributor`
6. Members: Select **Managed identity** → **Function App** → select `weatherk71j-func`
7. Click **Review + assign**

#### Via Azure CLI

```powershell
# Get Function App managed identity principal ID
$funcPrincipalId = az functionapp identity show --name <func-app-name> -g rg-hybrid-agent --query principalId -o tsv

# Get the target storage account ID
$storageId = az storage account show --name <storage-account-name> -g rg-hybrid-agent --query id -o tsv

# Assign Storage Blob Data Contributor
az role assignment create --assignee-object-id $funcPrincipalId `
    --assignee-principal-type ServicePrincipal `
    --role "Storage Blob Data Contributor" `
    --scope $storageId
```

> **Note**: Terraform already assigns 4 RBAC roles for the Function App MI on its **own** runtime storage account (`Storage Blob Data Owner`, `Storage Queue Data Contributor`, `Storage Table Data Contributor`, `Storage File Data SMB Share Contributor`). The step above covers the **additional** role on the shared project storage account.

---

## Step 8: Configure EasyAuth on Weather Function

EasyAuth protects the Weather Function with AAD authentication. This must be configured after deployment.

### Via Azure Portal

1. Go to the Function App (`weatherk71j-func`) → **Authentication**
2. Click **Add identity provider** → **Microsoft**
3. Under **App registration**:
   - Select **Pick an existing app registration**
   - Choose `idp4functionapp` (the SP created in Prerequisites)
   - This links to Client ID `dfe36927-3171-4c66-8370-26840f0ab080`
4. Under **App Service authentication settings**:
   - **Restrict access**: `Require authentication`
   - **Unauthenticated requests**: `Return HTTP 401`
   - **Token store**: Enabled
5. Click **Add**
6. Verify by checking the breadcrumb in portal shows: `weatherk71j-func | Authentication → idp4functionapp`

### Via Azure CLI

```powershell
az webapp auth microsoft update --name <function-app-name> `
    --resource-group rg-hybrid-agent `
    --client-id <your-sp-client-id> `
    --issuer "https://sts.windows.net/<your-tenant-id>/" `
    --yes

az webapp auth update --name <function-app-name> `
    --resource-group rg-hybrid-agent `
    --enabled true `
    --action Return401
```

### Verify EasyAuth

```powershell
# Should return 401 (no token)
curl https://<function-app-name>.azurewebsites.net/api/weather?city=Seattle

# Get token and call
$token = az account get-access-token --resource <your-sp-client-id> --query accessToken -o tsv
curl -H "Authorization: Bearer $token" "https://<function-app-name>.azurewebsites.net/api/weather?city=Seattle"
```

---

## Step 9: Create the Foundry Agent

The agent is created via REST API (Terraform can't manage Foundry data-plane resources).

### Using the Script

```powershell
.\scripts\create_or_update_agent.ps1 `
    -ClientId "<your-sp-client-id>" `
    -ClientSecret "<your-sp-client-secret>" `
    -TenantId "<your-tenant-id>" `
    -AccountEndpoint "https://<ai-account-name>.cognitiveservices.azure.com/" `
    -ProjectName "<project-name>" `
    -ModelDeploymentName "gpt-4.1-mini" `
    -AgentName "pce" `
    -SubscriptionId "<your-subscription-id>" `
    -AccountName "<ai-account-name>" `
    -SpObjectId "<sp-object-id>" `
    -ResourceGroupName "rg-hybrid-agent"
```

The script:
1. Authenticates the SP and gets an `https://ai.azure.com/.default` token
2. Ensures SP has `Cognitive Services User` role on the AI account
3. Checks for existing agent named "pce"
4. Creates or updates the agent with 6 function tools:
   - `get_weather` — Current weather for a city
   - `get_weather_forecast` — Multi-day forecast
   - `get_current_time` — Current time in any timezone
   - `get_date_info` — Date details (day of week, week number, etc.)
   - `convert_timezone` — Convert between timezones
   - `time_difference` — Calculate time between two dates

**Record the Agent ID** from the output (format: `asst_xxxxx`).

---

## Step 10: Set Up the Jump VM

### SSH into the VM

```powershell
# Get the public IP
$jumpIp = terraform -chdir=infra-terraform output -raw jumpbox_public_ip
ssh azureuser@$jumpIp
```

### Install Dependencies on the VM

```bash
# Update and install Python tools
sudo apt update && sudo apt install -y python3-pip python3-venv curl jq

# Create project directory
mkdir -p ~/agent && cd ~/agent

# Create virtual environment
python3 -m venv .venv
source .venv/bin/activate

# Install Python packages
pip install azure-identity python-dotenv requests
```

### Upload Agent Client

From your local machine:

```powershell
$jumpIp = terraform -chdir=infra-terraform output -raw jumpbox_public_ip

# Upload the agent client and .env
scp ai-agent/foundry_agent.py azureuser@${jumpIp}:~/agent/
scp .env azureuser@${jumpIp}:~/agent/
```

### Create .env on Jump VM

```bash
cat > ~/agent/.env << 'EOF'
FOUNDRY_ENDPOINT=https://<ai-account-name>.services.ai.azure.com/api/projects/<project-name>
AGENT_ID=<your-agent-id>
AGENT_API_VERSION=v1
WEATHER_BASE_URL=https://<function-app-name>.azurewebsites.net
WEATHER_AUTH_CLIENT_ID=<your-sp-client-id>
MCP_BASE_URL=https://<mcp-app-fqdn>

# SP credentials for DefaultAzureCredential
AZURE_CLIENT_ID=<your-sp-client-id>
AZURE_CLIENT_SECRET=<your-sp-client-secret>
AZURE_TENANT_ID=<your-tenant-id>
EOF
```

> **Important**: The MCP URL must use `https://` — the Container App redirects HTTP to HTTPS (301).

---

## Step 11: Test End-to-End

### Unit Tests (Local)

```powershell
# From project root with .venv activated
python -m pytest azure-function-server/test_function_app.py -v   # 13 tests
python -m pytest mcp-server/test_server.py -v                     # 21 tests
python -m pytest ai-agent/test_agent.py -v                        # 19 tests
python -m pytest agent-webapp/test_app.py -v                      # 14 tests
# Total: 67 unit tests
```

### Verify Weather Function (Public Endpoint)

```powershell
# From local machine (with EasyAuth token)
$token = az account get-access-token --resource <sp-client-id> --query accessToken -o tsv
curl -H "Authorization: Bearer $token" "https://<func-name>.azurewebsites.net/api/weather?city=Seattle"
curl -H "Authorization: Bearer $token" "https://<func-name>.azurewebsites.net/api/healthz"
```

### Verify MCP Server (From Jump VM Only)

```bash
# SSH into jump VM first — MCP is VNet-internal only
curl -X POST https://<mcp-app-fqdn>/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'

curl https://<mcp-app-fqdn>/healthz
```

### Run the Agent (From Jump VM)

```bash
cd ~/agent
source .venv/bin/activate

# Single query
python foundry_agent.py "What's the weather like in Tokyo right now?"

# Interactive mode
python foundry_agent.py
```

Expected flow:
1. Client sends message to Foundry Agent
2. Agent decides to call `get_weather` tool
3. Client receives `requires_action` with tool call
4. Client calls Weather Function with EasyAuth bearer token
5. Client submits tool output back to agent
6. Agent generates natural language response

### Sample Queries to Test All Tools

```
What's the weather in Seattle?                    → get_weather
Give me a 5-day forecast for Tokyo                → get_weather_forecast
What time is it in PST?                           → get_current_time
What day of the week is 2025-12-25?               → get_date_info
Convert 3pm EST to JST                            → convert_timezone
How many days between 2025-01-01 and 2025-12-31?  → time_difference
What's the weather in London and what time is it there? → get_weather + get_current_time
```

---

## Troubleshooting

### SSH Connection Timeout to Jump VM

**Cause**: NSG rules missing on BOTH the NIC-level NSG and the subnet-level NSG.

```powershell
# Check both NSGs have AllowSSH rules
az network nsg rule list --nsg-name jumpbox-vm-nsg -g rg-hybrid-agent -o table
az network nsg rule list --nsg-name agent-vnet-jumpbox-subnet-nsg-<region> -g rg-hybrid-agent -o table

# Add if missing
az network nsg rule create --nsg-name <nsg-name> -g rg-hybrid-agent \
    --name AllowSSH --priority 100 --protocol Tcp --destination-port-ranges 22 \
    --access Allow --direction Inbound
```

### MCP Server Returns Connection Refused

- **Wrong protocol**: Must use `https://` not `http://`. The CAE redirects port 80→443 with a 301.
- **Wrong FQDN**: The FQDN format is `<app-name>.<cae-domain>`. Check with:
  ```bash
  az containerapp show -n <app-name> -g rg-hybrid-agent --query properties.configuration.ingress.fqdn -o tsv
  ```
- **DNS not resolving**: Verify Private DNS zone has `*` and `@` A records pointing to CAE static IP.

### Weather Function Returns 401

- EasyAuth is enabled. You need a bearer token with audience = SP client ID.
- Get token: `az account get-access-token --resource <sp-client-id> --query accessToken -o tsv`
- On Jump VM, set `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID` env vars for `DefaultAzureCredential`.

### Agent Playground Doesn't Work

**Expected behavior**. Tools are `function` type (client-executed). The Foundry portal playground cannot execute client-side function calls. It shows `duration:0` and the agent may hallucinate responses. You must use the `foundry_agent.py` client.

To use the playground, you would need `azure_function` tool type, which requires Enterprise Standard tier for the capability host.

### Terraform CAE Drift

Container App Environment may show drift in Terraform state after Container App updates. Use targeted applies to avoid disrupting running services:

```powershell
terraform apply -target=module.foundry_agent
```

### Private DNS Resolution Issues

If VNet resources can't resolve private endpoints:
```bash
# From jump VM, verify DNS resolution
nslookup <ai-account>.cognitiveservices.azure.com
nslookup <storage>.blob.core.windows.net
nslookup <cosmos>.documents.azure.com
# Should resolve to 10.0.1.x (pe-subnet) addresses
```

---

## Step 12: Deploy Agent Webapp (A365 Container App)

The agent webapp is a FastAPI web service that receives Bot Framework Activities on `/api/messages`, processes them through the Foundry Assistants API, and sends replies via the Bot Connector REST API. It runs on an external Container App Environment (internet-accessible) but is VNet-integrated for connectivity to internal backends.

### Deploy Infrastructure

```powershell
# Add to terraform.tfvars:
# foundry_agent_id = "asst_fAVIpp16oVnfHaBuCo1BtvJ9"
# bot_app_id       = ""   # Set after a365 setup
# bot_app_secret   = ""   # Set after a365 setup

cd infra-terraform
terraform plan -target=module.network -target=module.agent_webapp
terraform apply -target=module.network -target=module.agent_webapp
```

### Build and Push Container

```powershell
.\scripts\deploy-agent-webapp.ps1
```

Or manually:

```powershell
$ACR = terraform -chdir=infra-terraform output -raw datetime_mcp_acr_name
az acr login --name $ACR
docker build -t "$ACR.azurecr.io/agent-webapp:latest" agent-webapp/
docker push "$ACR.azurecr.io/agent-webapp:latest"
```

### Verify

```powershell
$FQDN = terraform -chdir=infra-terraform output -raw agent_webapp_fqdn
curl "https://$FQDN/healthz"
# Should return: {"status":"ok","agent":"pce","framework":"a365"}
```

---

## Step 13: Setup A365 Permissions & Graph API

### Add Graph Permissions

```powershell
.\scripts\setup-a365-permissions.ps1
```

This adds Application.ReadWrite.All, DelegatedPermissionGrant.ReadWrite.All, Directory.Read.All, and User.ReadWrite.All to the service principal and grants admin consent.

### Install A365 CLI

```powershell
dotnet tool install --global Microsoft.Agents.A365.DevTools.Cli --prerelease
```

### Login and Setup

```powershell
a365 auth login --tenant-id <your-tenant-id>
a365 setup --config-file agent-webapp/manifest/a365.config.json
```

After setup, note the Bot App ID and Secret, then update `terraform.tfvars`:

```hcl
bot_app_id     = "<from-a365-setup>"
bot_app_secret = "<from-a365-setup>"
```

Redeploy the Container App to apply the new env vars:

```powershell
terraform apply -target=module.agent_webapp
```

---

## Step 14: Publish to M365 (Teams)

### Configure Teams Developer Portal

1. Go to [Teams Developer Portal](https://dev.teams.microsoft.com/apps)
2. Import the manifest from `agent-webapp/manifest/manifest.json` (replace `{{BOT_APP_ID}}` with your actual Bot App ID)
3. Under **App features** → **Bot**, set:
   - **Agent Type**: API Based
   - **Notification URL**: `https://<agent-webapp-fqdn>/api/messages`
4. Under **Publish** → **Publish to your org** or install for personal use

### VNet Integration for A365-Created App Service

If you used `needDeployment: true` in a365.config.json and A365 created its own App Service:

```powershell
.\scripts\add-vnet-integration.ps1 -AppServiceName "<a365-app-name>"
```

This adds VNet Integration so the App Service can reach the internal MCP server and private endpoints.

### Test in Teams

1. Search for "PCE Agent" in the Teams app catalog
2. Start a personal chat with the agent
3. Try: "What's the weather in Seattle?" or "What time is it in Tokyo?"

---

## Cleanup

```powershell
cd infra-terraform
terraform destroy

# Also delete the Entra ID app registration if no longer needed
az ad app delete --id <your-sp-client-id>
```

---

## Key Lessons Learned

1. **azapi v2.x**: `.output` is already an object — never wrap in `jsondecode()`
2. **storage_use_azuread = true**: Required in azurerm provider when all storage accounts disable shared keys
3. **Flex Consumption Functions**: Need 4 RBAC roles on their storage (blob owner, queue contributor, table contributor, file SMB contributor)
4. **EasyAuth + Anonymous auth level**: The function code uses `AuthLevel.ANONYMOUS` because EasyAuth handles auth at the platform layer before requests reach the function
5. **MCP server HTTPS**: Container Apps redirect HTTP→HTTPS. Always use `https://` URLs
6. **Agent tool types**: `function` = client-executed (works with any tier). `azure_function` = server-executed (requires Enterprise Standard)
7. **Private DNS for internal CAE**: Must create wildcard (`*`) and root (`@`) A records pointing to the CAE static IP
8. **AI Search free tier**: No private endpoint support. Either keep it public or use a paid SKU
9. **Jump VM NSGs**: Both NIC-level and subnet-level NSGs must allow SSH for connectivity
10. **Foundry agents are data-plane only**: Terraform can't manage them. Use REST API scripts
11. **Managed identity for Foundry project**: Must be granted access (e.g. Website Contributor) on the Function App for the agent runtime to invoke tools over the VNet
12. **Function App MI → Storage**: Beyond the 4 Terraform-managed roles on the function's runtime storage, you may need `Storage Blob Data Contributor` on the shared project storage account
13. **Service Principal via Portal**: When creating the app registration in Entra ID, remember to set Application ID URI and expose a scope (e.g. `Files.Read`) under "Expose an API" — this is needed for EasyAuth token audiences
14. **A365 self-hosted mode**: Use `needDeployment: false` when deploying your own Container App. The `messagingEndpoint` points to the Container App's public FQDN
15. **External CAE + VNet**: An external Container App Environment (internal_load_balancer_enabled=false) on a VNet subnet provides internet accessibility while maintaining VNet connectivity to internal resources
16. **Bot Framework Activities**: M365 sends Activities to `/api/messages`. The agent processes them and replies via the Bot Connector REST API at the `serviceUrl` provided in the activity
17. **Separate CAE for external access**: The MCP server's internal CAE must remain internal. Deploy the agent webapp on a separate external CAE on its own subnet (/23 for Container Apps)
