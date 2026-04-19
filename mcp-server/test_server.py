"""Unit tests for the DateTime MCP Server.

Run: python -m pytest mcp-server/test_server.py -v
"""

import json
import unittest
from datetime import datetime, timezone
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
from server import (
    handle_get_current_time,
    handle_get_date_info,
    handle_convert_timezone,
    handle_time_difference,
    handle_mcp_request,
    TOOLS,
)


class TestGetCurrentTime(unittest.TestCase):
    def test_default_utc(self):
        result = json.loads(handle_get_current_time({}))
        self.assertEqual(result["timezone"], "UTC")
        self.assertIn("datetime", result)
        self.assertIn("date", result)
        self.assertIn("time", result)
        self.assertIn("day_of_week", result)
        self.assertIn("unix_timestamp", result)

    def test_specific_timezone(self):
        result = json.loads(handle_get_current_time({"timezone": "PST"}))
        self.assertEqual(result["timezone"], "PST")
        self.assertEqual(result["utc_offset"], "-8")

    def test_positive_offset(self):
        result = json.loads(handle_get_current_time({"timezone": "JST"}))
        self.assertEqual(result["timezone"], "JST")
        self.assertEqual(result["utc_offset"], "+9")

    def test_case_insensitive(self):
        result = json.loads(handle_get_current_time({"timezone": "est"}))
        self.assertEqual(result["timezone"], "EST")


class TestGetDateInfo(unittest.TestCase):
    def test_specific_date(self):
        result = json.loads(handle_get_date_info({"date": "2026-01-01"}))
        self.assertEqual(result["date"], "2026-01-01")
        self.assertEqual(result["day_of_week"], "Thursday")
        self.assertEqual(result["day_of_year"], 1)
        self.assertFalse(result["is_leap_year"])

    def test_leap_year(self):
        result = json.loads(handle_get_date_info({"date": "2024-02-29"}))
        self.assertTrue(result["is_leap_year"])
        self.assertEqual(result["day_of_week"], "Thursday")

    def test_default_today(self):
        result = json.loads(handle_get_date_info({}))
        self.assertIn("date", result)
        self.assertIn("day_of_week", result)
        self.assertIn("quarter", result)

    def test_quarter_calculation(self):
        q1 = json.loads(handle_get_date_info({"date": "2026-02-15"}))
        q2 = json.loads(handle_get_date_info({"date": "2026-05-15"}))
        q3 = json.loads(handle_get_date_info({"date": "2026-08-15"}))
        q4 = json.loads(handle_get_date_info({"date": "2026-11-15"}))
        self.assertEqual(q1["quarter"], 1)
        self.assertEqual(q2["quarter"], 2)
        self.assertEqual(q3["quarter"], 3)
        self.assertEqual(q4["quarter"], 4)


class TestConvertTimezone(unittest.TestCase):
    def test_pst_to_jst(self):
        result = json.loads(handle_convert_timezone({
            "datetime_str": "2026-04-16T10:00:00",
            "from_timezone": "PST",
            "to_timezone": "JST",
        }))
        self.assertEqual(result["original"]["timezone"], "PST")
        self.assertEqual(result["converted"]["timezone"], "JST")
        # PST is -8, JST is +9, so difference is 17 hours
        self.assertIn("2026-04-17T03:00:00", result["converted"]["datetime"])

    def test_utc_to_est(self):
        result = json.loads(handle_convert_timezone({
            "datetime_str": "2026-04-16T12:00:00",
            "from_timezone": "UTC",
            "to_timezone": "EST",
        }))
        self.assertIn("07:00:00", result["converted"]["datetime"])

    def test_same_timezone(self):
        result = json.loads(handle_convert_timezone({
            "datetime_str": "2026-04-16T15:30:00",
            "from_timezone": "UTC",
            "to_timezone": "UTC",
        }))
        self.assertIn("15:30:00", result["converted"]["datetime"])


class TestTimeDifference(unittest.TestCase):
    def test_one_day_apart(self):
        result = json.loads(handle_time_difference({
            "datetime1": "2026-04-16T00:00:00",
            "datetime2": "2026-04-17T00:00:00",
        }))
        self.assertEqual(result["difference"]["days"], 1)
        self.assertEqual(result["difference"]["hours"], 0)
        self.assertEqual(result["difference"]["direction"], "forward")

    def test_backward_direction(self):
        result = json.loads(handle_time_difference({
            "datetime1": "2026-04-17T00:00:00",
            "datetime2": "2026-04-16T00:00:00",
        }))
        self.assertEqual(result["difference"]["direction"], "backward")

    def test_hours_and_minutes(self):
        result = json.loads(handle_time_difference({
            "datetime1": "2026-04-16T10:00:00",
            "datetime2": "2026-04-16T13:30:00",
        }))
        self.assertEqual(result["difference"]["hours"], 3)
        self.assertEqual(result["difference"]["minutes"], 30)


class TestMCPProtocol(unittest.TestCase):
    """Test the MCP JSON-RPC protocol handling."""

    def test_initialize(self):
        response = handle_mcp_request({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {}
        })
        self.assertEqual(response["jsonrpc"], "2.0")
        self.assertEqual(response["id"], 1)
        self.assertIn("protocolVersion", response["result"])
        self.assertIn("capabilities", response["result"])
        self.assertEqual(response["result"]["serverInfo"]["name"], "datetime-mcp-server")

    def test_tools_list(self):
        response = handle_mcp_request({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
            "params": {}
        })
        tools = response["result"]["tools"]
        self.assertEqual(len(tools), 4)
        tool_names = [t["name"] for t in tools]
        self.assertIn("get_current_time", tool_names)
        self.assertIn("get_date_info", tool_names)
        self.assertIn("convert_timezone", tool_names)
        self.assertIn("time_difference", tool_names)

    def test_tools_call(self):
        response = handle_mcp_request({
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {
                "name": "get_current_time",
                "arguments": {"timezone": "UTC"}
            }
        })
        self.assertEqual(response["id"], 3)
        content = response["result"]["content"]
        self.assertEqual(len(content), 1)
        self.assertEqual(content[0]["type"], "text")
        parsed = json.loads(content[0]["text"])
        self.assertEqual(parsed["timezone"], "UTC")

    def test_unknown_tool(self):
        response = handle_mcp_request({
            "jsonrpc": "2.0",
            "id": 4,
            "method": "tools/call",
            "params": {"name": "nonexistent_tool", "arguments": {}}
        })
        self.assertIn("error", response)
        self.assertEqual(response["error"]["code"], -32601)

    def test_unknown_method(self):
        response = handle_mcp_request({
            "jsonrpc": "2.0",
            "id": 5,
            "method": "unknown/method",
            "params": {}
        })
        self.assertIn("error", response)

    def test_notification_returns_none(self):
        response = handle_mcp_request({
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
            "params": {}
        })
        self.assertIsNone(response)

    def test_tools_have_input_schemas(self):
        for tool in TOOLS:
            self.assertIn("name", tool)
            self.assertIn("description", tool)
            self.assertIn("inputSchema", tool)
            self.assertEqual(tool["inputSchema"]["type"], "object")


if __name__ == "__main__":
    unittest.main()
