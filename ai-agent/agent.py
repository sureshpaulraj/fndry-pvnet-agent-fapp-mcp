# AI Agent Orchestration
#
# Hybrid-network agent that uses gpt-4o-mini with two tool backends:
#   1. Weather Function (Azure Function behind VNet) — HTTP REST calls
#   2. DateTime MCP Server (Container App on VNet) — MCP JSON-RPC calls
#
# Authentication: DefaultAzureCredential (managed identity in Azure, az login locally)
# No API keys — disableLocalAuth = true on the AI Services account.

import json
import os
import sys
import requests
from openai import AzureOpenAI
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from dotenv import load_dotenv

# ─── Configuration ───────────────────────────────────────────────────────────

load_dotenv(os.path.join(os.path.dirname(__file__), "..", ".env"))

AZURE_ENDPOINT = os.getenv(
    "AZURE_OPENAI_ENDPOINT",
    "https://aiservicesk71j.cognitiveservices.azure.com/",
)
MODEL_DEPLOYMENT = os.getenv("MODEL_DEPLOYMENT", "gpt-4o-mini")

# Tool backends — override with env vars for local vs. Azure
WEATHER_BASE_URL = os.getenv(
    "WEATHER_BASE_URL",
    "https://weatherk71j-func.azurewebsites.net",
)
MCP_BASE_URL = os.getenv(
    "MCP_BASE_URL",
    "https://dtmcpk71j-app.niceriver-877b9fd9.eastus2.azurecontainerapps.io",
)
# The function app's EasyAuth client ID (used as the token audience)
WEATHER_AUTH_CLIENT_ID = os.getenv(
    "WEATHER_AUTH_CLIENT_ID",
    "dfe36927-3171-4c66-8370-26840f0ab080",
)

# ─── Azure OpenAI Client ────────────────────────────────────────────────────

credential = DefaultAzureCredential()
token_provider = get_bearer_token_provider(
    credential, "https://cognitiveservices.azure.com/.default"
)

client = AzureOpenAI(
    azure_endpoint=AZURE_ENDPOINT,
    azure_ad_token_provider=token_provider,
    api_version="2024-10-21",
)

