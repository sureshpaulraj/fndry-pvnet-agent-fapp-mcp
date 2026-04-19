<#
.SYNOPSIS
    End-to-end deployment script for the Hybrid Network AI Agent project.
    Deploys infrastructure, application code, creates the Foundry agent,
    configures the Jump VM, and runs verification tests.

.DESCRIPTION
    This script automates the entire deployment pipeline described in SKILL.md:
      1. Validate prerequisites (tools, Azure context)
      2. Terraform init, plan, apply (infrastructure)
      3. Deploy Weather Function code
      4. Build and push MCP Docker image to ACR
      5. Update Container App with real image and configure EasyAuth
      6. Configure managed identity RBAC (Foundry project → Function App, Function App → Storage)
      7. Create/update the Foundry agent via REST API
      8. Set up the Jump VM (upload client, install deps)
      9. Run verification tests
     10. Deployment summary

    Run from the project root directory (hybrid-network/).

.PARAMETER SkipInfra
    Skip Terraform steps (infrastructure already deployed).

.PARAMETER SkipAgent
    Skip Foundry agent creation (agent already exists).

.PARAMETER SkipJumpVM
    Skip Jump VM setup.

.PARAMETER AgentId
    Existing agent ID (skip agent creation and use this ID).

.PARAMETER DryRun
    Show what would be done without making changes.

.EXAMPLE
    # Full deployment from scratch
    .\deploy-all.ps1

    # Skip infrastructure (already deployed)
    .\deploy-all.ps1 -SkipInfra

    # Re-deploy just the agent and jump VM setup
    .\deploy-all.ps1 -SkipInfra -AgentId "asst_xxxxx"
#>
[CmdletBinding()]
param(
    [switch]$SkipInfra,
    [switch]$SkipAgent,
    [switch]$SkipJumpVM,
    [string]$AgentId,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$ProjectRoot = $PSScriptRoot

# ═══════════════════════════════════════════════════════════════════════════════
# Helper Functions
# ═══════════════════════════════════════════════════════════════════════════════

function Write-Step($stepNum, $totalSteps, $message) {
    Write-Host "[$stepNum/$totalSteps] $message" -ForegroundColor Green
}

function Write-SubStep($message) {
    Write-Host "  $message" -ForegroundColor Yellow
}

function Write-Success($message) {
    Write-Host "  ✓ $message" -ForegroundColor Green
}

function Write-Fail($message) {
    Write-Host "  ✗ $message" -ForegroundColor Red
}

function Assert-Command($cmd, $name) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Fail "$name is not installed or not in PATH."
        Write-Host "    Install: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli" -ForegroundColor DarkYellow
        exit 1
    }
}

function Assert-ExitCode($stepName) {
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "$stepName failed (exit code $LASTEXITCODE)"
        exit 1
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Load .env
# ═══════════════════════════════════════════════════════════════════════════════

$envFile = Join-Path $ProjectRoot ".env"
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
            [Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim(), "Process")
        }
    }
    Write-Host "Loaded .env" -ForegroundColor DarkGray
}

# ═══════════════════════════════════════════════════════════════════════════════
# Configuration (from .env and terraform.tfvars)
# ═══════════════════════════════════════════════════════════════════════════════

$SUBSCRIPTION_ID = $env:AZURE_SUBSCRIPTION_ID
$TENANT_ID       = $env:AZURE_TENANT_ID
$RESOURCE_GROUP  = if ($env:RESOURCE_GROUP) { $env:RESOURCE_GROUP } else { "rg-hybrid-agent" }
$LOCATION        = if ($env:LOCATION) { $env:LOCATION } else { "eastus2" }

# SP credentials (needed for agent creation and EasyAuth)
$CLIENT_ID     = $env:AZURE_CLIENT_ID
$CLIENT_SECRET = $env:AZURE_CLIENT_SECRET

$TOTAL_STEPS = 10

Write-Host ""
Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Hybrid Network AI Agent — Full Deployment                ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Subscription:  $SUBSCRIPTION_ID"
Write-Host "  Tenant:        $TENANT_ID"
Write-Host "  Resource Group: $RESOURCE_GROUP"
Write-Host "  Location:      $LOCATION"
Write-Host "  Skip Infra:    $SkipInfra"
Write-Host "  Skip Agent:    $SkipAgent"
Write-Host "  Skip Jump VM:  $SkipJumpVM"
if ($DryRun) { Write-Host "  *** DRY RUN — no changes will be made ***" -ForegroundColor Magenta }
Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════════
# Step 1: Validate Prerequisites
# ═══════════════════════════════════════════════════════════════════════════════

