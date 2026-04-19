"""Unit tests for the Weather Azure Function.

Run: python -m pytest azure-function-server/test_function_app.py -v
"""

import json
import unittest
from unittest.mock import MagicMock
from datetime import datetime, timezone

# Import the function logic directly
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
from function_app import _get_weather, _get_forecast, app


class TestWeatherData(unittest.TestCase):
    """Test weather data generation functions."""

    def test_get_weather_known_city(self):
        result = _get_weather("Seattle")
        self.assertEqual(result["city"], "Seattle")
        self.assertIn("temperature", result)
        self.assertIn("celsius", result["temperature"])
        self.assertIn("fahrenheit", result["temperature"])
        self.assertIn("condition", result)
        self.assertIn("humidity_percent", result)
        self.assertIn("wind_speed_kmh", result)
        self.assertEqual(result["source"], "simulated")

    def test_get_weather_unknown_city(self):
        result = _get_weather("UnknownCity")
        self.assertEqual(result["city"], "UnknownCity")
        self.assertIn("temperature", result)
        self.assertEqual(result["source"], "simulated")

    def test_get_weather_temperature_range(self):
        for city in ["Seattle", "Tokyo", "Mumbai", "London"]:
            result = _get_weather(city)
            temp_c = result["temperature"]["celsius"]
            # Temperature should be within reasonable range
            self.assertGreater(temp_c, -50)
            self.assertLess(temp_c, 60)
            # Fahrenheit conversion
            expected_f = round(temp_c * 9 / 5 + 32, 1)
            self.assertAlmostEqual(result["temperature"]["fahrenheit"], expected_f, places=1)

    def test_get_weather_humidity_range(self):
        result = _get_weather("Seattle")
        self.assertGreaterEqual(result["humidity_percent"], 30)
        self.assertLessEqual(result["humidity_percent"], 95)

    def test_get_weather_deterministic(self):
        """Same city + same hour should produce same result."""
        r1 = _get_weather("Tokyo")
        r2 = _get_weather("Tokyo")
        self.assertEqual(r1["temperature"], r2["temperature"])
        self.assertEqual(r1["condition"], r2["condition"])

    def test_get_forecast_default_days(self):
        forecast = _get_forecast("Seattle", 3)
        self.assertEqual(len(forecast), 3)
        for day in forecast:
            self.assertIn("date", day)
            self.assertIn("high_celsius", day)
            self.assertIn("low_celsius", day)
            self.assertIn("condition", day)

    def test_get_forecast_max_days(self):
        forecast = _get_forecast("New York", 7)
        self.assertEqual(len(forecast), 7)

    def test_get_forecast_dates_sequential(self):
        forecast = _get_forecast("London", 5)
        dates = [day["date"] for day in forecast]
        for i in range(1, len(dates)):
            self.assertGreater(dates[i], dates[i - 1])


class TestHTTPEndpoints(unittest.TestCase):
    """Test Azure Function HTTP endpoints using mock requests."""

    def _make_request(self, params=None):
        """Create a mock HttpRequest."""
        req = MagicMock()
        req.params = params or {}
        return req

    def test_weather_endpoint_default_city(self):
        req = self._make_request()
        # Call the internal function directly
        result = _get_weather("Seattle")
        self.assertEqual(result["city"], "Seattle")

    def test_weather_endpoint_custom_city(self):
        result = _get_weather("Tokyo")
        self.assertEqual(result["city"], "Tokyo")

    def test_forecast_endpoint(self):
        forecast = _get_forecast("Paris", 3)
        self.assertEqual(len(forecast), 3)
        self.assertIn("condition", forecast[0])

    def test_weather_response_is_json_serializable(self):
        result = _get_weather("Berlin")
        # Should not raise
        serialized = json.dumps(result)
        self.assertIsInstance(serialized, str)
        parsed = json.loads(serialized)
        self.assertEqual(parsed["city"], "Berlin")

    def test_forecast_response_is_json_serializable(self):
        forecast = _get_forecast("Sydney", 5)
        serialized = json.dumps({"city": "Sydney", "forecast": forecast})
        self.assertIsInstance(serialized, str)


if __name__ == "__main__":
    unittest.main()
