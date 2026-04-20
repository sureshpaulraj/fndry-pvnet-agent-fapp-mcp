"""PCE Agent — v20 using Microsoft Agents SDK hosting + A365 Observability.

Uses the official Microsoft Agents SDK (same as Agent365-Samples) for:
  - Incoming activity deserialization and auth validation
  - Outgoing reply delivery via context.send_activity()
  - Token management via MsalConnectionManager
  - A365 Observability with BaggageBuilder + token exchange

Env vars required (set on Container App):
  CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTID
  CONNECTIONS__SERVICE_CONNECTION__SETTINGS__CLIENTSECRET
  CONNECTIONS__SERVICE_CONNECTION__SETTINGS__TENANTID
  CONNECTIONSMAP__0__SERVICEURL=*
  CONNECTIONSMAP__0__CONNECTION=SERVICE_CONNECTION
  AUTH_HANDLER_NAME=AGENTIC  (for observability token exchange)
"""

import asyncio
import logging
import os
from os import environ

from dotenv import load_dotenv

# ─── Azure Monitor (App Insights) — must be configured BEFORE other imports ──
load_dotenv(override=True)

_ai_conn_str = os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING", "")
if _ai_conn_str and _ai_conn_str != "placeholder":
    from azure.monitor.opentelemetry import configure_azure_monitor
    configure_azure_monitor(
        connection_string=_ai_conn_str,
        logger_name="agent-webapp",
        enable_live_metrics=True,
    )

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger("agent-webapp")

from aiohttp.web import Application, Request, Response, json_response, run_app
from microsoft_agents.activity import Activity, load_configuration_from_env
from microsoft_agents.authentication.msal import MsalConnectionManager
from microsoft_agents.hosting.aiohttp import CloudAdapter, start_agent_process
from microsoft_agents.hosting.core import (
    AgentApplication,
    Authorization,
    MemoryStorage,
    TurnContext,
    TurnState,
)

from bot import process_message
from token_cache import cache_agentic_token, get_cached_agentic_token

# Enable SDK debug logging
ms_agents_logger = logging.getLogger("microsoft_agents")
ms_agents_logger.addHandler(logging.StreamHandler())
ms_agents_logger.setLevel(logging.INFO)

# Observability imports — graceful fallback if packages not available
try:
    from microsoft_agents_a365.observability.core.config import configure as configure_observability
    from microsoft_agents_a365.observability.core.middleware.baggage_builder import BaggageBuilder
    from microsoft_agents_a365.runtime.environment_utils import get_observability_authentication_scope
    HAS_OBSERVABILITY = True
except ImportError as _obs_err:
    logger.warning("Observability import failed: %s", _obs_err)
    HAS_OBSERVABILITY = False

# ─── Microsoft Agents SDK Setup ─────────────────────────────────────────────

agents_sdk_config = load_configuration_from_env(environ)
logger.info("SDK config loaded, keys: %s", list(agents_sdk_config.keys()))

storage = MemoryStorage()
connection_manager = MsalConnectionManager(**agents_sdk_config)
adapter = CloudAdapter(connection_manager=connection_manager)
authorization = Authorization(storage, connection_manager, **agents_sdk_config)

AGENT_APP = AgentApplication[TurnState](
    storage=storage,
    adapter=adapter,
    authorization=authorization,
    **agents_sdk_config,
)

# Auth handler name for observability token exchange
AUTH_HANDLER_NAME = os.environ.get("AUTH_HANDLER_NAME") or None
if AUTH_HANDLER_NAME:
    logger.info("Auth handler configured: %s", AUTH_HANDLER_NAME)
else:
    logger.info("No AUTH_HANDLER_NAME set — observability token exchange disabled")

# ─── Observability Setup ────────────────────────────────────────────────────


def _token_resolver(agent_id: str, tenant_id: str) -> str | None:
    """Token resolver for A365 Observability exporter — uses cached agentic token."""
    try:
        cached = get_cached_agentic_token(tenant_id, agent_id)
        if cached:
            logger.debug("Observability token resolved for %s:%s", tenant_id[:8], agent_id[:8])
        else:
            logger.debug("No cached observability token for %s:%s", tenant_id[:8], agent_id[:8])
        return cached
    except Exception as exc:
        logger.error("Token resolver error: %s", exc)
        return None


