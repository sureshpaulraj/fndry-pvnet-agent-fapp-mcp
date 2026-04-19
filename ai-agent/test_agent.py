# Unit tests for the AI agent orchestration
# Tests tool execution, routing, and MCP/HTTP integration (mocked)
#
# The agent module uses AzureOpenAI + DefaultAzureCredential at import time,
# so we mock those before importing.

import json
import os
import sys
import unittest
from unittest.mock import patch, MagicMock

# Set env vars BEFORE importing the agent module
os.environ["AZURE_OPENAI_ENDPOINT"] = "https://test.openai.azure.com/"
os.environ["MODEL_DEPLOYMENT"] = "gpt-4o-mini"
os.environ["WEATHER_BASE_URL"] = "https://weather.test"
os.environ["MCP_BASE_URL"] = "http://mcp.test"

# Add ai-agent directory to path so we can import agent directly
sys.path.insert(0, os.path.join(os.path.dirname(__file__)))

# Mock azure.identity and openai before importing agent
_mock_credential = MagicMock()
_mock_token_provider = MagicMock(return_value="fake-token")
with patch("azure.identity.DefaultAzureCredential", return_value=_mock_credential), \
     patch("azure.identity.get_bearer_token_provider", return_value=_mock_token_provider), \
     patch("openai.AzureOpenAI"):
    import agent  # noqa: E402


class TestCallWeatherFunction(unittest.TestCase):
    """Test the Weather Function HTTP caller."""

    @patch.object(agent.requests, "get")
    def test_get_weather_success(self, mock_get):
        mock_resp = MagicMock()
        mock_resp.json.return_value = {"city": "Seattle", "temperature": {"celsius": 15}}
        mock_resp.raise_for_status = MagicMock()
        mock_get.return_value = mock_resp

        result = agent.call_weather_function("weather", {"city": "Seattle"})
        data = json.loads(result)
        self.assertEqual(data["city"], "Seattle")
        mock_get.assert_called_once()
        call_kwargs = mock_get.call_args
        self.assertEqual(call_kwargs.args[0], "https://weather.test/api/weather")
        self.assertEqual(call_kwargs.kwargs["params"], {"city": "Seattle"})
        self.assertEqual(call_kwargs.kwargs["timeout"], 15)
        self.assertIn("Authorization", call_kwargs.kwargs["headers"])
        self.assertTrue(call_kwargs.kwargs["headers"]["Authorization"].startswith("Bearer "))

    @patch.object(agent.requests, "get")
    def test_get_weather_error(self, mock_get):
        mock_get.side_effect = agent.requests.ConnectionError("Connection refused")
        result = agent.call_weather_function("weather", {"city": "X"})
        data = json.loads(result)
        self.assertIn("error", data)

    @patch.object(agent.requests, "get")
    def test_get_forecast_params(self, mock_get):
        mock_resp = MagicMock()
        mock_resp.json.return_value = {"city": "Tokyo", "forecast": []}
        mock_resp.raise_for_status = MagicMock()
        mock_get.return_value = mock_resp

        result = agent.call_weather_function("weather/forecast", {"city": "Tokyo", "days": 5})
        mock_get.assert_called_once()
        call_kwargs = mock_get.call_args
        self.assertEqual(call_kwargs.args[0], "https://weather.test/api/weather/forecast")
        self.assertEqual(call_kwargs.kwargs["params"], {"city": "Tokyo", "days": 5})
        self.assertEqual(call_kwargs.kwargs["timeout"], 15)
        self.assertIn("Authorization", call_kwargs.kwargs["headers"])


class TestCallMCPTool(unittest.TestCase):
    """Test the MCP JSON-RPC caller."""

    @patch.object(agent.requests, "post")
    def test_mcp_tool_success(self, mock_post):
        mock_resp = MagicMock()
        mock_resp.json.return_value = {
            "jsonrpc": "2.0",
            "id": 1,
            "result": {
                "content": [{"type": "text", "text": '{"timezone":"UTC","time":"12:00:00"}'}]
            },
        }
        mock_resp.raise_for_status = MagicMock()
        mock_post.return_value = mock_resp

        result = agent.call_mcp_tool("get_current_time", {"timezone": "UTC"})
        data = json.loads(result)
        self.assertEqual(data["timezone"], "UTC")

    @patch.object(agent.requests, "post")
    def test_mcp_tool_error_response(self, mock_post):
        mock_resp = MagicMock()
        mock_resp.json.return_value = {
            "jsonrpc": "2.0",
            "id": 1,
            "error": {"code": -32601, "message": "Method not found"},
        }
        mock_resp.raise_for_status = MagicMock()
        mock_post.return_value = mock_resp

        result = agent.call_mcp_tool("unknown_tool", {})
        data = json.loads(result)
        self.assertIn("code", data)

    @patch.object(agent.requests, "post")
    def test_mcp_tool_network_error(self, mock_post):
        mock_post.side_effect = agent.requests.ConnectionError("timeout")
        result = agent.call_mcp_tool("get_current_time", {})
        data = json.loads(result)
        self.assertIn("error", data)

    @patch.object(agent.requests, "post")
    def test_mcp_payload_structure(self, mock_post):
        mock_resp = MagicMock()
        mock_resp.json.return_value = {
            "jsonrpc": "2.0", "id": 1,
            "result": {"content": [{"type": "text", "text": "{}"}]},
        }
        mock_resp.raise_for_status = MagicMock()
        mock_post.return_value = mock_resp

        agent.call_mcp_tool("get_date_info", {"date": "2025-12-25"})
        call_args = mock_post.call_args
        payload = call_args[1]["json"] if "json" in call_args[1] else call_args[0][0]
        self.assertEqual(payload["jsonrpc"], "2.0")
        self.assertEqual(payload["method"], "tools/call")
        self.assertEqual(payload["params"]["name"], "get_date_info")
        self.assertEqual(payload["params"]["arguments"]["date"], "2025-12-25")


