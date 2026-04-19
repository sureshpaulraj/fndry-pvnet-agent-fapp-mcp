"""Unit tests for the Agent 365 web service."""

import json
import os
import sys
import unittest
from unittest.mock import patch, MagicMock, AsyncMock

# Ensure agent-webapp is on the path
sys.path.insert(0, os.path.join(os.path.dirname(__file__)))

# Set required env vars before importing app
os.environ.setdefault("BOT_APP_ID", "test-bot-id")
os.environ.setdefault("BOT_APP_SECRET", "test-bot-secret")
os.environ.setdefault("AZURE_TENANT_ID", "test-tenant")

from fastapi.testclient import TestClient


class TestHealthEndpoints(unittest.TestCase):
    """Test health and info endpoints."""

    def setUp(self):
        from app import app

        self.client = TestClient(app)

    def test_healthz(self):
        resp = self.client.get("/healthz")
        self.assertEqual(resp.status_code, 200)
        data = resp.json()
        self.assertEqual(data["status"], "ok")
        self.assertEqual(data["agent"], "pce")
        self.assertEqual(data["framework"], "a365")

    def test_root(self):
        resp = self.client.get("/")
        self.assertEqual(resp.status_code, 200)
        data = resp.json()
        self.assertIn("service", data)
        self.assertIn("/api/messages", data["endpoints"])


class TestMessagesEndpoint(unittest.TestCase):
    """Test the /api/messages Bot Framework endpoint."""

    def setUp(self):
        from app import app

        self.client = TestClient(app)

    @patch("app.process_message")
    @patch("app._send_activity", new_callable=AsyncMock)
    def test_message_activity(self, mock_send, mock_process):
        mock_process.return_value = "The weather in Seattle is sunny, 72°F."

        activity = {
            "type": "message",
            "text": "What's the weather in Seattle?",
            "from": {"id": "user1", "name": "Test User"},
            "recipient": {"id": "bot1", "name": "PCE Agent"},
            "id": "activity-1",
            "serviceUrl": "https://smba.trafficmanager.net/teams/",
            "conversation": {"id": "conv-1"},
        }
        resp = self.client.post("/api/messages", json=activity)
        self.assertEqual(resp.status_code, 200)
        mock_process.assert_called_once_with("What's the weather in Seattle?")
        mock_send.assert_called_once()

    @patch("app.process_message")
    @patch("app._send_activity", new_callable=AsyncMock)
    def test_empty_message_returns_200(self, mock_send, mock_process):
        activity = {
            "type": "message",
            "text": "",
            "from": {"id": "user1"},
            "recipient": {"id": "bot1"},
        }
        resp = self.client.post("/api/messages", json=activity)
        self.assertEqual(resp.status_code, 200)
        mock_process.assert_not_called()

    def test_non_message_activity(self):
        activity = {"type": "typing"}
        resp = self.client.post("/api/messages", json=activity)
        self.assertEqual(resp.status_code, 200)

    @patch("app._send_activity", new_callable=AsyncMock)
    def test_conversation_update_welcome(self, mock_send):
        activity = {
            "type": "conversationUpdate",
            "membersAdded": [{"id": "user1", "name": "Test User"}],
            "from": {"id": "user1"},
            "recipient": {"id": "bot1", "name": "PCE Agent"},
            "serviceUrl": "https://smba.trafficmanager.net/teams/",
            "conversation": {"id": "conv-1"},
        }
        resp = self.client.post("/api/messages", json=activity)
        self.assertEqual(resp.status_code, 200)
        mock_send.assert_called_once()


