"""账户与个人资料：密码不存原文、资料按用户隔离、错误次数锁定、只接受 HTTPS（部署设置）、可删除账户。"""
import sqlite3

import pytest
from fastapi.testclient import TestClient

from app import accounts
from app.main import app


@pytest.fixture()
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("MEDILENS_DB", str(tmp_path / "t.sqlite3"))
    monkeypatch.delenv("API_TOKEN", raising=False)
    monkeypatch.delenv("ACCOUNTS_REQUIRE_TLS", raising=False)
    accounts._fails.clear()
    return TestClient(app)


def signup(c, name="xiaoming", pw="synthetic-pass-1"):
    r = c.post("/api/v1/auth/register", json={"username": name, "password": pw})
    assert r.status_code == 200, r.text
    return {"Authorization": f"Bearer {r.json()['token']}"}


def test_register_login_and_password_never_stored_plain(client, tmp_path):
    h = signup(client)
    assert client.get("/api/v1/auth/me", headers=h).json()["username"] == "xiaoming"
    r = client.post("/api/v1/auth/login", json={"username": "XiaoMing", "password": "synthetic-pass-1"})
    assert r.status_code == 200  # 用户名不分大小写
    raw = (tmp_path / "t.sqlite3").read_bytes()
    assert b"synthetic-pass-1" not in raw and r.json()["token"].encode() not in raw  # 密码与令牌都不存原文


@pytest.mark.parametrize("name,pw,msg", [("ab", "synthetic-pass-1", "用户名"), ("bad name!", "synthetic-pass-1", "用户名"),
                                         ("xiaoming", "short", "至少 8"), ("password1", "password1", "相同")])
def test_register_validation(client, name, pw, msg):
    r = client.post("/api/v1/auth/register", json={"username": name, "password": pw})
    assert r.status_code == 422 and msg in r.json()["detail"]


def test_duplicate_username(client):
    signup(client)
    assert client.post("/api/v1/auth/register", json={"username": "XIAOMING", "password": "another-pass-2"}).status_code == 409


def test_login_lockout_after_repeated_failures(client):
    signup(client)
    for _ in range(5):
        assert client.post("/api/v1/auth/login", json={"username": "xiaoming", "password": "wrong-pass-0"}).status_code == 401
    r = client.post("/api/v1/auth/login", json={"username": "xiaoming", "password": "synthetic-pass-1"})
    assert r.status_code == 429


def test_store_is_per_user_and_requires_login(client):
    a, b = signup(client, "user_a"), signup(client, "user_b")
    assert client.get("/api/v1/store/settings").status_code == 401
    client.put("/api/v1/store/settings/life_events", json={"value": "[1]"}, headers=a)
    report = {"id": "r1", "test_date": "2026-11-01", "saved_at": "2026-11-01T08:00:00", "report_type": "urinalysis", "payload": "{}"}
    client.put("/api/v1/store/reports/r1", json=report, headers=a)
    assert client.get("/api/v1/store/settings", headers=a).json() == {"life_events": "[1]"}
    assert client.get("/api/v1/store/settings", headers=b).json() == {}
    assert client.get("/api/v1/store/reports", headers=b).json() == []
    assert client.get("/api/v1/store/reports", headers=a).json() == [report]
    client.delete("/api/v1/store/reports/r1", headers=b)  # 别人删不到
    assert len(client.get("/api/v1/store/reports", headers=a).json()) == 1
    client.delete("/api/v1/store/reports", headers=a)
    assert client.get("/api/v1/store/reports", headers=a).json() == []


def test_logout_and_delete_account_removes_everything(client, tmp_path):
    h = signup(client)
    client.put("/api/v1/store/settings/note", json={"value": "合成日记"}, headers=h)
    assert client.post("/api/v1/auth/delete-account", json={"password": "wrong-pass-0"}, headers=h).status_code == 401
    assert client.post("/api/v1/auth/delete-account", json={"password": "synthetic-pass-1"}, headers=h).json()["ok"]
    assert client.get("/api/v1/auth/me", headers=h).status_code == 401
    con = sqlite3.connect(tmp_path / "t.sqlite3")
    assert con.execute("SELECT COUNT(*) FROM settings").fetchone()[0] == 0
    h2 = signup(client, "user_c")
    client.post("/api/v1/auth/logout", headers=h2)
    assert client.get("/api/v1/auth/me", headers=h2).status_code == 401


def test_change_password(client):
    h = signup(client)
    assert client.post("/api/v1/auth/password", json={"password": "synthetic-pass-1", "new_password": "synthetic-pass-2"}, headers=h).json()["ok"]
    assert client.post("/api/v1/auth/login", json={"username": "xiaoming", "password": "synthetic-pass-2"}).status_code == 200


def test_accounts_reject_plain_http_when_tls_required(client, monkeypatch):
    monkeypatch.setenv("ACCOUNTS_REQUIRE_TLS", "true")
    r = client.post("/api/v1/auth/register", json={"username": "xiaoming", "password": "synthetic-pass-1"})
    assert r.status_code == 403 and "HTTPS" in r.json()["detail"]
    tls = TestClient(app, base_url="https://testserver")
    assert tls.post("/api/v1/auth/register", json={"username": "xiaoming", "password": "synthetic-pass-1"}).status_code == 200
    assert client.get("/api/v1/health").status_code == 200  # 解读等其他功能不受影响


def test_size_limit(client):
    h = signup(client)
    assert client.put("/api/v1/store/settings/big", json={"value": "x" * 2_000_001}, headers=h).status_code == 413


def test_tls_cert_endpoint_is_public_and_safe_when_missing(client, monkeypatch):
    monkeypatch.setenv("API_TOKEN", "synthetic-code")
    r = client.get("/api/v1/tls-cert")  # 不需要访问口令
    assert r.status_code == 200 and "available" in r.json()
    assert "key" not in r.text.lower() or "private" not in r.text.lower()  # 只会给公开证书，不会给私钥