# ─── Tool Definitions (OpenAI function-calling format) ───────────────────────

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "get_weather",
            "description": "Get the current weather for a city including temperature, condition, humidity, and wind speed.",
            "parameters": {
                "type": "object",
                "properties": {
                    "city": {
                        "type": "string",
                        "description": "City name (e.g., Seattle, Tokyo, London). Defaults to Seattle.",
                    }
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_weather_forecast",
            "description": "Get a multi-day weather forecast for a city.",
            "parameters": {
                "type": "object",
                "properties": {
                    "city": {
                        "type": "string",
                        "description": "City name. Defaults to Seattle.",
                    },
                    "days": {
                        "type": "integer",
                        "description": "Number of forecast days (1-7). Defaults to 3.",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_current_time",
            "description": "Get the current date and time, optionally in a specific timezone (e.g., PST, JST, UTC, EST).",
            "parameters": {
                "type": "object",
                "properties": {
                    "timezone": {
                        "type": "string",
                        "description": "Timezone abbreviation (e.g., UTC, PST, JST). Defaults to UTC.",
                    }
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_date_info",
            "description": "Get detailed information about a date: day of week, week number, quarter, day of year, and whether it's a leap year.",
            "parameters": {
                "type": "object",
                "properties": {
                    "date": {
                        "type": "string",
                        "description": "Date in YYYY-MM-DD format. Defaults to today.",
                    }
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "convert_timezone",
            "description": "Convert a datetime string from one timezone to another.",
            "parameters": {
                "type": "object",
                "properties": {
                    "datetime_str": {
                        "type": "string",
                        "description": "Datetime in ISO 8601 format (e.g., 2025-01-15T14:30:00).",
                    },
                    "from_timezone": {
                        "type": "string",
                        "description": "Source timezone abbreviation (e.g., PST).",
                    },
                    "to_timezone": {
                        "type": "string",
                        "description": "Target timezone abbreviation (e.g., JST).",
                    },
                },
                "required": ["datetime_str", "from_timezone", "to_timezone"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "time_difference",
            "description": "Calculate the time difference between two datetime strings.",
            "parameters": {
                "type": "object",
                "properties": {
                    "datetime1": {
                        "type": "string",
                        "description": "First datetime in ISO 8601 format.",
                    },
                    "datetime2": {
                        "type": "string",
                        "description": "Second datetime in ISO 8601 format.",
                    },
                },
                "required": ["datetime1", "datetime2"],
            },
        },
    },
]

# ─── Tool Execution ─────────────────────────────────────────────────────────

def call_weather_function(endpoint: str, params: dict) -> str:
    """Call the Weather Azure Function via HTTP GET with AAD auth."""
    url = f"{WEATHER_BASE_URL}/api/{endpoint}"
    try:
        token = credential.get_token(f"{WEATHER_AUTH_CLIENT_ID}/.default")
        headers = {"Authorization": f"Bearer {token.token}"}
        resp = requests.get(url, params=params, headers=headers, timeout=15)
        resp.raise_for_status()
        return json.dumps(resp.json())
    except requests.RequestException as e:
        return json.dumps({"error": str(e)})


def call_mcp_tool(tool_name: str, arguments: dict) -> str:
    """Call the DateTime MCP server via JSON-RPC POST."""
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
            texts = [c["text"] for c in result["result"]["content"] if c.get("type") == "text"]
            return "\n".join(texts)
        if "error" in result:
            return json.dumps(result["error"])
        return json.dumps(result)
    except requests.RequestException as e:
        return json.dumps({"error": str(e)})


def execute_tool(name: str, arguments: dict) -> str:
    """Route a tool call to the appropriate backend."""
    if name == "get_weather":
        return call_weather_function("weather", arguments)
    elif name == "get_weather_forecast":
        return call_weather_function("weather/forecast", arguments)
    elif name in ("get_current_time", "get_date_info", "convert_timezone", "time_difference"):
        return call_mcp_tool(name, arguments)
    else:
        return json.dumps({"error": f"Unknown tool: {name}"})


# ─── Agent Loop ──────────────────────────────────────────────────────────────

SYSTEM_PROMPT = """You are a helpful assistant with access to real-time weather data and date/time utilities.

Available tools:
- get_weather: Current weather for any city
- get_weather_forecast: Multi-day forecast for any city
- get_current_time: Current time in any timezone
- get_date_info: Detailed info about any date
- convert_timezone: Convert times between timezones
- time_difference: Calculate duration between two datetimes

Use these tools to answer user questions accurately. When a user asks about weather or time, call the appropriate tool(s) rather than guessing."""


def run_agent(user_message: str, conversation: list | None = None) -> tuple[str, list]:
    """Run one turn of the agent loop. Returns (assistant_reply, updated_conversation)."""
    if conversation is None:
        conversation = [{"role": "system", "content": SYSTEM_PROMPT}]

    conversation.append({"role": "user", "content": user_message})

    # Allow up to 5 rounds of tool calls per turn
    for _ in range(5):
        response = client.chat.completions.create(
            model=MODEL_DEPLOYMENT,
            messages=conversation,
            tools=TOOLS,
            tool_choice="auto",
        )
        msg = response.choices[0].message

        # No tool calls → final answer
        if not msg.tool_calls:
            conversation.append({"role": "assistant", "content": msg.content})
            return msg.content, conversation

        # Process tool calls
        conversation.append(msg)
        for tc in msg.tool_calls:
            args = json.loads(tc.function.arguments)
            print(f"  [tool] {tc.function.name}({args})")
            result = execute_tool(tc.function.name, args)
            conversation.append(
                {
                    "role": "tool",
                    "tool_call_id": tc.id,
                    "content": result,
                }
            )

    # Fallback if tool-call loop exhausted
    return "I was unable to complete this request after multiple attempts.", conversation


# ─── Interactive CLI ─────────────────────────────────────────────────────────

def main():
    print("Hybrid Agent (gpt-4o-mini) — Weather + DateTime tools")
    print(f"  Weather backend : {WEATHER_BASE_URL}")
    print(f"  MCP backend     : {MCP_BASE_URL}")
    print(f"  AI endpoint     : {AZURE_ENDPOINT}")
    print("Type 'quit' or 'exit' to stop.\n")

    conversation = None
    while True:
        try:
            user_input = input("You: ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nGoodbye!")
            break
        if not user_input:
            continue
        if user_input.lower() in ("quit", "exit"):
            print("Goodbye!")
            break

        reply, conversation = run_agent(user_input, conversation)
        print(f"\nAssistant: {reply}\n")


if __name__ == "__main__":
    main()
