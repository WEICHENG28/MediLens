"""用户账户与个人资料存储（用户名 + 密码）。

- 登入后，APP 的报告、打卡、血糖、日记与设置都存在服务器，按用户分开；手机 / 网页只暂存当下画面。
- 密码只存 scrypt 杂凑（加盐），不存原文；登入后发放随机会话令牌，服务器只存令牌的 SHA-256。
- 连续输错密码 5 次锁定 10 分钟。可随时删除账户（连同全部资料）。
- 部署时设 ACCOUNTS_REQUIRE_TLS=true：账户与资料接口只接受 HTTPS，避免密码与健康资料明文传输。
- 资料库：SQLite（标准库），路径 MEDILENS_DB，默认 backend/data/medilens.sqlite3（不入库）。
"""
from __future__ import annotations

import hashlib
import hmac
import os
import re
import secrets
import sqlite3
import threading
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Depends, Header, HTTPException, Request
from pydantic import BaseModel, Field

SESSION_DAYS = 30
MAX_FAILS, LOCK_SECONDS = 5, 600
MAX_VALUE = 2_000_000  # 单个设置值 / 报告的上限（字节）
USERNAME = re.compile(r"^[A-Za-z0-9_一-鿿]{3,32}$")

router = APIRouter(prefix="/api/v1")
_lock = threading.Lock()
_fails: dict[str, list[float]] = {}


def db_path() -> Path:
    return Path(os.environ.get("MEDILENS_DB") or Path(__file__).resolve().parents[1] / "data" / "medilens.sqlite3")


@contextmanager
def _db():
    path = db_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(path, timeout=10)
    con.execute("PRAGMA foreign_keys = ON")
    try:
        with con:
            con.executescript("""
                CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, username TEXT UNIQUE NOT NULL COLLATE NOCASE,
                  pw_hash TEXT NOT NULL, created_at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS sessions (token_hash TEXT PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                  expires_at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS settings (user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE, key TEXT NOT NULL,
                  value TEXT NOT NULL, updated_at REAL NOT NULL, PRIMARY KEY (user_id, key));
                CREATE TABLE IF NOT EXISTS reports (user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE, id TEXT NOT NULL,
                  row TEXT NOT NULL, updated_at REAL NOT NULL, PRIMARY KEY (user_id, id));
            """)
        yield con
        con.commit()
    finally:
        con.close()


# ---------- 密码 ----------
def hash_password(pw: str) -> str:
    salt = secrets.token_bytes(16)
    dk = hashlib.scrypt(pw.encode(), salt=salt, n=2 ** 14, r=8, p=1, dklen=32)
    return f"scrypt${salt.hex()}${dk.hex()}"


def check_password(pw: str, stored: str) -> bool:
    try:
        _, salt, dk = stored.split("$")
        got = hashlib.scrypt(pw.encode(), salt=bytes.fromhex(salt), n=2 ** 14, r=8, p=1, dklen=32)
        return hmac.compare_digest(got.hex(), dk)
    except ValueError:
        return False


def _token_hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def _new_session(con: sqlite3.Connection, user_id: int) -> str:
    token = secrets.token_urlsafe(32)
    con.execute("INSERT INTO sessions VALUES (?, ?, ?)", (_token_hash(token), user_id, time.time() + SESSION_DAYS * 86400))
    con.execute("DELETE FROM sessions WHERE expires_at < ?", (time.time(),))
    return token


# ---------- 传输安全 ----------
def require_tls(request: Request) -> None:
    if os.environ.get("ACCOUNTS_REQUIRE_TLS", "").lower() == "true" and request.url.scheme != "https":
        raise HTTPException(status_code=403, detail="账户与个人资料只能通过加密连接（HTTPS）使用，请更新 APP 或改用 https 网址。")


class User(BaseModel):
    id: int
    username: str


def current_user(authorization: str = Header(default=""), _: None = Depends(require_tls)) -> User:
    token = authorization.removeprefix("Bearer ").strip()
    if not token:
        raise HTTPException(status_code=401, detail="请先登入")
    with _db() as con:
        row = con.execute("SELECT u.id, u.username FROM sessions s JOIN users u ON u.id = s.user_id "
                          "WHERE s.token_hash = ? AND s.expires_at > ?", (_token_hash(token), time.time())).fetchone()
    if not row:
        raise HTTPException(status_code=401, detail="登入已过期，请重新登入")
    return User(id=row[0], username=row[1])


# ---------- 账户 ----------
class Credentials(BaseModel):
    username: str = Field(min_length=1, max_length=64)
    password: str = Field(min_length=1, max_length=128)


class AuthResult(BaseModel):
    token: str
    username: str


def _validate(c: Credentials) -> None:
    if not USERNAME.match(c.username):
        raise HTTPException(status_code=422, detail="用户名需 3–32 个字，只能用中文、英文字母、数字或底线")
    if len(c.password) < 8:
        raise HTTPException(status_code=422, detail="密码至少 8 个字")
    if c.password.lower() == c.username.lower():
        raise HTTPException(status_code=422, detail="密码不能和用户名相同")


@router.post("/auth/register", response_model=AuthResult, dependencies=[Depends(require_tls)])
def register(c: Credentials) -> AuthResult:
    _validate(c)
    with _db() as con:
        try:
            cur = con.execute("INSERT INTO users (username, pw_hash, created_at) VALUES (?, ?, ?)",
                              (c.username, hash_password(c.password), time.time()))
        except sqlite3.IntegrityError:
            raise HTTPException(status_code=409, detail="这个用户名已经有人用了，请换一个") from None
        return AuthResult(token=_new_session(con, cur.lastrowid), username=c.username)