Write-Step 1 $TOTAL_STEPS "Validating prerequisites..."

Assert-Command "az" "Azure CLI"
Assert-Command "terraform" "Terraform"
Assert-Command "func" "Azure Functions Core Tools"
Assert-Command "docker" "Docker"
Assert-Command "ssh" "SSH client"
Assert-Command "scp" "SCP client"

Write-Success "All required tools found"

# Validate Azure context
$currentAccount = az account show --output json 2>$null | ConvertFrom-Json
if (-not $currentAccount) {
    Write-SubStep "Not logged in. Running az login..."
    if (-not $DryRun) {
        az login --tenant $TENANT_ID
        az account set --subscription $SUBSCRIPTION_ID
    }
} else {
    if ($currentAccount.id -ne $SUBSCRIPTION_ID) {
        Write-SubStep "Setting subscription..."
        if (-not $DryRun) { az account set --subscription $SUBSCRIPTION_ID }
    }
    if ($currentAccount.tenantId -ne $TENANT_ID) {
        Write-Fail "Tenant mismatch: current=$($currentAccount.tenantId), expected=$TENANT_ID"
        Write-Host "    Run: az login --tenant $TENANT_ID" -ForegroundColor DarkYellow
        exit 1
    }
}

Write-Success "Azure context validated"

# Check SSH key exists
$sshKeyPath = Join-Path $HOME ".ssh" "id_rsa.pub"
if (-not (Test-Path $sshKeyPath)) {
    Write-Fail "SSH public key not found at $sshKeyPath"
    Write-Host "    Run: ssh-keygen -t rsa -b 4096 -f `"$HOME\.ssh\id_rsa`" -N '`"`"'" -ForegroundColor DarkYellow
    exit 1
}
Write-Success "SSH key found"

# ═══════════════════════════════════════════════════════════════════════════════
# Step 2: Terraform — Deploy Infrastructure
# ═══════════════════════════════════════════════════════════════════════════════

Write-Step 2 $TOTAL_STEPS "Deploying infrastructure with Terraform..."

$terraformDir = Join-Path $ProjectRoot "infra-terraform"

if ($SkipInfra) {
    Write-SubStep "Skipped (--SkipInfra)"
} elseif ($DryRun) {
    Write-SubStep "[DRY RUN] Would run: terraform init, plan, apply in $terraformDir"
} else {
    Push-Location $terraformDir
    try {
        Write-SubStep "terraform init -upgrade..."
        terraform init -upgrade
        Assert-ExitCode "terraform init"

        Write-SubStep "terraform plan..."
        terraform plan -out=tfplan
        Assert-ExitCode "terraform plan"

        Write-SubStep "terraform apply..."
        terraform apply tfplan
        Assert-ExitCode "terraform apply"

        Write-Success "Infrastructure deployed"
    }
    finally {
        Pop-Location
    }
}

# ─── Capture Terraform outputs ───────────────────────────────────────────────

Write-SubStep "Reading Terraform outputs..."
Push-Location $terraformDir
try {
    $tfOutput = terraform output -json 2>$null | ConvertFrom-Json
}
finally {
    Pop-Location
}

if (-not $tfOutput) {
    Write-Fail "Could not read Terraform outputs. Ensure infrastructure is deployed."
    exit 1
}

$funcAppName  = $tfOutput.weather_function_name.value
$funcHostname = $tfOutput.weather_function_hostname.value
$acrName      = $tfOutput.datetime_mcp_acr_name.value
$mcpAppName   = $tfOutput.datetime_mcp_app_name.value
$mcpFqdn      = $tfOutput.datetime_mcp_fqdn.value
$mcpUrl       = $tfOutput.datetime_mcp_url.value
$aiAccount    = $tfOutput.ai_account_name.value
$aiEndpoint   = $tfOutput.ai_account_endpoint.value
$projectName  = $tfOutput.project_name.value
$jumpIp       = $tfOutput.jumpbox_public_ip.value

