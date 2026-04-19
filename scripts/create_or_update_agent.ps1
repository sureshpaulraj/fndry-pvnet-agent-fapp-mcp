<#
.SYNOPSIS
    Idempotent bootstrap: creates or updates the Foundry agent "pce" via REST API.
    Authenticates as the service principal (idp4functionapp).

.DESCRIPTION
    Terraform cannot manage Foundry agents (data-plane only).
    This script:
      1. Authenticates the SP and acquires a Cognitive Services token
      2. Ensures the SP has Cognitive Services User on the AI account
      3. Creates or updates the agent with gpt-4.1-mini and queue-based weather tool

.PARAMETER ClientId
    Application (client) ID of the service principal.

.PARAMETER ClientSecret
    Client secret value. Prefer passing via env var AZURE_CLIENT_SECRET.

.PARAMETER TenantId
    Azure AD tenant ID.

.PARAMETER AccountEndpoint
    AI Services account endpoint (e.g. https://aiservicesk71j.cognitiveservices.azure.com/).

.PARAMETER ModelDeploymentName
    Name of the model deployment to use (default: gpt-4.1-mini).

.PARAMETER AgentName
    Display name for the agent (default: pce).

.PARAMETER QueueStorageAccountName
    Storage account name hosting the tool queues.

.PARAMETER ResourceGroupName
    Resource group containing the AI account.

.PARAMETER AccountName
    AI Services account name (for RBAC scope).

.PARAMETER SubscriptionId
    Azure subscription ID.

.PARAMETER SpObjectId
    Service principal object ID (for RBAC assignment).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ClientId = $env:AZURE_CLIENT_ID,

    [Parameter(Mandatory=$false)]
    [string]$ClientSecret = $env:AZURE_CLIENT_SECRET,

    [Parameter(Mandatory=$false)]
    [string]$TenantId = $env:AZURE_TENANT_ID,

    [string]$AccountEndpoint,
    [string]$ProjectName = "projectk71j",
    [string]$ModelDeploymentName = "gpt-4.1-mini",
    [string]$AgentName = "pce",
    [string]$QueueStorageAccountName,
    [string]$ResourceGroupName = "rg-hybrid-agent",
    [string]$AccountName,
    [string]$SubscriptionId,
    [string]$SpObjectId
)

$ErrorActionPreference = "Stop"

# ─── Validate required params ─────────────────────────────────────────────────
if (-not $ClientId)       { throw "ClientId is required. Set AZURE_CLIENT_ID env var or pass -ClientId." }
if (-not $ClientSecret)   { throw "ClientSecret is required. Set AZURE_CLIENT_SECRET env var or pass -ClientSecret." }
if (-not $TenantId)       { throw "TenantId is required. Set AZURE_TENANT_ID env var or pass -TenantId." }
if (-not $AccountEndpoint){ throw "AccountEndpoint is required." }

# Normalize endpoint (remove trailing slash)
$AccountEndpoint = $AccountEndpoint.TrimEnd('/')

# Derive the AI Foundry services endpoint from the cog services endpoint
# aiservicesk71j.cognitiveservices.azure.com → aiservicesk71j.services.ai.azure.com
$accountHost = ([System.Uri]$AccountEndpoint).Host
$accountPrefix = $accountHost.Split('.')[0]
$FoundryEndpoint = "https://$accountPrefix.services.ai.azure.com/api/projects/$ProjectName"

Write-Host "=== Foundry Agent Bootstrap ===" -ForegroundColor Cyan
Write-Host "Tenant:     $TenantId"
Write-Host "Client:     $ClientId"
Write-Host "Endpoint:   $FoundryEndpoint"
Write-Host "Model:      $ModelDeploymentName"
Write-Host "Agent:      $AgentName"
Write-Host ""

# ─── Step 1: Authenticate SP → get Cognitive Services token ──────────────────
Write-Host "[1/4] Authenticating service principal..." -ForegroundColor Yellow