def _throttled(key: str) -> bool:
    now = time.time()
    with _lock:
        recent = [t for t in _fails.get(key, []) if now - t < LOCK_SECONDS]
        _fails[key] = recent
        return len(recent) >= MAX_FAILS


def _record_fail(key: str) -> None:
    with _lock:
        _fails.setdefault(key, []).append(time.time())


@router.post("/auth/login", response_model=AuthResult, dependencies=[Depends(require_tls)])
def login(c: Credentials) -> AuthResult:
    key = c.username.lower()
    if _throttled(key):
        raise HTTPException(status_code=429, detail="密码错误次数太多，请 10 分钟后再试")
    with _db() as con:
        row = con.execute("SELECT id, username, pw_hash FROM users WHERE username = ?", (c.username,)).fetchone()
        if not row or not check_password(c.password, row[2]):
            _record_fail(key)
            raise HTTPException(status_code=401, detail="用户名或密码不正确")
        with _lock:
            _fails.pop(key, None)
        return AuthResult(token=_new_session(con, row[0]), username=row[1])


@router.get("/auth/me", response_model=User)
def me(user: User = Depends(current_user)) -> User:
    return user


@router.post("/auth/logout")
def logout(authorization: str = Header(default=""), _: User = Depends(current_user)) -> dict[str, bool]:
    with _db() as con:
        con.execute("DELETE FROM sessions WHERE token_hash = ?", (_token_hash(authorization.removeprefix("Bearer ").strip()),))
    return {"ok": True}


class PasswordCheck(BaseModel):
    password: str = Field(min_length=1, max_length=128)


class PasswordChange(PasswordCheck):
    new_password: str = Field(min_length=1, max_length=128)


@router.post("/auth/password")
def change_password(body: PasswordChange, user: User = Depends(current_user)) -> dict[str, bool]:
    _validate(Credentials(username=user.username, password=body.new_password))
    with _db() as con:
        stored = con.execute("SELECT pw_hash FROM users WHERE id = ?", (user.id,)).fetchone()[0]
        if not check_password(body.password, stored):
            raise HTTPException(status_code=401, detail="原密码不正确")
        con.execute("UPDATE users SET pw_hash = ? WHERE id = ?", (hash_password(body.new_password), user.id))
    return {"ok": True}


@router.post("/auth/delete-account")
def delete_account(body: PasswordCheck, user: User = Depends(current_user)) -> dict[str, bool]:
    """删除账户与全部资料（不可恢复），需再次输入密码。"""
    with _db() as con:
        stored = con.execute("SELECT pw_hash FROM users WHERE id = ?", (user.id,)).fetchone()[0]
        if not check_password(body.password, stored):
            raise HTTPException(status_code=401, detail="密码不正确")
        con.execute("DELETE FROM users WHERE id = ?", (user.id,))
    return {"ok": True}


# ---------- 个人资料（对应 APP 的 LocalStore：报告 + 设置） ----------
class Value(BaseModel):
    value: str


def _check_size(s: str) -> None:
    if len(s.encode()) > MAX_VALUE:
        raise HTTPException(status_code=413, detail="资料太大，无法保存")


@router.get("/store/settings")
def all_settings(user: User = Depends(current_user)) -> dict[str, str]:
    with _db() as con:
        return dict(con.execute("SELECT key, value FROM settings WHERE user_id = ?", (user.id,)).fetchall())


@router.put("/store/settings/{key}")
def put_setting(key: str, body: Value, user: User = Depends(current_user)) -> dict[str, bool]:
    if not 0 < len(key) <= 100:
        raise HTTPException(status_code=422, detail="设置名称不正确")
    _check_size(body.value)
    with _db() as con:
        con.execute("INSERT INTO settings VALUES (?, ?, ?, ?) ON CONFLICT(user_id, key) DO UPDATE SET value = excluded.value, "
                    "updated_at = excluded.updated_at", (user.id, key, body.value, time.time()))
    return {"ok": True}


@router.get("/store/reports")
def list_reports(user: User = Depends(current_user)) -> list[dict[str, Any]]:
    import json
    with _db() as con:
        return [json.loads(r[0]) for r in con.execute("SELECT row FROM reports WHERE user_id = ?", (user.id,)).fetchall()]


@router.put("/store/reports/{report_id}")
def put_report(report_id: str, body: dict[str, Any], user: User = Depends(current_user)) -> dict[str, bool]:
    import json
    if not 0 < len(report_id) <= 100 or body.get("id") != report_id:
        raise HTTPException(status_code=422, detail="报告编号不正确")
    raw = json.dumps(body, ensure_ascii=False)
    _check_size(raw)
    with _db() as con:
        con.execute("INSERT INTO reports VALUES (?, ?, ?, ?) ON CONFLICT(user_id, id) DO UPDATE SET row = excluded.row, "
                    "updated_at = excluded.updated_at", (user.id, report_id, raw, time.time()))
    return {"ok": True}


@router.delete("/store/reports/{report_id}")
def delete_report(report_id: str, user: User = Depends(current_user)) -> dict[str, bool]:
    with _db() as con:
        con.execute("DELETE FROM reports WHERE user_id = ? AND id = ?", (user.id, report_id))
    return {"ok": True}


@router.delete("/store/reports")
def delete_all_reports(user: User = Depends(current_user)) -> dict[str, bool]:
    with _db() as con:
        con.execute("DELETE FROM reports WHERE user_id = ?", (user.id,))
    return {"ok": True}
