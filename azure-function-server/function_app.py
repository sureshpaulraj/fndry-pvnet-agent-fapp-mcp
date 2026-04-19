# Weather API — Azure Function Behind VNet
#
# A simple Azure Function that provides weather data for agent tool access.
# Demonstrates VNet Integration: the function is publicly accessible
# (publicNetworkAccess: Enabled) but outbound traffic goes through VNet
# Integration, letting it reach private resources on the VNet.
#
# Endpoints:
#   GET  /api/weather?city=Seattle     - Get current weather for a city
#   GET  /api/weather/forecast?city=Seattle&days=3 - Get forecast
#   GET  /api/healthz                  - Health check
#
# Run locally: func start
# Deploy:      func azure functionapp publish <APP_NAME>

import json
import logging
import random
from datetime import datetime, timezone, timedelta

import azure.functions as func

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)

# Simple simulated weather data (in production, call a real weather API via VNet)
WEATHER_CONDITIONS = ["Sunny", "Partly Cloudy", "Cloudy", "Rainy", "Stormy", "Snowy", "Foggy", "Windy"]

CITY_BASE_TEMPS = {
    "Seattle": {"base": 12, "range": 8},
    "New York": {"base": 15, "range": 12},
    "London": {"base": 11, "range": 7},
    "Tokyo": {"base": 16, "range": 10},
    "Sydney": {"base": 22, "range": 6},
    "Paris": {"base": 13, "range": 9},
    "Berlin": {"base": 10, "range": 11},
    "Mumbai": {"base": 30, "range": 5},
    "Toronto": {"base": 8, "range": 15},
    "San Francisco": {"base": 15, "range": 5},
}


def _get_weather(city: str) -> dict:
    """Generate weather data for a city.

    In a production scenario, this would call an external weather API
    through VNet Integration to reach private endpoints.
    """
    now = datetime.now(timezone.utc)
    city_info = CITY_BASE_TEMPS.get(city, {"base": 18, "range": 10})

    # Deterministic-ish based on city + hour for consistency
    seed = hash(f"{city}-{now.strftime('%Y%m%d%H')}")
    rng = random.Random(seed)

    temp_c = city_info["base"] + rng.uniform(-city_info["range"] / 2, city_info["range"] / 2)
    temp_c = round(temp_c, 1)
    temp_f = round(temp_c * 9 / 5 + 32, 1)
    condition = rng.choice(WEATHER_CONDITIONS)
    humidity = rng.randint(30, 95)
    wind_speed_kmh = round(rng.uniform(0, 40), 1)

    return {
        "city": city,
        "timestamp": now.isoformat(),
        "temperature": {
            "celsius": temp_c,
            "fahrenheit": temp_f,
        },
        "condition": condition,
        "humidity_percent": humidity,
        "wind_speed_kmh": wind_speed_kmh,
        "source": "simulated",
    }


def _get_forecast(city: str, days: int) -> list:
    """Generate a multi-day forecast."""
    now = datetime.now(timezone.utc)
    forecast = []
    for i in range(days):
        day = now + timedelta(days=i)
        seed = hash(f"{city}-{day.strftime('%Y%m%d')}")
        rng = random.Random(seed)
        city_info = CITY_BASE_TEMPS.get(city, {"base": 18, "range": 10})

        high = round(city_info["base"] + rng.uniform(0, city_info["range"] / 2), 1)
        low = round(city_info["base"] - rng.uniform(0, city_info["range"] / 2), 1)
        condition = rng.choice(WEATHER_CONDITIONS)

        forecast.append({
            "date": day.strftime("%Y-%m-%d"),
            "high_celsius": high,
            "low_celsius": low,
            "high_fahrenheit": round(high * 9 / 5 + 32, 1),
            "low_fahrenheit": round(low * 9 / 5 + 32, 1),
            "condition": condition,
        })

    return forecast


@app.route(route="weather", methods=["GET"])
def weather(req: func.HttpRequest) -> func.HttpResponse:
    """Get current weather for a city.

    Query Parameters:
        city: City name (default: Seattle)
    """
    logging.info("Weather function invoked")
    city = req.params.get("city", "Seattle")

    data = _get_weather(city)
    return func.HttpResponse(
        json.dumps(data, indent=2),
        status_code=200,
        mimetype="application/json",
    )


@app.route(route="weather/forecast", methods=["GET"])
def weather_forecast(req: func.HttpRequest) -> func.HttpResponse:
    """Get multi-day weather forecast for a city.

    Query Parameters:
        city: City name (default: Seattle)
        days: Number of days (default: 3, max: 7)
    """
    logging.info("Weather forecast function invoked")
    city = req.params.get("city", "Seattle")

    try:
        days = min(int(req.params.get("days", "3")), 7)
    except ValueError:
        days = 3

    forecast = _get_forecast(city, days)
    return func.HttpResponse(
        json.dumps({"city": city, "forecast": forecast}, indent=2),
        status_code=200,
        mimetype="application/json",
    )


@app.route(route="healthz", methods=["GET"])
def healthz(req: func.HttpRequest) -> func.HttpResponse:
    """Health check endpoint."""
    return func.HttpResponse(
        json.dumps({
            "status": "ok",
            "service": "weather-api",
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }),
        status_code=200,
        mimetype="application/json",
    )
