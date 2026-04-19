<#
.SYNOPSIS
    Build, push, and deploy the Agent Webapp Container App.

.DESCRIPTION
    1. Build the Docker image for agent-webapp
    2. Push to ACR (reuses the existing MCP ACR)
    3. Update the Container App revision

.PARAMETER AcrName
    Name of the Azure Container Registry

.PARAMETER ResourceGroup
    Name of the resource group

.PARAMETER ContainerAppName
    Name of the Container App

.EXAMPLE
    .\deploy-agent-webapp.ps1 -AcrName "acrdtmcpk71j" -ResourceGroup "rg-hybrid-agent" -ContainerAppName "agentappk71j-app"
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$AcrName = "",

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroup = "rg-hybrid-agent",

    [Parameter(Mandatory = $false)]
    [string]$ContainerAppName = ""
)

$ErrorActionPreference = "Stop"
$ROOT = Split-Path -Parent $PSScriptRoot

# ─── Auto-detect from Terraform if not provided ─────────────────────────────
Push-Location "$ROOT/infra-terraform"

if (-not $AcrName) {
    $AcrName = terraform output -raw datetime_mcp_acr_name 2>$null
    if (-not $AcrName) {
        Write-Error "Cannot determine ACR name. Pass -AcrName or run terraform apply first."
        Pop-Location
        exit 1
    }
}
if (-not $ContainerAppName) {
    $ContainerAppName = terraform output -raw agent_webapp_fqdn 2>$null
    # Extract app name: e.g. agentappk71j-app
    $ContainerAppName = (terraform output -json | ConvertFrom-Json).agent_webapp_fqdn.value -replace '\..*', ''
    if (-not $ContainerAppName) {
        $ContainerAppName = "agentapp-app"
    }
}

Pop-Location

$AcrLoginServer = "$AcrName.azurecr.io"
$ImageName = "agent-webapp"
$Tag = "latest"

Write-Host "`n=== Deploy Agent Webapp ===" -ForegroundColor Cyan

# ─── Step 1: Login to ACR ───────────────────────────────────────────────────
Write-Host "`n[1/4] Logging in to ACR $AcrName..." -ForegroundColor Yellow
az acr login --name $AcrName

# ─── Step 2: Build Docker image ─────────────────────────────────────────────
Write-Host "`n[2/4] Building Docker image..." -ForegroundColor Yellow
Push-Location "$ROOT/agent-webapp"
docker build -t "${AcrLoginServer}/${ImageName}:${Tag}" .
Pop-Location

# ─── Step 3: Push to ACR ────────────────────────────────────────────────────
Write-Host "`n[3/4] Pushing to ACR..." -ForegroundColor Yellow
docker push "${AcrLoginServer}/${ImageName}:${Tag}"

# ─── Step 4: Update Container App ───────────────────────────────────────────
Write-Host "`n[4/4] Updating Container App $ContainerAppName..." -ForegroundColor Yellow
az containerapp update `
    --name $ContainerAppName `
    --resource-group $ResourceGroup `
    --image "${AcrLoginServer}/${ImageName}:${Tag}"

Write-Host "`n=== Agent Webapp Deployed ===" -ForegroundColor Cyan

# Show messaging endpoint
$fqdn = az containerapp show --name $ContainerAppName --resource-group $ResourceGroup --query "properties.configuration.ingress.fqdn" -o tsv
Write-Host "Messaging endpoint: https://$fqdn/api/messages" -ForegroundColor Green
