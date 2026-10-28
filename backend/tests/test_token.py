from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_no_token_configured_allows_requests(monkeypatch):
    monkeypatch.delenv("API_TOKEN", raising=False)
    assert client.post("/api/v1/chat", json={}).status_code == 422  # 未设口令：照常进入（这里因参数不全返回 422）


def test_token_required_when_configured(monkeypatch):
    monkeypatch.setenv("API_TOKEN", "abc123")
    assert client.get("/api/v1/health").status_code == 200  # 健康检查不需要口令
    r = client.post("/api/v1/chat", json={})
    assert r.status_code == 401 and r.json()["message"] == "访问口令不正确"
    assert client.post("/api/v1/chat", json={}, headers={"X-MediLens-Token": "wrong"}).status_code == 401
    assert client.post("/api/v1/chat", json={}, headers={"X-MediLens-Token": "abc123"}).status_code == 422
