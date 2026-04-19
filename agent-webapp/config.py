"""Configuration for the Agent 365 web service."""

import os
from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(__file__), "..", ".env"))

# ─── Foundry Agent ───────────────────────────────────────────────────────────
FOUNDRY_ENDPOINT = os.getenv(
    "FOUNDRY_ENDPOINT",
    "https://aiservicesk71j.services.ai.azure.com/api/projects/projectk71j",
)
AGENT_ID = os.getenv("AGENT_ID", "asst_fAVIpp16oVnfHaBuCo1BtvJ9")
API_VERSION = os.getenv("AGENT_API_VERSION", "v1")

# ─── Tool Backends ───────────────────────────────────────────────────────────
WEATHER_BASE_URL = os.getenv(
    "WEATHER_BASE_URL",
    "https://weatherk71j-func.azurewebsites.net",
)
WEATHER_AUTH_CLIENT_ID = os.getenv(
    "WEATHER_AUTH_CLIENT_ID",
    "dfe36927-3171-4c66-8370-26840f0ab080",
)
MCP_BASE_URL = os.getenv(
    "MCP_BASE_URL",
    "https://dtmcpk71j-app.niceriver-877b9fd9.eastus2.azurecontainerapps.io",
)

# ─── A365 Bot Framework ─────────────────────────────────────────────────────
# Blueprint App ID and secret created by a365 setup
BOT_APP_ID = os.getenv("BOT_APP_ID", "")
BOT_APP_SECRET = os.getenv("BOT_APP_SECRET", "")
BOT_TENANT_ID = os.getenv(
    "AZURE_TENANT_ID", "5d0245d3-4d99-44f5-82d3-28c83aeda726"
)
