<#
.SYNOPSIS
    Add VNet Integration to an existing App Service (e.g., created by A365).

.DESCRIPTION
    If A365 created an App Service with needDeployment: true, this script
    adds VNet Integration so it can reach the VNet-internal MCP server and
    private endpoint resources.

    Uses the func-integration-subnet which is delegated to Microsoft.Web/serverFarms.

.PARAMETER AppServiceName
    Name of the App Service to integrate

.PARAMETER ResourceGroup
    Resource group name

.PARAMETER VNetName
    VNet name

.PARAMETER SubnetName
    Subnet name (must be delegated to Microsoft.Web/serverFarms)

.EXAMPLE
    .\add-vnet-integration.ps1 -AppServiceName "my-a365-app" -ResourceGroup "rg-hybrid-agent"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$AppServiceName,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroup = "rg-hybrid-agent",

    [Parameter(Mandatory = $false)]
    [string]$VNetName = "agent-vnet",

    [Parameter(Mandatory = $false)]
    [string]$SubnetName = "func-integration-subnet"
)

$ErrorActionPreference = "Stop"

Write-Host "`n=== Add VNet Integration ===" -ForegroundColor Cyan

# Get subscription ID
$subId = az account show --query "id" -o tsv

# Build the subnet resource ID
$subnetId = "/subscriptions/$subId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/virtualNetworks/$VNetName/subnets/$SubnetName"

Write-Host "App Service: $AppServiceName" -ForegroundColor Yellow
Write-Host "Subnet: $subnetId" -ForegroundColor Yellow

# Add VNet integration
Write-Host "`nAdding VNet Integration..." -ForegroundColor Yellow
az webapp vnet-integration add `
    --name $AppServiceName `
    --resource-group $ResourceGroup `
    --subnet $subnetId

Write-Host "`nVNet Integration added successfully!" -ForegroundColor Green

# Configure route-all traffic through VNet
Write-Host "Configuring WEBSITE_VNET_ROUTE_ALL=1..." -ForegroundColor Yellow
az webapp config appsettings set `
    --name $AppServiceName `
    --resource-group $ResourceGroup `
    --settings WEBSITE_VNET_ROUTE_ALL=1

Write-Host "`n=== VNet Integration Complete ===" -ForegroundColor Cyan
Write-Host "The App Service can now reach VNet-internal resources (MCP server, private endpoints)."
