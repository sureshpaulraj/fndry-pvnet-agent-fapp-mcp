# deploy-terraform.ps1 — Deploys the hybrid private resources agent setup using Terraform
# Uses subscription ME-MngEnvMCAP687688-surep-1 (2588d490-7849-4b98-9b57-8309b012872b)
# Tenant: 5d0245d3-4d99-44f5-82d3-28c83aeda726
#
# Usage: .\deploy-terraform.ps1

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

# ─── Validate configuration ─────────────────────────────────────────────────
Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Hybrid Private Resources Agent Setup — Terraform       ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "Subscription: $SUBSCRIPTION_ID" -ForegroundColor Yellow
Write-Host "Tenant:       $TENANT_ID" -ForegroundColor Yellow
Write-Host ""

# ─── Step 1: Verify Azure context ───────────────────────────────────────────
Write-Host "[1/7] Verifying Azure context..." -ForegroundColor Green
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

# ─── Step 2: Terraform init ─────────────────────────────────────────────────
Write-Host "[2/7] Initializing Terraform..." -ForegroundColor Green
$terraformDir = Join-Path $PSScriptRoot "infra-terraform"
Push-Location $terraformDir
try {
    terraform init -upgrade
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ERROR: terraform init failed" -ForegroundColor Red
        exit 1
    }
    Write-Host "  ✓ Terraform initialized" -ForegroundColor Green

    # ─── Step 3: Terraform plan ──────────────────────────────────────────────
    Write-Host "[3/7] Planning Terraform deployment..." -ForegroundColor Green
    terraform plan -out=tfplan
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ERROR: terraform plan failed" -ForegroundColor Red
        exit 1
    }
    Write-Host "  ✓ Plan generated" -ForegroundColor Green

    # ─── Step 4: Terraform apply ─────────────────────────────────────────────
    Write-Host "[4/7] Applying Terraform..." -ForegroundColor Green
    terraform apply tfplan
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ERROR: terraform apply failed" -ForegroundColor Red
        exit 1
    }
    Write-Host "  ✓ Infrastructure deployed" -ForegroundColor Green

    # Capture outputs
    $tfOutput = terraform output -json | ConvertFrom-Json

    $funcAppName = $tfOutput.weather_function_name.value
    $acrName     = $tfOutput.datetime_mcp_acr_name.value
    $mcpAppName  = $tfOutput.datetime_mcp_app_name.value
    $rgName      = $env:RESOURCE_GROUP
}
finally {
    Pop-Location
}

# ─── Step 5: Deploy Weather Azure Function code ─────────────────────────────
Write-Host "[5/7] Deploying Weather Azure Function..." -ForegroundColor Green
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
    Write-Host "  ⚠ Could not determine Function App name from Terraform outputs" -ForegroundColor Yellow
}

# ─── Step 6: Build and push DateTime MCP server ─────────────────────────────
Write-Host "[6/7] Building and deploying DateTime MCP server..." -ForegroundColor Green
if ($acrName) {
    $mcpServerPath = Join-Path $PSScriptRoot "mcp-server"
    az acr build --registry $acrName --image datetime-mcp:latest $mcpServerPath
    Write-Host "  ✓ DateTime MCP server image pushed to $acrName" -ForegroundColor Green

    if ($mcpAppName) {
        Write-Host "  ✓ DateTime MCP server deployed: $mcpAppName" -ForegroundColor Green
    }
} else {
    Write-Host "  ⚠ Could not find ACR name. Build MCP image manually." -ForegroundColor Yellow
}

# ─── Step 7: Show deployment summary ────────────────────────────────────────
Write-Host ""
Write-Host "[7/7] Deployment Summary" -ForegroundColor Green
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Push-Location (Join-Path $PSScriptRoot "infra-terraform")
try {
    terraform output
}
finally {
    Pop-Location
}

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
