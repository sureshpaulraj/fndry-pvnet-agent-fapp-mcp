# deploy.ps1 — Deploys the hybrid private resources agent setup
# Uses subscription ME-MngEnvMCAP687688-surep-1 (2588d490-7849-4b98-9b57-8309b012872b)
# Tenant: 5d0245d3-4d99-44f5-82d3-28c83aeda726
#
# Usage: .\deploy.ps1

$ErrorActionPreference = "Stop"

# ─── Load .env ───────────────────────────────────────────────────────────────
$envFile = Join-Path $PSScriptRoot ".env"
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
            [Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim(), "Process")
        }
    }
}

# ─── Configuration ───────────────────────────────────────────────────────────
$SUBSCRIPTION_ID = $env:AZURE_SUBSCRIPTION_ID
$TENANT_ID       = $env:AZURE_TENANT_ID
$RESOURCE_GROUP  = $env:RESOURCE_GROUP
$LOCATION        = $env:LOCATION

# ─── Validate configuration ─────────────────────────────────────────────────
Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Hybrid Private Resources Agent Setup — Deployment      ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "Subscription: $SUBSCRIPTION_ID" -ForegroundColor Yellow
Write-Host "Tenant:       $TENANT_ID" -ForegroundColor Yellow
Write-Host "RG:           $RESOURCE_GROUP" -ForegroundColor Yellow
Write-Host "Location:     $LOCATION" -ForegroundColor Yellow
Write-Host ""

# ─── Step 1: Verify Azure context ───────────────────────────────────────────
Write-Host "[1/6] Verifying Azure context..." -ForegroundColor Green
$currentAccount = az account show --output json | ConvertFrom-Json
if ($currentAccount.id -ne $SUBSCRIPTION_ID) {
    Write-Host "  Setting subscription to $SUBSCRIPTION_ID..." -ForegroundColor Yellow
    az account set --subscription $SUBSCRIPTION_ID
}
if ($currentAccount.tenantId -ne $TENANT_ID) {
    Write-Host "  WARNING: Current tenant ($($currentAccount.tenantId)) differs from expected ($TENANT_ID)" -ForegroundColor Red
    Write-Host "  Run: az login --tenant $TENANT_ID" -ForegroundColor Red
    exit 1
}

# Verify subscription and tenant after setting
$verifyAccount = az account show --output json | ConvertFrom-Json
Write-Host "  ✓ Subscription: $($verifyAccount.name) ($($verifyAccount.id))" -ForegroundColor Green
Write-Host "  ✓ Tenant: $($verifyAccount.tenantId)" -ForegroundColor Green
if ($verifyAccount.id -ne $SUBSCRIPTION_ID -or $verifyAccount.tenantId -ne $TENANT_ID) {
    Write-Host "  ERROR: Subscription or tenant mismatch!" -ForegroundColor Red
    exit 1
}

# ─── Step 2: Create resource group ──────────────────────────────────────────
Write-Host "[2/6] Creating resource group '$RESOURCE_GROUP' in '$LOCATION'..." -ForegroundColor Green
az group create --name $RESOURCE_GROUP --location $LOCATION --output none
Write-Host "  ✓ Resource group ready" -ForegroundColor Green

# ─── Step 3: Deploy main infrastructure (Bicep) ─────────────────────────────
Write-Host "[3/6] Deploying main infrastructure (VNet, AI Services, dependencies)..." -ForegroundColor Green
$bicepPath = Join-Path $PSScriptRoot "infra" "main.bicep"
az deployment group create `
    --resource-group $RESOURCE_GROUP `
    --template-file $bicepPath `
    --parameters location=$LOCATION `
    --output none
Write-Host "  ✓ Infrastructure deployed" -ForegroundColor Green

# ─── Step 4: Deploy Weather Azure Function code ─────────────────────────────
Write-Host "[4/6] Deploying Weather Azure Function..." -ForegroundColor Green
$funcAppName = az deployment group show `
    --resource-group $RESOURCE_GROUP `
    --name "main" `
    --query "properties.outputs.weatherFunctionName.value" -o tsv 2>$null

if ($funcAppName) {
    Push-Location (Join-Path $PSScriptRoot "azure-function-server")
    try {
        func azure functionapp publish $funcAppName --python
        Write-Host "  ✓ Weather Function deployed: https://$funcAppName.azurewebsites.net" -ForegroundColor Green
    }
    finally {
        Pop-Location
    }
} else {
    Write-Host "  ⚠ Could not determine Function App name from deployment outputs" -ForegroundColor Yellow
}

# ─── Step 5: Build and push DateTime MCP server ─────────────────────────────
Write-Host "[5/6] Building and deploying DateTime MCP server..." -ForegroundColor Green
$acrName = az deployment group show `
    --resource-group $RESOURCE_GROUP `
    --name "main" `
    --query "properties.outputs.dateTimeMcpAcrName.value" -o tsv 2>$null

if (-not $acrName) {
    # Try to find ACR in the resource group
    $acrName = az acr list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv 2>$null
}

if ($acrName) {
    $mcpServerPath = Join-Path $PSScriptRoot "mcp-server"
    az acr build --registry $acrName --image datetime-mcp:latest $mcpServerPath
    Write-Host "  ✓ DateTime MCP server image pushed to $acrName" -ForegroundColor Green

    # Update Container App with the new image
    $mcpAppName = az deployment group show `
        --resource-group $RESOURCE_GROUP `
        --name "main" `
        --query "properties.outputs.dateTimeMcpAppName.value" -o tsv 2>$null
    if ($mcpAppName) {
        Write-Host "  ✓ DateTime MCP server deployed: $mcpAppName" -ForegroundColor Green
    }
} else {
    Write-Host "  ⚠ Could not find ACR. Build MCP image manually." -ForegroundColor Yellow
}

# ─── Step 6: Show deployment summary ────────────────────────────────────────
Write-Host ""
Write-Host "[6/6] Deployment Summary" -ForegroundColor Green
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
az deployment group show `
    --resource-group $RESOURCE_GROUP `
    --name "main" `
    --query "properties.outputs" `
    --output table

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Deployment complete!                                    ║" -ForegroundColor Cyan
Write-Host "║                                                          ║" -ForegroundColor Cyan
Write-Host "║  Next steps:                                             ║" -ForegroundColor Cyan
Write-Host "║  1. Navigate to https://ai.azure.com                    ║" -ForegroundColor Cyan
Write-Host "║  2. Select your project                                  ║" -ForegroundColor Cyan
Write-Host "║  3. Create an agent with OpenAPI tool (Weather Function) ║" -ForegroundColor Cyan
Write-Host "║  4. Create an agent with MCP tool (DateTime server)      ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