class TestTools(unittest.TestCase):
    """Test the tool execution layer."""

    @patch("tools.requests.get")
    @patch("tools.credential")
    def test_call_weather(self, mock_cred, mock_get):
        mock_token = MagicMock()
        mock_token.token = "test-token"
        mock_cred.get_token.return_value = mock_token

        mock_resp = MagicMock()
        mock_resp.json.return_value = {"city": "Seattle", "temperature": 72}
        mock_resp.raise_for_status = MagicMock()
        mock_get.return_value = mock_resp

        from tools import call_weather

        result = call_weather("weather", {"city": "Seattle"})
        data = json.loads(result)
        self.assertEqual(data["city"], "Seattle")

    @patch("tools.requests.post")
    def test_call_mcp(self, mock_post):
        mock_resp = MagicMock()
        mock_resp.json.return_value = {
            "result": {
                "content": [{"type": "text", "text": "2026-04-18 12:00:00 UTC"}]
            }
        }
        mock_resp.raise_for_status = MagicMock()
        mock_post.return_value = mock_resp

        from tools import call_mcp

        result = call_mcp("get_current_time", {"timezone": "UTC"})
        self.assertIn("2026-04-18", result)

    def test_execute_tool_unknown(self):
        from tools import execute_tool

        result = execute_tool("unknown_tool", {})
        data = json.loads(result)
        self.assertIn("error", data)
        self.assertIn("Unknown tool", data["error"])

    def test_execute_tool_routes_weather(self):
        from tools import execute_tool

        with patch("tools.call_weather", return_value='{"ok":true}') as m:
            execute_tool("get_weather", {"city": "London"})
            m.assert_called_once_with("weather", {"city": "London"})

    def test_execute_tool_routes_mcp(self):
        from tools import execute_tool

        with patch("tools.call_mcp", return_value="time result") as m:
            execute_tool("get_current_time", {"timezone": "PST"})
            m.assert_called_once_with("get_current_time", {"timezone": "PST"})


class TestBotHandler(unittest.TestCase):
    """Test the bot message processing."""

    @patch("bot.execute_tool")
    @patch("bot._api")
    def test_process_message_completed(self, mock_api, mock_tool):
        # Simulate: create thread → add message → create run → poll completed → get messages
        mock_api.side_effect = [
            {"id": "thread-1"},  # create thread
            {},  # add message
            {"id": "run-1"},  # create run
            {"status": "completed"},  # get run
            {
                "data": [
                    {
                        "role": "assistant",
                        "content": [
                            {"type": "text", "text": {"value": "It's sunny!"}}
                        ],
                    }
                ]
            },  # get messages
        ]

        from bot import process_message

        result = process_message("weather?")
        self.assertEqual(result, "It's sunny!")

    @patch("bot.execute_tool")
    @patch("bot._api")
    def test_process_message_with_tool_call(self, mock_api, mock_tool):
        mock_tool.return_value = '{"temperature": 72}'
        mock_api.side_effect = [
            {"id": "thread-1"},  # create thread
            {},  # add message
            {"id": "run-1"},  # create run
            {
                "status": "requires_action",
                "required_action": {
                    "submit_tool_outputs": {
                        "tool_calls": [
                            {
                                "id": "tc-1",
                                "function": {
                                    "name": "get_weather",
                                    "arguments": '{"city":"Seattle"}',
                                },
                            }
                        ]
                    }
                },
            },  # get run → requires_action
            {},  # submit tool outputs
            {"status": "completed"},  # get run → completed
            {
                "data": [
                    {
                        "role": "assistant",
                        "content": [
                            {
                                "type": "text",
                                "text": {"value": "Seattle is 72°F."},
                            }
                        ],
                    }
                ]
            },  # get messages
        ]

        from bot import process_message

        result = process_message("weather in Seattle?")
        self.assertEqual(result, "Seattle is 72°F.")
        mock_tool.assert_called_once_with("get_weather", {"city": "Seattle"})

    @patch("bot._api")
    def test_process_message_failed(self, mock_api):
        mock_api.side_effect = [
            {"id": "thread-1"},
            {},
            {"id": "run-1"},
            {
                "status": "failed",
                "last_error": {"message": "Model overloaded"},
            },
        ]

        from bot import process_message

        result = process_message("test")
        self.assertIn("failed", result)
        self.assertIn("Model overloaded", result)


if __name__ == "__main__":
    unittest.main()