$tokenBody = @{
    grant_type    = "client_credentials"
    client_id     = $ClientId
    client_secret = $ClientSecret
    scope         = "https://ai.azure.com/.default"
}
$tokenResponse = Invoke-RestMethod -Method Post `
    -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
    -ContentType "application/x-www-form-urlencoded" `
    -Body $tokenBody

$accessToken = $tokenResponse.access_token
Write-Host "  Token acquired (expires in $($tokenResponse.expires_in)s)" -ForegroundColor Green

$headers = @{
    "Authorization" = "Bearer $accessToken"
    "Content-Type"  = "application/json"
}

# ─── Step 2: Ensure RBAC — Cognitive Services User for the SP ────────────────
if ($SpObjectId -and $SubscriptionId -and $AccountName) {
    Write-Host "[2/4] Checking RBAC (Cognitive Services User)..." -ForegroundColor Yellow

    # Login as SP for az cli RBAC commands
    az login --service-principal -u $ClientId -p $ClientSecret --tenant $TenantId --output none 2>$null
    az account set --subscription $SubscriptionId --output none

    $scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.CognitiveServices/accounts/$AccountName"
    $existingRole = az role assignment list --assignee $SpObjectId --scope $scope --role "Cognitive Services User" --query "[0].id" -o tsv 2>$null

    if (-not $existingRole) {
        Write-Host "  Assigning Cognitive Services User to SP..." -ForegroundColor Yellow
        az role assignment create --assignee-object-id $SpObjectId --assignee-principal-type ServicePrincipal `
            --role "Cognitive Services User" --scope $scope --output none
        Write-Host "  Role assigned. Waiting 30s for propagation..." -ForegroundColor Yellow
        Start-Sleep -Seconds 30
    } else {
        Write-Host "  RBAC already in place." -ForegroundColor Green
    }
} else {
    Write-Host "[2/4] Skipping RBAC check (SpObjectId/SubscriptionId/AccountName not provided)." -ForegroundColor DarkYellow
}

# ─── Step 3: List existing agents → check if "pce" exists ───────────────────
Write-Host "[3/4] Checking for existing agent '$AgentName'..." -ForegroundColor Yellow

$apiVersion = "v1"
$listUrl = "$FoundryEndpoint/assistants?api-version=$apiVersion"

try {
    $existingAgents = Invoke-RestMethod -Method Get -Uri $listUrl -Headers $headers
    $existing = $existingAgents.data | Where-Object { $_.name -eq $AgentName } | Select-Object -First 1
} catch {
    Write-Host "  Could not list agents (may not exist yet): $($_.Exception.Message)" -ForegroundColor DarkYellow
    $existing = $null
}

# ─── Step 4: Create or update the agent ──────────────────────────────────────
Write-Host "[4/4] Creating/updating agent..." -ForegroundColor Yellow

# Build the agent body with standard function tools
# The client code (running inside the VNet) handles HTTP calls to the weather function
$agentBody = @{
    name         = $AgentName
    model        = $ModelDeploymentName
    instructions = @"
You are PCE (Private Cloud Expert), an AI assistant with access to real-time weather data and date/time utilities.

When a user asks about weather:
1. Use the weather tool to get current conditions or forecasts
2. Present the data in a clear, conversational format
3. Include temperature, conditions, and any relevant details

When a user asks about time, dates, or timezones:
1. Use the appropriate date/time tool
2. Present the information clearly

You can:
- Get current weather for any city
- Get multi-day forecasts (up to 7 days)
- Get current time in any timezone
- Get date information (day of week, week number, etc.)
- Convert times between timezones
- Calculate time differences between two dates

Always be helpful, concise, and accurate.
"@
    tools = @(
        @{
            type = "function"
            function = @{
                name        = "get_weather"
                description = "Get current weather for a city. Returns temperature, conditions, humidity, and wind."
                parameters  = @{
                    type       = "object"
                    properties = @{
                        city = @{
                            type        = "string"
                            description = "City name (e.g., Seattle, Tokyo, London)"
                        }
                    }
                    required = @("city")
                }
            }
        },
        @{
            type = "function"
            function = @{
                name        = "get_weather_forecast"
                description = "Get a multi-day weather forecast for a city."
                parameters  = @{
                    type       = "object"
                    properties = @{
                        city = @{
                            type        = "string"
                            description = "City name (e.g., Seattle, Tokyo, London)"
                        }
                        days = @{
                            type        = "integer"
                            description = "Number of forecast days (1-7, default 3)"
                        }
                    }
                    required = @("city")
                }
            }
        },
        @{
            type = "function"
            function = @{
                name        = "get_current_time"
                description = "Get the current date and time, optionally in a specific timezone."
                parameters  = @{
                    type       = "object"
                    properties = @{
                        timezone = @{
                            type        = "string"
                            description = "IANA timezone name (e.g., America/New_York, Asia/Tokyo, Europe/London). Defaults to UTC."
                        }
                    }
                    required = @()
                }
            }
        },
        @{
            type = "function"
            function = @{
                name        = "get_date_info"
                description = "Get detailed information about a specific date (day of week, week number, day of year, etc.)."
                parameters  = @{
                    type       = "object"
                    properties = @{
                        date = @{
                            type        = "string"
                            description = "Date in YYYY-MM-DD format (defaults to today)"
                        }
                    }
                    required = @()
                }
            }
        },
        @{
            type = "function"
            function = @{
                name        = "convert_timezone"
                description = "Convert a time from one timezone to another."
                parameters  = @{
                    type       = "object"
                    properties = @{
                        time = @{
                            type        = "string"
                            description = "Time to convert in ISO 8601 format (e.g., 2024-01-15T10:30:00)"
                        }
                        from_timezone = @{
                            type        = "string"
                            description = "Source IANA timezone (e.g., America/New_York)"
                        }
                        to_timezone = @{
                            type        = "string"
                            description = "Target IANA timezone (e.g., Asia/Tokyo)"
                        }
                    }
                    required = @("time", "from_timezone", "to_timezone")
                }
            }
        },
        @{
            type = "function"
            function = @{
                name        = "time_difference"
                description = "Calculate the time difference between two dates/times."
                parameters  = @{
                    type       = "object"
                    properties = @{
                        start_time = @{
                            type        = "string"
                            description = "Start date/time in ISO 8601 format"
                        }
                        end_time = @{
                            type        = "string"
                            description = "End date/time in ISO 8601 format"
                        }
                    }
                    required = @("start_time", "end_time")
                }
            }
        }
    )
    temperature  = 0.7
    top_p        = 0.95
} | ConvertTo-Json -Depth 10

if ($existing) {
    $agentId = $existing.id
    Write-Host "  Agent exists (id=$agentId). Updating..." -ForegroundColor Yellow
    $updateUrl = "$FoundryEndpoint/assistants/$($agentId)?api-version=$apiVersion"
    $result = Invoke-RestMethod -Method Post -Uri $updateUrl -Headers $headers -Body $agentBody
    Write-Host "  Agent updated: $($result.id)" -ForegroundColor Green
} else {
    Write-Host "  Creating new agent..." -ForegroundColor Yellow
    $createUrl = "$FoundryEndpoint/assistants?api-version=$apiVersion"
    $result = Invoke-RestMethod -Method Post -Uri $createUrl -Headers $headers -Body $agentBody
    Write-Host "  Agent created: $($result.id)" -ForegroundColor Green
}

Write-Host ""
Write-Host "=== Bootstrap Complete ===" -ForegroundColor Cyan
Write-Host "Agent ID:    $($result.id)"
Write-Host "Agent Name:  $($result.name)"
Write-Host "Model:       $($result.model)"
Write-Host "Tools:       $($result.tools.Count) configured"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Test via Azure AI Foundry portal or REST API"
Write-Host "  2. Ensure the Weather Function has a queue trigger for 'weather-input'"
Write-Host "  3. Verify queue connectivity from Jump VM"
