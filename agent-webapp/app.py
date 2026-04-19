"""Agent 365 Web Service — FastAPI app that handles Bot Framework Activities.

Endpoints:
  POST /api/messages  — receives Activities from M365 (Teams, Outlook, etc.)
  GET  /healthz       — health check for Container App probes
  GET  /              — service info
"""

import hmac
import json
import logging
import os
import time

import httpx
from fastapi import FastAPI, Request, Response

from bot import process_message
from config import BOT_APP_ID, BOT_APP_SECRET, BOT_TENANT_ID

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger("agent-webapp")

app = FastAPI(title="PCE Agent — A365 Web Service", version="1.0.0")

# ─── Health / Info ───────────────────────────────────────────────────────────


@app.get("/healthz")
async def healthz():
    return {"status": "ok", "agent": "pce", "framework": "a365"}


@app.get("/")
async def root():
    return {
        "service": "PCE Agent — A365 Web Service",
        "version": "1.0.0",
        "endpoints": ["/api/messages", "/healthz"],
    }


# ─── Bot Connector helpers ──────────────────────────────────────────────────

_token_cache: dict = {"token": None, "expires_at": 0}


async def _get_bot_token() -> str:
    """Get an OAuth token for the Bot Connector service."""
    now = time.time()
    if _token_cache["token"] and _token_cache["expires_at"] > now + 60:
        return _token_cache["token"]

    async with httpx.AsyncClient() as client:
        resp = await client.post(
            f"https://login.microsoftonline.com/{BOT_TENANT_ID}/oauth2/v2.0/token",
            data={
                "grant_type": "client_credentials",
                "client_id": BOT_APP_ID,
                "client_secret": BOT_APP_SECRET,
                "scope": "https://api.botframework.com/.default",
            },
            timeout=15,
        )
        resp.raise_for_status()
        data = resp.json()

    _token_cache["token"] = data["access_token"]
    _token_cache["expires_at"] = now + data.get("expires_in", 3600)
    return data["access_token"]


async def _send_activity(service_url: str, conversation_id: str, activity: dict):
    """Send a reply Activity back via the Bot Connector REST API."""
    url = (
        f"{service_url.rstrip('/')}/v3/conversations/"
        f"{conversation_id}/activities"
    )
    token = await _get_bot_token()
    async with httpx.AsyncClient() as client:
        resp = await client.post(
            url,
            json=activity,
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
            timeout=120,
        )
        if resp.status_code >= 400:
            logger.error(
                "Bot Connector error %s: %s", resp.status_code, resp.text
            )


# ─── Main messaging endpoint ────────────────────────────────────────────────


@app.post("/api/messages")
async def messages(request: Request):
    """Handle incoming Bot Framework Activities from M365."""
    body = await request.json()
    activity_type = body.get("type", "")

    if activity_type == "message":
        user_text = body.get("text", "").strip()
        if not user_text:
            return Response(status_code=200)

        logger.info("Received message: %s", user_text[:100])

        # Process through Foundry agent (synchronous — runs in threadpool)
        import asyncio

        reply_text = await asyncio.to_thread(process_message, user_text)

        # Build reply activity
        reply_activity = {
            "type": "message",
            "from": body.get("recipient"),
            "recipient": body.get("from"),
            "replyToId": body.get("id"),
            "text": reply_text,
        }

        service_url = body.get("serviceUrl", "")
        conversation_id = body.get("conversation", {}).get("id", "")

        if service_url and conversation_id:
            await _send_activity(service_url, conversation_id, reply_activity)
        else:
            logger.warning("No serviceUrl/conversationId — returning inline")
            return reply_activity

    elif activity_type == "conversationUpdate":
        members_added = body.get("membersAdded", [])
        bot_id = body.get("recipient", {}).get("id", "")
        for member in members_added:
            if member.get("id") != bot_id:
                welcome = {
                    "type": "message",
                    "from": body.get("recipient"),
                    "recipient": member,
                    "text": (
                        "Hello! I'm the PCE Agent. I can help with weather "
                        "information and date/time queries. Try asking:\n"
                        "- What's the weather in Seattle?\n"
                        "- What time is it in Tokyo?\n"
                        "- What's the forecast for London?"
                    ),
                }
                service_url = body.get("serviceUrl", "")
                conversation_id = body.get("conversation", {}).get("id", "")
                if service_url and conversation_id:
                    await _send_activity(
                        service_url, conversation_id, welcome
                    )

    return Response(status_code=200)


# ─── Run with uvicorn ────────────────────────────────────────────────────────

if __name__ == "__main__":
    import uvicorn

    port = int(os.getenv("PORT", "8080"))
    uvicorn.run(app, host="0.0.0.0", port=port)