Write-Success "Terraform outputs captured"
Write-Host "    Function App:  $funcAppName" -ForegroundColor DarkGray
Write-Host "    ACR:           $acrName" -ForegroundColor DarkGray
Write-Host "    MCP App:       $mcpAppName ($mcpFqdn)" -ForegroundColor DarkGray
Write-Host "    AI Account:    $aiAccount" -ForegroundColor DarkGray
Write-Host "    Project:       $projectName" -ForegroundColor DarkGray
Write-Host "    Jump VM IP:    $jumpIp" -ForegroundColor DarkGray

# ═══════════════════════════════════════════════════════════════════════════════
# Step 3: Deploy Weather Function Code
# ═══════════════════════════════════════════════════════════════════════════════

Write-Step 3 $TOTAL_STEPS "Deploying Weather Function code..."

if (-not $funcAppName) {
    Write-Fail "Function App name not found in Terraform outputs"
    exit 1
}

if ($DryRun) {
    Write-SubStep "[DRY RUN] Would run: func azure functionapp publish $funcAppName --python"
} else {
    Push-Location (Join-Path $ProjectRoot "azure-function-server")
    try {
        func azure functionapp publish $funcAppName --python
        Assert-ExitCode "func publish"
        Write-Success "Weather Function deployed: https://$funcHostname"
    }
    finally {
        Pop-Location
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Step 4: Build and Push MCP Server Image
# ═══════════════════════════════════════════════════════════════════════════════

Write-Step 4 $TOTAL_STEPS "Building and deploying MCP server..."

if (-not $acrName) {
    Write-Fail "ACR name not found in Terraform outputs"
    exit 1
}

if ($DryRun) {
    Write-SubStep "[DRY RUN] Would run: az acr build --registry $acrName --image datetime-mcp:latest"
} else {
    $mcpServerPath = Join-Path $ProjectRoot "mcp-server"
    az acr build --registry $acrName --image datetime-mcp:latest $mcpServerPath
    Assert-ExitCode "ACR build"
    Write-Success "MCP image pushed to $acrName.azurecr.io/datetime-mcp:latest"

    # Update Container App to use the real image
    if ($mcpAppName) {
        Write-SubStep "Updating Container App to use real image..."
        az containerapp update --name $mcpAppName `
            --resource-group $RESOURCE_GROUP `
            --image "$acrName.azurecr.io/datetime-mcp:latest"
        Assert-ExitCode "Container App update"
        Write-Success "Container App updated: $mcpAppName"
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Step 5: Configure EasyAuth on Weather Function
# ═══════════════════════════════════════════════════════════════════════════════

Write-Step 5 $TOTAL_STEPS "Configuring EasyAuth on Weather Function..."

if (-not $CLIENT_ID) {
    Write-SubStep "AZURE_CLIENT_ID not set — skipping EasyAuth. Configure manually in Portal."
} elseif ($DryRun) {
    Write-SubStep "[DRY RUN] Would configure EasyAuth with client ID: $CLIENT_ID"
} else {
    # Check if auth is already configured
    $authSettings = az webapp auth show --name $funcAppName --resource-group $RESOURCE_GROUP --output json 2>$null | ConvertFrom-Json
    if ($authSettings -and $authSettings.platform -and $authSettings.platform.enabled) {
        Write-Success "EasyAuth already configured"
    } else {
        Write-SubStep "Enabling Microsoft identity provider..."
        az webapp auth microsoft update --name $funcAppName `
            --resource-group $RESOURCE_GROUP `
            --client-id $CLIENT_ID `
            --issuer "https://sts.windows.net/$TENANT_ID/" `
            --yes 2>$null

        az webapp auth update --name $funcAppName `
            --resource-group $RESOURCE_GROUP `
            --enabled true `
            --action Return401 2>$null

        Write-Success "EasyAuth configured (Return401 for unauthenticated)"
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Step 6: Configure Managed Identity RBAC Assignments
# ═══════════════════════════════════════════════════════════════════════════════

Write-Step 6 $TOTAL_STEPS "Configuring managed identity RBAC assignments..."

if ($DryRun) {
    Write-SubStep "[DRY RUN] Would assign Foundry project MI → Function App, Function App MI → Storage"
} else {
    # 6a. Foundry project managed identity → Website Contributor on Function App
    Write-SubStep "Granting Foundry project identity access to Function App..."
    $projectResourceId = az resource list -g $RESOURCE_GROUP --resource-type "Microsoft.CognitiveServices/accounts/projects" --query "[0].id" -o tsv 2>$null
    if ($projectResourceId) {
        $projectPrincipalId = az resource show --ids $projectResourceId --query "identity.principalId" -o tsv 2>$null
        $funcAppId = az functionapp show --name $funcAppName -g $RESOURCE_GROUP --query id -o tsv 2>$null
        if ($projectPrincipalId -and $funcAppId) {
            $existing = az role assignment list --assignee $projectPrincipalId --scope $funcAppId --role "Website Contributor" --query "[0].id" -o tsv 2>$null
            if ($existing) {
                Write-Success "Foundry project MI already has Website Contributor on Function App"
            } else {
                az role assignment create --assignee-object-id $projectPrincipalId `
                    --assignee-principal-type ServicePrincipal `
                    --role "Website Contributor" `
                    --scope $funcAppId -o none 2>$null
                Assert-ExitCode "Foundry project MI role assignment"
                Write-Success "Foundry project MI → Website Contributor on $funcAppName"
            }
        } else {
            Write-SubStep "Could not resolve project principal ID or function app ID — assign manually in Portal"
        }
    } else {
        Write-SubStep "Could not find Foundry project resource — assign manually in Portal"
    }

    # 6b. Function App managed identity → Storage Blob Data Contributor on dependent storage
    Write-SubStep "Granting Function App identity access to dependent storage..."
    $funcPrincipalId = az functionapp identity show --name $funcAppName -g $RESOURCE_GROUP --query principalId -o tsv 2>$null
    # Find the dependent-resources storage account (not the function's own runtime storage)
    $depStorageAccounts = az storage account list -g $RESOURCE_GROUP --query "[?!contains(name, 'weather') && !contains(name, 'toolq')].{name:name, id:id}" -o json 2>$null | ConvertFrom-Json
    if ($funcPrincipalId -and $depStorageAccounts -and $depStorageAccounts.Count -gt 0) {
        foreach ($stg in $depStorageAccounts) {
            $existing = az role assignment list --assignee $funcPrincipalId --scope $stg.id --role "Storage Blob Data Contributor" --query "[0].id" -o tsv 2>$null
            if ($existing) {
                Write-Success "Function App MI already has Storage Blob Data Contributor on $($stg.name)"
            } else {
                az role assignment create --assignee-object-id $funcPrincipalId `
                    --assignee-principal-type ServicePrincipal `
                    --role "Storage Blob Data Contributor" `
                    --scope $stg.id -o none 2>$null
                Assert-ExitCode "Function App MI storage role assignment"
                Write-Success "Function App MI → Storage Blob Data Contributor on $($stg.name)"
            }
        }
    } else {
        Write-SubStep "Could not resolve function principal ID or storage accounts — assign manually in Portal"
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Step 7: Create/Update Foundry Agent
# ═══════════════════════════════════════════════════════════════════════════════

Write-Step 7 $TOTAL_STEPS "Creating Foundry agent..."

if ($AgentId) {
    Write-SubStep "Using existing agent: $AgentId"
} elseif ($SkipAgent) {
    Write-SubStep "Skipped (--SkipAgent)"
} elseif (-not $CLIENT_ID -or -not $CLIENT_SECRET) {
    Write-Fail "AZURE_CLIENT_ID and AZURE_CLIENT_SECRET required for agent creation"
    Write-Host "    Set them in .env or environment variables" -ForegroundColor DarkYellow
    exit 1
} elseif ($DryRun) {
    Write-SubStep "[DRY RUN] Would run create_or_update_agent.ps1"
} else {
    $agentScript = Join-Path $ProjectRoot "scripts" "create_or_update_agent.ps1"
    if (-not (Test-Path $agentScript)) {
        Write-Fail "Agent script not found: $agentScript"
        exit 1
    }

    # Derive the cog services endpoint from Terraform output
    $cogEndpoint = "https://$aiAccount.cognitiveservices.azure.com/"

    # Get SP object ID
    $spObjectId = az ad sp show --id $CLIENT_ID --query id -o tsv 2>$null

    & $agentScript `
        -ClientId $CLIENT_ID `
        -ClientSecret $CLIENT_SECRET `
        -TenantId $TENANT_ID `
        -AccountEndpoint $cogEndpoint `
        -ProjectName $projectName `
        -ModelDeploymentName "gpt-4.1-mini" `
        -AgentName "pce" `
        -SubscriptionId $SUBSCRIPTION_ID `
        -AccountName $aiAccount `
        -SpObjectId $spObjectId `
        -ResourceGroupName $RESOURCE_GROUP

    Assert-ExitCode "Agent creation"
    Write-Success "Foundry agent created/updated"

    # Capture the agent ID from the Foundry API
    if (-not $AgentId) {
        Write-SubStep "Fetching agent ID..."
        $foundryEndpoint = "https://$aiAccount.services.ai.azure.com/api/projects/$projectName"
        $tokenBody = @{
            grant_type    = "client_credentials"
            client_id     = $CLIENT_ID
            client_secret = $CLIENT_SECRET
            scope         = "https://ai.azure.com/.default"
        }
        $tokenResp = Invoke-RestMethod -Method Post `
            -Uri "https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token" `
            -ContentType "application/x-www-form-urlencoded" `
            -Body $tokenBody
        $authHeaders = @{
            "Authorization" = "Bearer $($tokenResp.access_token)"
            "Content-Type"  = "application/json"
        }
        $agents = Invoke-RestMethod -Method Get `
            -Uri "$foundryEndpoint/assistants?api-version=v1" `
            -Headers $authHeaders
        $pceAgent = $agents.data | Where-Object { $_.name -eq "pce" } | Select-Object -First 1
        if ($pceAgent) {
            $AgentId = $pceAgent.id
            Write-Success "Agent ID: $AgentId"
        } else {
            Write-Fail "Could not find agent 'pce' after creation"
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Step 8: Set Up Jump VM
# ═══════════════════════════════════════════════════════════════════════════════

Write-Step 8 $TOTAL_STEPS "Setting up Jump VM..."

if ($SkipJumpVM) {
    Write-SubStep "Skipped (--SkipJumpVM)"
} elseif (-not $jumpIp) {
    Write-Fail "Jump VM IP not found in Terraform outputs"
    exit 1
} elseif ($DryRun) {
    Write-SubStep "[DRY RUN] Would SSH to $jumpIp, install deps, upload client"
} else {
    $sshOpts = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30"
    $sshTarget = "azureuser@$jumpIp"

    # Wait for VM to be reachable
    Write-SubStep "Waiting for VM to be reachable..."
    $maxRetries = 10
    $reachable = $false
    for ($i = 1; $i -le $maxRetries; $i++) {
        $result = ssh $sshOpts.Split(' ') $sshTarget "echo ok" 2>$null
        if ($result -eq "ok") {
            $reachable = $true
            break
        }
        Write-Host "    Attempt $i/$maxRetries — waiting 15s..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 15
    }
    if (-not $reachable) {
        Write-Fail "Cannot reach Jump VM at $jumpIp. Check NSG rules (AllowSSH on both NIC and subnet NSGs)."
        exit 1
    }
    Write-Success "VM reachable"

    # Install dependencies
    Write-SubStep "Installing Python dependencies on VM..."
    ssh $sshOpts.Split(' ') $sshTarget @"
        sudo apt-get update -qq && sudo apt-get install -y -qq python3-pip python3-venv curl jq > /dev/null 2>&1
        mkdir -p ~/agent
        cd ~/agent
        python3 -m venv .venv
        source .venv/bin/activate
        pip install -q azure-identity python-dotenv requests
"@
    Write-Success "Dependencies installed"

    # Upload agent client
    Write-SubStep "Uploading agent client..."
    $agentClient = Join-Path $ProjectRoot "ai-agent" "foundry_agent.py"
    scp $sshOpts.Split(' ') $agentClient "${sshTarget}:~/agent/"
    Write-Success "Agent client uploaded"

    # Create .env on VM
    Write-SubStep "Creating .env on Jump VM..."
    $foundryEndpoint = "https://$aiAccount.services.ai.azure.com/api/projects/$projectName"
    $mcpBaseUrl = "https://$mcpFqdn"
    $weatherBaseUrl = "https://$funcHostname"

    $vmEnvContent = @"
FOUNDRY_ENDPOINT=$foundryEndpoint
AGENT_ID=$AgentId
AGENT_API_VERSION=v1
WEATHER_BASE_URL=$weatherBaseUrl
WEATHER_AUTH_CLIENT_ID=$CLIENT_ID
MCP_BASE_URL=$mcpBaseUrl
AZURE_CLIENT_ID=$CLIENT_ID
AZURE_CLIENT_SECRET=$CLIENT_SECRET
AZURE_TENANT_ID=$TENANT_ID
"@

    # Write env content to a temp file and scp it
    $tempEnv = [System.IO.Path]::GetTempFileName()
    $vmEnvContent | Set-Content -Path $tempEnv -NoNewline
    scp $sshOpts.Split(' ') $tempEnv "${sshTarget}:~/agent/.env"
    Remove-Item $tempEnv
    Write-Success "Jump VM .env configured"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Step 9: Verification Tests
# ═══════════════════════════════════════════════════════════════════════════════

Write-Step 9 $TOTAL_STEPS "Running verification tests..."

if ($DryRun) {
    Write-SubStep "[DRY RUN] Would test Weather Function and MCP Server endpoints"
} else {
    # Test Weather Function (public endpoint with EasyAuth)
    Write-SubStep "Testing Weather Function (public)..."
    if ($CLIENT_ID) {
        try {
            $token = az account get-access-token --resource $CLIENT_ID --query accessToken -o tsv 2>$null
            if ($token) {
                $weatherResp = Invoke-RestMethod -Uri "https://$funcHostname/api/healthz" `
                    -Headers @{ "Authorization" = "Bearer $token" } `
                    -TimeoutSec 15
                if ($weatherResp.status -eq "ok") {
                    Write-Success "Weather Function health check passed"
                } else {
                    Write-Fail "Weather Function returned unexpected response"
                }
            } else {
                Write-SubStep "Could not get token — skipping public endpoint test"
            }
        } catch {
            Write-Fail "Weather Function test failed: $($_.Exception.Message)"
        }
    } else {
        Write-SubStep "No CLIENT_ID — skipping Weather Function auth test"
    }

    # Test MCP Server (via Jump VM — it's VNet-internal)
    if (-not $SkipJumpVM -and $jumpIp -and $mcpFqdn) {
        Write-SubStep "Testing MCP Server (via Jump VM)..."
        try {
            $mcpResult = ssh $sshOpts.Split(' ') $sshTarget "curl -s https://$mcpFqdn/healthz 2>/dev/null"
            if ($mcpResult -match "ok") {
                Write-Success "MCP Server health check passed (via Jump VM)"
            } else {
                Write-SubStep "MCP Server response: $mcpResult"
            }
        } catch {
            Write-Fail "MCP Server test failed: $($_.Exception.Message)"
        }
    }

    # Quick agent test (via Jump VM)
    if (-not $SkipJumpVM -and $jumpIp -and $AgentId) {
        Write-SubStep "Testing agent (via Jump VM)..."
        try {
            $agentResult = ssh $sshOpts.Split(' ') $sshTarget @"
                cd ~/agent && source .venv/bin/activate && timeout 60 python foundry_agent.py "What time is it in UTC?" 2>&1 | tail -5
"@
            if ($agentResult) {
                Write-Success "Agent responded:"
                Write-Host "    $agentResult" -ForegroundColor DarkGray
            }
        } catch {
            Write-SubStep "Agent test did not complete (may need manual verification)"
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Step 10: Deployment Summary
# ═══════════════════════════════════════════════════════════════════════════════

Write-Step 10 $TOTAL_STEPS "Deployment Summary"

Write-Host ""
Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Deployment Complete!                                      ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Resources:" -ForegroundColor White
Write-Host "    Resource Group:    $RESOURCE_GROUP"
Write-Host "    AI Account:        $aiAccount"
Write-Host "    Project:           $projectName"
Write-Host "    Weather Function:  https://$funcHostname"
Write-Host "    MCP Server:        https://$mcpFqdn (VNet-internal)"
Write-Host "    ACR:               $acrName.azurecr.io"
Write-Host "    Jump VM:           $jumpIp (ssh azureuser@$jumpIp)"
if ($AgentId) {
    Write-Host "    Agent ID:          $AgentId"
}
Write-Host ""
Write-Host "  To use the agent:" -ForegroundColor White
Write-Host "    ssh azureuser@$jumpIp"
Write-Host "    cd ~/agent && source .venv/bin/activate"
Write-Host "    python foundry_agent.py"
Write-Host ""
Write-Host "  To run unit tests locally:" -ForegroundColor White
Write-Host "    python -m pytest azure-function-server/test_function_app.py -v"
Write-Host "    python -m pytest mcp-server/test_server.py -v"
Write-Host "    python -m pytest ai-agent/test_agent.py -v"
Write-Host ""
Write-Host "  IMPORTANT: Rotate the SP client secret when done." -ForegroundColor Yellow
Write-Host ""
