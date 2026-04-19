# Foundry Agent Client
#
# Uses the Azure AI Agent Service (Assistants API) with the deployed "pce" agent.
# The client handles function calls by making HTTP requests to tool backends
# running inside the VNet.
#
# Architecture:
#   Client (jump VM) → Foundry Agent (cloud) → requires_action →
#   Client calls Weather Function / MCP Server via VNet → submits results → Agent responds
#
# Usage:
#   python foundry_agent.py                  # Interactive mode
#   python foundry_agent.py "What's the weather in Seattle?"  # Single query

import json
import os
import sys
import time
import requests
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(__file__), "..", ".env"))

# ─── Configuration ───────────────────────────────────────────────────────────

FOUNDRY_ENDPOINT = os.getenv(
    "FOUNDRY_ENDPOINT",
    "https://aiservicesk71j.services.ai.azure.com/api/projects/projectk71j",
)
AGENT_ID = os.getenv("AGENT_ID", "asst_fAVIpp16oVnfHaBuCo1BtvJ9")
API_VERSION = os.getenv("AGENT_API_VERSION", "v1")

WEATHER_BASE_URL = os.getenv(
    "WEATHER_BASE_URL",
    "https://weatherk71j-func.azurewebsites.net",
)
# The function app's EasyAuth client ID (used as the token audience)
WEATHER_AUTH_CLIENT_ID = os.getenv(
    "WEATHER_AUTH_CLIENT_ID",
    "dfe36927-3171-4c66-8370-26840f0ab080",
)
MCP_BASE_URL = os.getenv(
    "MCP_BASE_URL",
    "https://dtmcpk71j-app.niceriver-877b9fd9.eastus2.azurecontainerapps.io",
)

# ─── Auth ────────────────────────────────────────────────────────────────────

credential = DefaultAzureCredential()


def _get_headers() -> dict:
    token = credential.get_token("https://ai.azure.com/.default")
    return {
        "Authorization": f"Bearer {token.token}",
        "Content-Type": "application/json",
    }


def _api(method: str, path: str, body: dict | None = None) -> dict:
    url = f"{FOUNDRY_ENDPOINT}/{path}?api-version={API_VERSION}"
    resp = requests.request(method, url, headers=_get_headers(), json=body, timeout=60)
    resp.raise_for_status()
    return resp.json() if resp.content else {}


# ─── Tool Execution (same backends as agent.py) ─────────────────────────────

def _get_weather_headers() -> dict:
    token = credential.get_token(f"{WEATHER_AUTH_CLIENT_ID}/.default")
    return {"Authorization": f"Bearer {token.token}"}


def call_weather(endpoint: str, params: dict) -> str:
    url = f"{WEATHER_BASE_URL}/api/{endpoint}"
    try:
        resp = requests.get(url, params=params, headers=_get_weather_headers(), timeout=15)
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
                c["text"] for c in result["result"]["content"] if c.get("type") == "text"
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
    elif name in ("get_current_time", "get_date_info", "convert_timezone", "time_difference"):
        return call_mcp(name, arguments)
    else:
        return json.dumps({"error": f"Unknown tool: {name}"})


# ─── Assistants API helpers ──────────────────────────────────────────────────

def create_thread() -> str:
    result = _api("POST", "threads")
    return result["id"]


def add_message(thread_id: str, content: str) -> None:
    _api("POST", f"threads/{thread_id}/messages", {"role": "user", "content": content})


def create_run(thread_id: str) -> str:
    result = _api("POST", f"threads/{thread_id}/runs", {"assistant_id": AGENT_ID})
    return result["id"]


def get_run(thread_id: str, run_id: str) -> dict:
    return _api("GET", f"threads/{thread_id}/runs/{run_id}")


def submit_tool_outputs(thread_id: str, run_id: str, outputs: list) -> None:
    _api(
        "POST",
        f"threads/{thread_id}/runs/{run_id}/submit_tool_outputs",
        {"tool_outputs": outputs},
    )


def get_messages(thread_id: str) -> list:
    result = _api("GET", f"threads/{thread_id}/messages")
    return result.get("data", [])


# ─── Agent Run Loop ─────────────────────────────────────────────────────────

def run_agent_turn(thread_id: str, user_message: str) -> str:
    add_message(thread_id, user_message)
    run_id = create_run(thread_id)

    for _ in range(30):  # max ~60s of polling
        run = get_run(thread_id, run_id)
        status = run["status"]

        if status == "completed":
            messages = get_messages(thread_id)
            # First message is the latest assistant response
            for msg in messages:
                if msg["role"] == "assistant":
                    texts = []
                    for block in msg.get("content", []):
                        if block.get("type") == "text":
                            texts.append(block["text"]["value"])
                    if texts:
                        return "\n".join(texts)
            return "(no response)"

        elif status == "requires_action":
            tool_calls = run["required_action"]["submit_tool_outputs"]["tool_calls"]
            outputs = []
            for tc in tool_calls:
                args = json.loads(tc["function"]["arguments"])
                print(f"  [tool] {tc['function']['name']}({args})")
                result = execute_tool(tc["function"]["name"], args)
                outputs.append({"tool_call_id": tc["id"], "output": result})
            submit_tool_outputs(thread_id, run_id, outputs)

        elif status in ("failed", "cancelled", "expired"):
            error = run.get("last_error", {}).get("message", status)
            return f"Run {status}: {error}"

        else:
            time.sleep(2)

    return "Run timed out."


# ─── Interactive CLI ─────────────────────────────────────────────────────────

def main():
    print("Foundry Agent (pce) — Weather + DateTime tools")
    print(f"  Agent ID        : {AGENT_ID}")
    print(f"  Foundry endpoint: {FOUNDRY_ENDPOINT}")
    print(f"  Weather backend : {WEATHER_BASE_URL}")
    print(f"  MCP backend     : {MCP_BASE_URL}")
    print("Type 'quit' or 'exit' to stop.\n")

    # Single-query mode
    if len(sys.argv) > 1:
        query = " ".join(sys.argv[1:])
        thread_id = create_thread()
        print(f"Thread: {thread_id}")
        reply = run_agent_turn(thread_id, query)
        print(f"\nAssistant: {reply}")
        return

    # Interactive mode
    thread_id = create_thread()
    print(f"Thread: {thread_id}\n")

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

        reply = run_agent_turn(thread_id, user_input)
        print(f"\nAssistant: {reply}\n")


if __name__ == "__main__":
    main()