if HAS_OBSERVABILITY:
    try:
        status = configure_observability(
            service_name=os.environ.get("OBSERVABILITY_SERVICE_NAME", "pce-agent"),
            service_namespace=os.environ.get("OBSERVABILITY_SERVICE_NAMESPACE", "hybrid-network"),
            token_resolver=_token_resolver,
        )
        if status:
            logger.info("A365 Observability configured successfully")
        else:
            logger.warning("A365 Observability configuration returned False")
    except Exception as exc:
        logger.warning("A365 Observability setup failed (non-fatal): %s", exc)
else:
    logger.info("A365 Observability packages not installed — skipping")


# ─── Activity Handlers ──────────────────────────────────────────────────────

@AGENT_APP.activity("message")
async def on_message(context: TurnContext, _: TurnState):
    """Handle all user messages — process via Foundry agent and reply."""
    user_text = (context.activity.text or "").strip()
    if not user_text:
        return

    from_prop = context.activity.from_property
    recipient = context.activity.recipient
    tenant_id = getattr(recipient, "tenant_id", None) if recipient else None
    agent_id = getattr(recipient, "agentic_app_id", None) if recipient else None

    logger.info(
        "Message from %s (%s): %s",
        getattr(from_prop, "name", "?"),
        getattr(from_prop, "id", "?")[:30] if from_prop else "?",
        user_text[:120],
    )

    # Exchange token for observability if auth handler is configured
    if AUTH_HANDLER_NAME and HAS_OBSERVABILITY and tenant_id and agent_id:
        try:
            exaau_token = await AGENT_APP.auth.exchange_token(
                context,
                scopes=get_observability_authentication_scope(),
                auth_handler_id=AUTH_HANDLER_NAME,
            )
            cache_agentic_token(tenant_id, agent_id, exaau_token.token)
            logger.info("Observability token exchanged and cached")
        except Exception as exc:
            logger.warning("Observability token exchange failed (non-fatal): %s", exc)

    # Wrap processing in BaggageBuilder context for observability tracing
    async def _process():
        # Send typing indicator
        await context.send_activity(Activity(type="typing"))

        try:
            reply_text = await asyncio.to_thread(process_message, user_text)
        except Exception as exc:
            logger.exception("process_message failed")
            reply_text = f"Sorry, I encountered an error: {exc}"

        logger.info("Reply (%d chars): %s", len(reply_text), reply_text[:200])
        await context.send_activity(reply_text)
        logger.info("Reply sent via Microsoft Agents SDK")

    if HAS_OBSERVABILITY and tenant_id and agent_id:
        with BaggageBuilder().tenant_id(tenant_id).agent_id(agent_id).build():
            await _process()
    else:
        await _process()


@AGENT_APP.activity("installationUpdate")
async def on_installation_update(context: TurnContext, _: TurnState):
    """Handle agent install/uninstall events."""
    action = context.activity.action
    logger.info("InstallationUpdate: action=%s", action)
    if action == "add":
        await context.send_activity(
            "Hello! I'm PCE Agent — I can help with weather, time, and more. "
            "Just send me a message!"
        )
    elif action == "remove":
        await context.send_activity("Goodbye! Thanks for using PCE Agent.")


# ─── HTTP Endpoints ─────────────────────────────────────────────────────────

async def entry_point(req: Request) -> Response:
    """Bot Framework messages endpoint — handled by Microsoft Agents SDK."""
    return await start_agent_process(req, AGENT_APP, adapter)


async def healthz(req: Request) -> Response:
    return json_response({
        "status": "healthy",
        "service": "agent-webapp",
        "version": "v20-obs",
        "observability": HAS_OBSERVABILITY,
    })


async def root(req: Request) -> Response:
    return json_response({
        "service": "PCE Agent (A365)",
        "version": "v20-obs",
        "endpoints": ["/api/messages", "/healthz"],
    })


# ─── Application ────────────────────────────────────────────────────────────

app = Application()
app.router.add_post("/api/messages", entry_point)
app.router.add_get("/api/messages", lambda _: Response(status=200))
app.router.add_get("/healthz", healthz)
app.router.add_get("/", root)

if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    logger.info("Starting agent-webapp v20-obs on port %d", port)
    run_app(app, host="0.0.0.0", port=port)
