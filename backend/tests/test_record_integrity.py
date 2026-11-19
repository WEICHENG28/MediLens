"""组员 1.0.2 问题清单的回归测试：照护入口共用检查、相同编号只算一次、跨栏位检查、多设备写入冲突。"""
from datetime import datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from app.care import CareRequest, build_profile
from app.lifestyle import Event
from app.main import app

client = TestClient(app)
FUTURE = (datetime.now() + timedelta(days=30)).replace(microsecond=0).isoformat()


@pytest.mark.parametrize("path,extra", [
    ("/api/v1/care/profile", {}), ("/api/v1/care/daily", {}), ("/api/v1/care/goal", {}), ("/api/v1/care/weekly", {}),
    ("/api/v1/care/visit", {}), ("/api/v1/care/chat", {"message": "最近怎么样"}),
    ("/api/v1/care/record", {"new": [{"type": "glucose", "time": "2026-11-01T08:00:00", "glucose": 6.0}]}),
])
def test_every_care_endpoint_rejects_future_actual_records(path, extra):
    body = {"events": [{"type": "glucose", "time": FUTURE, "glucose": 6.0}], **extra}
    assert client.post(path, json=body).status_code == 422


def test_care_endpoints_reject_mixed_simulated_and_actual_but_accept_all_simulated():
    sim = {"type": "glucose", "time": FUTURE, "glucose": 6.0, "is_simulated": True}
    real = {"type": "glucose", "time": "2026-11-01T08:00:00", "glucose": 6.0}
    assert client.post("/api/v1/care/profile", json={"events": [sim, real]}).status_code == 422
    assert client.post("/api/v1/care/profile", json={"events": [sim]}).status_code == 200  # 示范资料可以是未来时间
    r = client.post("/api/v1/care/record", json={"events": [real], "new": [sim]})
    assert r.status_code == 422


def test_new_record_in_future_is_rejected_even_if_history_is_fine():
    body = {"events": [{"type": "glucose", "time": "2026-11-01T08:00:00", "glucose": 6.0}],
            "new": [{"type": "glucose", "time": FUTURE, "glucose": 6.0}]}
    assert client.post("/api/v1/care/record", json=body).status_code == 422


def test_same_id_counts_once():
    e = {"id": "abc", "type": "glucose", "time": "2026-11-01T08:00:00", "glucose": 6.2}
    r = build_profile(CareRequest(events=[Event(**e), Event(**e), Event(**{**e, "id": None})]))
    assert r.metrics.readings == 2   # 相同编号算一次；没有编号的旧记录照常保留
    lr = client.post("/api/v1/lifestyle", json={"events": [e, e]}).json()
    assert lr["metrics"]["readings"] == 1


@pytest.mark.parametrize("record", [
    {"type": "meal", "carbs_g": 10, "sugars_g": 30},
    {"type": "bp", "systolic": 80, "diastolic": 100},
    {"type": "bp", "systolic": 130},
    {"type": "bp"},
    {"type": "weight"},
    {"type": "steps"},
    {"type": "lab", "lab": {}},
])
def test_cross_field_and_required_values(record):
    record["time"] = "2026-11-01T12:00:00"
    assert client.post("/api/v1/care/profile", json={"events": [record]}).status_code == 422
    assert client.post("/api/v1/lifestyle", json={"events": [record]}).status_code == 422


def test_valid_records_still_pass():
    ok = [{"type": "meal", "time": "2026-11-01T12:00:00", "carbs_g": 60, "sugars_g": 5},
          {"type": "bp", "time": "2026-11-01T07:30:00", "systolic": 135, "diastolic": 80},
          {"type": "weight", "time": "2026-11-01T06:30:00", "weight_kg": 66.5},
          {"type": "lab", "time": "2026-10-30T09:00:00", "lab": {"hba1c": 7.3}}]
    assert client.post("/api/v1/care/profile", json={"events": ok}).status_code == 200


# ---------- 多设备写入：带版本时检测冲突 ----------

@pytest.fixture
def acct(tmp_path, monkeypatch):
    monkeypatch.setenv("MEDILENS_DB", str(tmp_path / "accounts.db"))
    monkeypatch.delenv("API_TOKEN", raising=False)
    monkeypatch.delenv("ACCOUNTS_REQUIRE_TLS", raising=False)
    c = TestClient(app)
    tok = c.post("/api/v1/auth/register", json={"username": "conflict_user", "password": "secret-pass-123"}).json()["token"]
    return c, {"Authorization": f"Bearer {tok}"}


def test_settings_conflict_detected_with_base_version(acct):
    c, h = acct
    url = "/api/v1/store/settings/life_events"
    first = c.put(url, json={"value": "[]"}, headers=h).json()
    base = first["updated_at"]
    assert c.get("/api/v1/store/settings-versions", headers=h).json()["life_events"] == pytest.approx(base)
    a = '[{"id":"A","type":"glucose","time":"2026-11-01T08:00:00","glucose":6.0}]'
    b = '[{"id":"B","type":"glucose","time":"2026-11-01T09:00:00","glucose":7.0}]'
    ra = c.put(url, json={"value": a, "base": base}, headers=h)      # 设备 A 先写
    assert ra.status_code == 200
    rb = c.put(url, json={"value": b, "base": base}, headers=h)      # 设备 B 用旧版本写：冲突
    assert rb.status_code == 409
    detail = rb.json()["detail"]
    assert detail["value"] == a and detail["updated_at"] == pytest.approx(ra.json()["updated_at"])
    assert c.get("/api/v1/store/settings", headers=h).json()["life_events"] == a   # A 的记录没有被覆盖
    # 不带版本（旧版 APP）照旧覆盖
    assert c.put(url, json={"value": b}, headers=h).status_code == 200
