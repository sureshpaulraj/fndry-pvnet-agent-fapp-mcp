"""Tool execution layer — shared by both the original agent and the A365 web service.

Calls the Weather Function (Azure Function + EasyAuth) and DateTime MCP Server
(Container App on VNet) backends.
"""

import json
import logging
import requests
from azure.identity import DefaultAzureCredential
from opentelemetry import trace

from config import WEATHER_BASE_URL, WEATHER_AUTH_CLIENT_ID, MCP_BASE_URL

logger = logging.getLogger("agent-webapp")
tracer = trace.get_tracer("agent-webapp.tools")

credential = DefaultAzureCredential()


def _get_weather_headers() -> dict:
    import time as _t
    with tracer.start_as_current_span("get_weather_token") as span:
        span.set_attribute("auth.audience", f"{WEATHER_AUTH_CLIENT_ID}/.default")
        print(f"[DIAG] Acquiring weather token for audience: {WEATHER_AUTH_CLIENT_ID}/.default", flush=True)
        t0 = _t.time()
        try:
            token = credential.get_token(f"{WEATHER_AUTH_CLIENT_ID}/.default")
            elapsed = _t.time() - t0
            span.set_attribute("auth.elapsed_s", elapsed)
            print(f"[DIAG] Weather token acquired in {elapsed:.2f}s, first 20 chars: {token.token[:20]}...", flush=True)
            return {"Authorization": f"Bearer {token.token}"}
        except Exception as e:
            elapsed = _t.time() - t0
            span.set_attribute("auth.elapsed_s", elapsed)
            span.record_exception(e)
            span.set_status(trace.StatusCode.ERROR, str(e))
            print(f"[DIAG] Weather token FAILED in {elapsed:.2f}s: {type(e).__name__}: {e}", flush=True)
            raise


def call_weather(endpoint: str, params: dict) -> str:
    import time as _t
    url = f"{WEATHER_BASE_URL}/api/{endpoint}"
    with tracer.start_as_current_span("call_weather") as span:
        span.set_attribute("http.url", url)
        span.set_attribute("weather.params", json.dumps(params))
        print(f"[DIAG] Calling weather: {url} params={params}", flush=True)
        try:
            t0 = _t.time()
            headers = _get_weather_headers()
            t1 = _t.time()
            print(f"[DIAG] Headers ready in {t1-t0:.2f}s, sending GET...", flush=True)
            resp = requests.get(url, params=params, headers=headers, timeout=15)
            t2 = _t.time()
            span.set_attribute("http.status_code", resp.status_code)
            span.set_attribute("http.response_size", len(resp.content))
            print(f"[DIAG] Weather response: status={resp.status_code} len={len(resp.content)} in {t2-t1:.2f}s", flush=True)
            if not resp.ok:
                print(f"[DIAG] Weather error body: {resp.text[:500]}", flush=True)
            resp.raise_for_status()
            return json.dumps(resp.json())
        except requests.RequestException as e:
            span.record_exception(e)
            span.set_status(trace.StatusCode.ERROR, str(e))
            print(f"[DIAG] Weather call FAILED: {type(e).__name__}: {e}", flush=True)
            return json.dumps({"error": str(e)})


def call_mcp(tool_name: str, arguments: dict) -> str:
    with tracer.start_as_current_span("call_mcp") as span:
        span.set_attribute("mcp.tool_name", tool_name)
        span.set_attribute("mcp.arguments", json.dumps(arguments))
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
            span.record_exception(e)
            span.set_status(trace.StatusCode.ERROR, str(e))
            return json.dumps({"error": str(e)})


def execute_tool(name: str, arguments: dict) -> str:
    with tracer.start_as_current_span("execute_tool") as span:
        span.set_attribute("tool.name", name)
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
