"""Bot handler — processes incoming Activities using the Foundry Assistants API.

Receives user messages from A365/Teams, creates a Foundry thread+run,
handles tool calls via the VNet-connected backends, and returns the
assistant's response.
"""

import json
import logging
import time
import requests
from azure.identity import DefaultAzureCredential

from config import FOUNDRY_ENDPOINT, AGENT_ID, API_VERSION
from tools import execute_tool

logger = logging.getLogger(__name__)

credential = DefaultAzureCredential()


def _get_headers() -> dict:
    token = credential.get_token("https://ai.azure.com/.default")
    logger.info("Token acquired, first 20 chars: %s...", token.token[:20])
    return {
        "Authorization": f"Bearer {token.token}",
        "Content-Type": "application/json",
    }


def _api(method: str, path: str, body: dict | None = None) -> dict:
    url = f"{FOUNDRY_ENDPOINT}/{path}?api-version={API_VERSION}"
    resp = requests.request(
        method, url, headers=_get_headers(), json=body, timeout=60
    )
    if not resp.ok:
        logger.error("API %s %s → %s: %s", method, url, resp.status_code, resp.text)
        raise RuntimeError(f"{resp.status_code} {method} {path}: {resp.text[:500]}")
    return resp.json() if resp.content else {}


def process_message(user_text: str) -> str:
    """Run one full Foundry agent turn and return the assistant's reply."""
    try:
        return _run_agent(user_text)
    except Exception as exc:
        logger.exception("process_message failed")
        return f"Error: {exc}"


def _run_agent(user_text: str) -> str:
    """Inner implementation that may raise."""
    thread = _api("POST", "threads")
    thread_id = thread["id"]

    _api(
        "POST",
        f"threads/{thread_id}/messages",
        {"role": "user", "content": user_text},
    )
    run = _api(
        "POST",
        f"threads/{thread_id}/runs",
        {"assistant_id": AGENT_ID},
    )
    run_id = run["id"]

    for _ in range(30):  # ~60 s max polling
        run = _api("GET", f"threads/{thread_id}/runs/{run_id}")
        status = run["status"]

        if status == "completed":
            msgs = _api("GET", f"threads/{thread_id}/messages").get("data", [])
            for msg in msgs:
                if msg["role"] == "assistant":
                    texts = [
                        b["text"]["value"]
                        for b in msg.get("content", [])
                        if b.get("type") == "text"
                    ]
                    if texts:
                        return "\n".join(texts)
            return "(no response)"

        elif status == "requires_action":
            tool_calls = run["required_action"]["submit_tool_outputs"][
                "tool_calls"
            ]
            outputs = []
            for tc in tool_calls:
                args = json.loads(tc["function"]["arguments"])
                print(f"[DIAG] tool call: {tc['function']['name']}({args})", flush=True)
                logger.info("tool call: %s(%s)", tc["function"]["name"], args)
                result = execute_tool(tc["function"]["name"], args)
                print(f"[DIAG] tool result: {result[:200]}", flush=True)
                outputs.append({"tool_call_id": tc["id"], "output": result})
            _api(
                "POST",
                f"threads/{thread_id}/runs/{run_id}/submit_tool_outputs",
                {"tool_outputs": outputs},
            )

        elif status in ("failed", "cancelled", "expired"):
            error = run.get("last_error", {}).get("message", status)
            return f"Run {status}: {error}"

        else:
            time.sleep(2)

    return "Run timed out."
