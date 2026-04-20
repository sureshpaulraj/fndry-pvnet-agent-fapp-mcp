# DateTime MCP Server
#
# A simple MCP (Model Context Protocol) server that provides date/time tools.
# Deployed on the VNet as a Container App, accessible by agents via Data Proxy.
#
# MCP Endpoints:
#   POST /mcp  - MCP JSON-RPC endpoint (tools/list, tools/call)
#   GET /healthz - Health check
#
# Tools provided:
#   - get_current_time: Get current UTC time or time in a specific timezone
#   - get_date_info: Get detailed info about a date (day of week, week number, etc.)
#   - convert_timezone: Convert a datetime from one timezone to another
#   - time_difference: Calculate the difference between two datetimes

import json
import logging
from datetime import datetime, timezone, timedelta
from http.server import HTTPServer, BaseHTTPRequestHandler
import os

# ─── Azure Monitor (App Insights) ────────────────────────────────────────────
_ai_conn_str = os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING", "")
if _ai_conn_str and _ai_conn_str != "placeholder":
    from azure.monitor.opentelemetry import configure_azure_monitor
    configure_azure_monitor(
        connection_string=_ai_conn_str,
        logger_name="datetime-mcp",
        enable_live_metrics=True,
    )

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("datetime-mcp")

# Common timezone offsets (hours from UTC)
TIMEZONE_OFFSETS = {
    "UTC": 0,
    "EST": -5, "EDT": -4,
    "CST": -6, "CDT": -5,
    "MST": -7, "MDT": -6,
    "PST": -8, "PDT": -7,
    "GMT": 0, "BST": 1,
    "CET": 1, "CEST": 2,
    "IST": 5.5,
    "JST": 9,
    "AEST": 10, "AEDT": 11,
    "NZST": 12, "NZDT": 13,
}

# MCP tool definitions
TOOLS = [
    {
        "name": "get_current_time",
        "description": "Get the current date and time. Optionally specify a timezone (e.g., PST, JST, UTC).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "timezone": {
                    "type": "string",
                    "description": "Timezone abbreviation (e.g., UTC, PST, JST, EST). Defaults to UTC.",
                    "default": "UTC"
                }
            }
        }
    },
    {
        "name": "get_date_info",
        "description": "Get detailed information about a specific date: day of week, week number, day of year, whether it's a leap year, etc.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "date": {
                    "type": "string",
                    "description": "Date in YYYY-MM-DD format. Defaults to today."
                }
            }
        }
    },
    {
        "name": "convert_timezone",
        "description": "Convert a datetime from one timezone to another.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "datetime_str": {
                    "type": "string",
                    "description": "Datetime in ISO 8601 format (e.g., 2026-04-16T10:30:00)"
                },
                "from_timezone": {
                    "type": "string",
                    "description": "Source timezone abbreviation (e.g., PST, UTC)"
                },
                "to_timezone": {
                    "type": "string",
                    "description": "Target timezone abbreviation (e.g., JST, EST)"
                }
            },
            "required": ["datetime_str", "from_timezone", "to_timezone"]
        }
    },
    {
        "name": "time_difference",
        "description": "Calculate the time difference between two datetimes.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "datetime1": {
                    "type": "string",
                    "description": "First datetime in ISO 8601 format"
                },
                "datetime2": {
                    "type": "string",
                    "description": "Second datetime in ISO 8601 format"
                }
            },
            "required": ["datetime1", "datetime2"]
        }
    }
]


def _get_tz_offset(tz_name: str) -> float:
    """Get timezone offset in hours."""
    return TIMEZONE_OFFSETS.get(tz_name.upper(), 0)


def handle_get_current_time(arguments: dict) -> str:
    tz_name = arguments.get("timezone", "UTC").upper()
    offset_hours = _get_tz_offset(tz_name)
    offset = timedelta(hours=offset_hours)
    tz = timezone(offset)
    now = datetime.now(tz)

    return json.dumps({
        "timezone": tz_name,
        "utc_offset": f"{'+' if offset_hours >= 0 else ''}{offset_hours}",
        "datetime": now.isoformat(),
        "date": now.strftime("%Y-%m-%d"),
        "time": now.strftime("%H:%M:%S"),
        "day_of_week": now.strftime("%A"),
        "unix_timestamp": int(now.timestamp()),
    })


def handle_get_date_info(arguments: dict) -> str:
    date_str = arguments.get("date")
    if date_str:
        dt = datetime.strptime(date_str, "%Y-%m-%d")
    else:
        dt = datetime.now(timezone.utc)

    year = dt.year
    is_leap = (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0)

    return json.dumps({
        "date": dt.strftime("%Y-%m-%d"),
        "day_of_week": dt.strftime("%A"),
        "day_of_year": dt.timetuple().tm_yday,
        "week_number": dt.isocalendar()[1],
        "month_name": dt.strftime("%B"),
        "quarter": (dt.month - 1) // 3 + 1,
        "is_leap_year": is_leap,
        "days_in_month": (dt.replace(month=dt.month % 12 + 1, day=1) - timedelta(days=1)).day if dt.month < 12 else 31,
        "iso_format": dt.date().isoformat(),
    })