class TestExecuteTool(unittest.TestCase):
    """Test the tool router."""

    @patch.object(agent, "call_weather_function", return_value='{"city":"Seattle"}')
    def test_route_get_weather(self, mock_fn):
        result = agent.execute_tool("get_weather", {"city": "Seattle"})
        mock_fn.assert_called_once_with("weather", {"city": "Seattle"})
        self.assertIn("Seattle", result)

    @patch.object(agent, "call_weather_function", return_value='{"city":"Tokyo","forecast":[]}')
    def test_route_get_weather_forecast(self, mock_fn):
        agent.execute_tool("get_weather_forecast", {"city": "Tokyo", "days": 3})
        mock_fn.assert_called_once_with("weather/forecast", {"city": "Tokyo", "days": 3})

    @patch.object(agent, "call_mcp_tool", return_value='{"timezone":"PST"}')
    def test_route_get_current_time(self, mock_mcp):
        agent.execute_tool("get_current_time", {"timezone": "PST"})
        mock_mcp.assert_called_once_with("get_current_time", {"timezone": "PST"})

    @patch.object(agent, "call_mcp_tool", return_value='{"info":"date"}')
    def test_route_get_date_info(self, mock_mcp):
        agent.execute_tool("get_date_info", {"date": "2025-01-01"})
        mock_mcp.assert_called_once_with("get_date_info", {"date": "2025-01-01"})

    @patch.object(agent, "call_mcp_tool", return_value='{"converted":"ok"}')
    def test_route_convert_timezone(self, mock_mcp):
        args = {"datetime_str": "2025-01-15T14:30:00", "from_timezone": "UTC", "to_timezone": "JST"}
        agent.execute_tool("convert_timezone", args)
        mock_mcp.assert_called_once_with("convert_timezone", args)

    @patch.object(agent, "call_mcp_tool", return_value='{"diff":"1h"}')
    def test_route_time_difference(self, mock_mcp):
        args = {"datetime1": "2025-01-01T00:00:00", "datetime2": "2025-01-01T01:00:00"}
        agent.execute_tool("time_difference", args)
        mock_mcp.assert_called_once_with("time_difference", args)

    def test_route_unknown_tool(self):
        result = agent.execute_tool("nonexistent", {})
        data = json.loads(result)
        self.assertIn("error", data)
        self.assertIn("Unknown tool", data["error"])


class TestToolDefinitions(unittest.TestCase):
    """Verify TOOLS list structure."""

    def test_tool_count(self):
        self.assertEqual(len(agent.TOOLS), 6)

    def test_all_tools_have_required_fields(self):
        for tool in agent.TOOLS:
            self.assertEqual(tool["type"], "function")
            fn = tool["function"]
            self.assertIn("name", fn)
            self.assertIn("description", fn)
            self.assertIn("parameters", fn)
            self.assertEqual(fn["parameters"]["type"], "object")

    def test_tool_names(self):
        names = {t["function"]["name"] for t in agent.TOOLS}
        expected = {
            "get_weather", "get_weather_forecast",
            "get_current_time", "get_date_info",
            "convert_timezone", "time_difference",
        }
        self.assertEqual(names, expected)

    def test_convert_timezone_required_params(self):
        tz_tool = next(t for t in agent.TOOLS if t["function"]["name"] == "convert_timezone")
        required = tz_tool["function"]["parameters"].get("required", [])
        self.assertIn("datetime_str", required)
        self.assertIn("from_timezone", required)
        self.assertIn("to_timezone", required)

    def test_time_difference_required_params(self):
        td_tool = next(t for t in agent.TOOLS if t["function"]["name"] == "time_difference")
        required = td_tool["function"]["parameters"].get("required", [])
        self.assertIn("datetime1", required)
        self.assertIn("datetime2", required)


if __name__ == "__main__":
    unittest.main()
