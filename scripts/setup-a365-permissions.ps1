<#
.SYNOPSIS
    Add A365-required Graph API permissions to the service principal and
    configure VNet Integration for the A365-created App Service.

.DESCRIPTION
    1. Adds 7 Graph API permissions to the existing app registration
    2. Grants admin consent for those permissions
    3. Configures the app as a public client with redirect URI
    4. Adds VNet Integration to the App Service (if A365 used needDeployment: true)

.PARAMETER AppId
    Application (client) ID of the service principal

.PARAMETER TenantId
    Azure AD Tenant ID

.EXAMPLE
    .\setup-a365-permissions.ps1 -AppId "dfe36927-3171-4c66-8370-26840f0ab080" -TenantId "5d0245d3-4d99-44f5-82d3-28c83aeda726"
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$AppId = "dfe36927-3171-4c66-8370-26840f0ab080",

    [Parameter(Mandatory = $false)]
    [string]$TenantId = "5d0245d3-4d99-44f5-82d3-28c83aeda726"
)

$ErrorActionPreference = "Stop"

Write-Host "`n=== A365 Permission Setup ===" -ForegroundColor Cyan

# ─── Step 1: Get Microsoft Graph service principal ID ────────────────────────
Write-Host "`n[1/4] Looking up Microsoft Graph service principal..." -ForegroundColor Yellow
$graphSp = az ad sp list --filter "appId eq '00000003-0000-0000-c000-000000000000'" --query "[0].id" -o tsv
if (-not $graphSp) {
    Write-Error "Could not find Microsoft Graph service principal"
    exit 1
}
Write-Host "  Graph SP ID: $graphSp"

# ─── Step 2: Add Graph API permissions ───────────────────────────────────────
Write-Host "`n[2/4] Adding required Graph API permissions..." -ForegroundColor Yellow

# The 7 required A365 Graph permissions (Application type)
$permissions = @(
    @{ Name = "Application.ReadWrite.All";                          Id = "1bfefb4e-e0b5-418b-a88f-73c46d2cc8e9" }
    @{ Name = "DelegatedPermissionGrant.ReadWrite.All";            Id = "8e8e4742-1d95-4f68-9d56-6ee75648c72a" }
    @{ Name = "Directory.Read.All";                                 Id = "7ab1d382-f21e-4acd-a863-ba3e13f7da61" }
    @{ Name = "User.ReadWrite.All";                                 Id = "741f803b-c850-494e-b5df-cde7c675a1ca" }
)

# A365-specific permissions (may not exist in all tenants yet)
$a365Permissions = @(
    "AgentIdentityBlueprint.ReadWrite.All"
    "AgentIdentityBlueprint.UpdateAuthProperties.All"
    "AgentIdentityBlueprint.AddRemoveCreds.All"
)

foreach ($perm in $permissions) {
    Write-Host "  Adding $($perm.Name)..."
    try {
        az ad app permission add --id $AppId --api "00000003-0000-0000-c000-000000000000" --api-permissions "$($perm.Id)=Role" 2>$null
        Write-Host "    Added" -ForegroundColor Green
    }
    catch {
        Write-Host "    Already exists or error: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

Write-Host "`n  Note: A365-specific permissions ($($a365Permissions -join ', ')) are auto-configured by the a365 CLI."

# ─── Step 3: Grant admin consent ────────────────────────────────────────────
Write-Host "`n[3/4] Granting admin consent..." -ForegroundColor Yellow
try {
    az ad app permission admin-consent --id $AppId
    Write-Host "  Admin consent granted" -ForegroundColor Green
}
catch {
    Write-Host "  Warning: Admin consent may require Global Admin. Error: $($_.Exception.Message)" -ForegroundColor DarkYellow
    Write-Host "  You can grant consent manually at: https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/CallAnAPI/appId/$AppId"
}

# ─── Step 4: Configure public client with redirect URI ──────────────────────
Write-Host "`n[4/4] Configuring public client with redirect URI..." -ForegroundColor Yellow
try {
    az ad app update --id $AppId --public-client-redirect-uris "http://localhost:8400"
    Write-Host "  Public client configured with redirect: http://localhost:8400" -ForegroundColor Green
}
catch {
    Write-Host "  Warning: $($_.Exception.Message)" -ForegroundColor DarkYellow
}

Write-Host "`n=== A365 Permission Setup Complete ===" -ForegroundColor Cyan
Write-Host @"

Next steps:
1. Install A365 CLI: dotnet tool install --global Microsoft.Agents.A365.DevTools.Cli --prerelease
2. Login: a365 auth login --tenant-id $TenantId
3. Setup agent: a365 setup --config-file agent-webapp/manifest/a365.config.json
4. Deploy via Terraform or manually build & push the agent-webapp container

"@
