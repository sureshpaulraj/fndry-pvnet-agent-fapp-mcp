"""Tool execution layer — shared by both the original agent and the A365 web service.

Calls the Weather Function (Azure Function + EasyAuth) and DateTime MCP Server
(Container App on VNet) backends.
"""

import json
import requests
from azure.identity import DefaultAzureCredential

from config import WEATHER_BASE_URL, WEATHER_AUTH_CLIENT_ID, MCP_BASE_URL

credential = DefaultAzureCredential()


def _get_weather_headers() -> dict:
    token = credential.get_token(f"{WEATHER_AUTH_CLIENT_ID}/.default")
    return {"Authorization": f"Bearer {token.token}"}


def call_weather(endpoint: str, params: dict) -> str:
    url = f"{WEATHER_BASE_URL}/api/{endpoint}"
    try:
        resp = requests.get(
            url, params=params, headers=_get_weather_headers(), timeout=15
        )
        resp.raise_for_status()
        return json.dumps(resp.json())
    except requests.RequestException as e:
        return json.dumps({"error": str(e)})


def call_mcp(tool_name: str, arguments: dict) -> str:
    payload = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {"name": tool_name, "arguments": arguments},
    }
    try:
        resp = requests.post(
            f"{MCP_BASE_URL}/mcp",
            json=payload,
            headers={"Content-Type": "application/json"},
            timeout=15,
        )
        resp.raise_for_status()
        result = resp.json()
        if "result" in result and "content" in result["result"]:
            return "\n".join(
                c["text"]
                for c in result["result"]["content"]
                if c.get("type") == "text"
            )
        if "error" in result:
            return json.dumps(result["error"])
        return json.dumps(result)
    except requests.RequestException as e:
        return json.dumps({"error": str(e)})


def execute_tool(name: str, arguments: dict) -> str:
    if name == "get_weather":
        return call_weather("weather", arguments)
    elif name == "get_weather_forecast":
        return call_weather("weather/forecast", arguments)
    elif name in (
        "get_current_time",
        "get_date_info",
        "convert_timezone",
        "time_difference",
    ):
        return call_mcp(name, arguments)
    else:
        return json.dumps({"error": f"Unknown tool: {name}"})
