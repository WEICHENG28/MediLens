from datetime import datetime
import pytest
from fastapi.testclient import TestClient
from app.main import app
from app.lifestyle import Event

client = TestClient(app)

@pytest.mark.parametrize("record", [
    {"type": "glucose", "glucose": -1},
    {"type": "glucose"},
    {"type": "glucose", "glucose": 180},
    {"type": "exercise", "minutes": -30},
    {"type": "exercise"},
    {"type": "meal", "meal_grams": -100},
])
def test_invalid_measurements_are_rejected(record):
    record["time"] = "2026-11-01T12:00:00"
    assert client.post("/api/v1/lifestyle", json={"events": [record]}).status_code == 422


def test_units_legacy_nutrients_and_timezone():
    reading = Event(type="glucose", time="2026-11-01T04:00:00Z", glucose=180, unit="mg/dL")
    assert reading.glucose == 10 and reading.unit == "mmol/L"
    assert reading.original_glucose == 180 and reading.time == datetime(2026, 11, 1, 12)
    meal = Event(type="meal", time=reading.time, meal_carbs_g=42, meal_grams=150, meal_food="rice", meal_fdc_id=2708408)
    assert meal.carbs_g == 42 and meal.grams == 150 and meal.meal_fdc_id == 2708408


def test_mixed_timezone_and_future_boundary():
    events = [
        {"type": "glucose", "glucose": 6.2, "time": "2026-11-01T12:00:00"},
        {"type": "glucose", "glucose": 7.2, "time": "2026-11-01T06:00:00Z"},
    ]
    assert client.post("/api/v1/lifestyle", json={"events": events}).status_code == 200
    events[0]["time"] = "2099-01-01T12:00:00"
    assert client.post("/api/v1/lifestyle", json={"events": events}).status_code == 422
    events[0]["is_simulated"] = True
    events[1]["is_simulated"] = True
    assert client.post("/api/v1/lifestyle", json={"events": events}).status_code == 200