def handle_convert_timezone(arguments: dict) -> str:
    dt_str = arguments["datetime_str"]
    from_tz = arguments["from_timezone"].upper()
    to_tz = arguments["to_timezone"].upper()

    dt = datetime.fromisoformat(dt_str)
    from_offset = timedelta(hours=_get_tz_offset(from_tz))
    to_offset = timedelta(hours=_get_tz_offset(to_tz))

    # Convert to UTC first, then to target
    dt_utc = dt - from_offset
    dt_target = dt_utc + to_offset

    return json.dumps({
        "original": {
            "datetime": dt.isoformat(),
            "timezone": from_tz,
        },
        "converted": {
            "datetime": dt_target.isoformat(),
            "timezone": to_tz,
        },
        "utc": dt_utc.isoformat(),
    })


def handle_time_difference(arguments: dict) -> str:
    dt1 = datetime.fromisoformat(arguments["datetime1"])
    dt2 = datetime.fromisoformat(arguments["datetime2"])

    diff = dt2 - dt1
    total_seconds = int(diff.total_seconds())
    abs_seconds = abs(total_seconds)

    days = abs_seconds // 86400
    hours = (abs_seconds % 86400) // 3600
    minutes = (abs_seconds % 3600) // 60
    seconds = abs_seconds % 60

    return json.dumps({
        "datetime1": dt1.isoformat(),
        "datetime2": dt2.isoformat(),
        "difference": {
            "total_seconds": total_seconds,
            "days": days,
            "hours": hours,
            "minutes": minutes,
            "seconds": seconds,
            "human_readable": f"{days}d {hours}h {minutes}m {seconds}s",
            "direction": "forward" if total_seconds >= 0 else "backward",
        }
    })


TOOL_HANDLERS = {
    "get_current_time": handle_get_current_time,
    "get_date_info": handle_get_date_info,
    "convert_timezone": handle_convert_timezone,
    "time_difference": handle_time_difference,
}


def handle_mcp_request(request_body: dict) -> dict:
    """Handle an MCP JSON-RPC request."""
    method = request_body.get("method", "")
    request_id = request_body.get("id")
    params = request_body.get("params", {})

    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "protocolVersion": "2025-03-26",
                "capabilities": {
                    "tools": {"listChanged": False}
                },
                "serverInfo": {
                    "name": "datetime-mcp-server",
                    "version": "1.0.0"
                }
            }
        }

    elif method == "tools/list":
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "tools": TOOLS
            }
        }

    elif method == "tools/call":
        tool_name = params.get("name", "")
        arguments = params.get("arguments", {})

        handler = TOOL_HANDLERS.get(tool_name)
        if handler is None:
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {
                    "code": -32601,
                    "message": f"Unknown tool: {tool_name}"
                }
            }

        try:
            result_text = handler(arguments)
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "content": [
                        {
                            "type": "text",
                            "text": result_text
                        }
                    ]
                }
            }
        except Exception as e:
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {
                    "code": -32603,
                    "message": str(e)
                }
            }

    elif method == "notifications/initialized":
        # No response needed for notifications
        return None

    else:
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "error": {
                "code": -32601,
                "message": f"Method not found: {method}"
            }
        }


class MCPHandler(BaseHTTPRequestHandler):
    """HTTP handler for MCP JSON-RPC over HTTP (Streamable HTTP transport)."""

    def do_POST(self):
        if self.path == "/mcp":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length)

            try:
                request_data = json.loads(body)
            except json.JSONDecodeError:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({
                    "jsonrpc": "2.0",
                    "id": None,
                    "error": {"code": -32700, "message": "Parse error"}
                }).encode())
                return

            response = handle_mcp_request(request_data)

            if response is None:
                # Notification — no response body
                self.send_response(204)
                self.end_headers()
                return

            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(response).encode())
        else:
            self.send_response(404)
            self.end_headers()

    def do_GET(self):
        if self.path == "/healthz":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({
                "status": "ok",
                "service": "datetime-mcp-server",
                "version": "1.0.0",
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "tools": [t["name"] for t in TOOLS],
            }).encode())
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        logger.info(format % args)


def main():
    port = int(os.environ.get("PORT", "8080"))
    server = HTTPServer(("0.0.0.0", port), MCPHandler)
    logger.info(f"DateTime MCP Server starting on port {port}")
    logger.info(f"MCP endpoint: http://0.0.0.0:{port}/mcp")
    logger.info(f"Health check: http://0.0.0.0:{port}/healthz")
    server.serve_forever()


if __name__ == "__main__":
    main()
