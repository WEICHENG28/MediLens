"""MediLens 后端入口。

只接收端侧识别并经用户确认的结构化指标；不接收原始报告图像（云 OCR 待实现，且仅注册用户授权后可用）。
"""
from __future__ import annotations

import hmac
import os
from typing import Any

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from . import config  # noqa: F401  加载 .env
from .analysis import AnalyzeResponse, analyze
from .chat import ChatRequest, ChatResponse, ExplainRequest, ExplainResponse, chat, explain
from .followup import validate_answer
from .llm import get_provider
from .pending import router as pending_router
from .lifestyle import LifestyleRequest, LifestyleResponse, analyze_lifestyle
from .schemas import AnalyzeRequest

app = FastAPI(title="MediLens API", version="0.2.0", docs_url="/docs", redoc_url=None)
app.include_router(pending_router)


@app.middleware("http")
async def require_token(request: Request, call_next):
    """设置了 API_TOKEN（部署到共享网络时）就要求请求带上访问口令；健康检查除外。本机开发不设即不检查。"""
    token = os.environ.get("API_TOKEN", "")
    if token and request.url.path.startswith("/api/") and request.url.path != "/api/v1/health":
        if not hmac.compare_digest(request.headers.get("X-MediLens-Token", ""), token):
            return JSONResponse(status_code=401, content={"message": "访问口令不正确"})
    return await call_next(request)


@app.get("/api/v1/health")
def health() -> dict[str, Any]:
    return {"status": "ok", "service": "medilens", "test_rules": True, "llm_provider": get_provider().name}


@app.post("/api/v1/analyze", response_model=AnalyzeResponse)
def analyze_report(req: AnalyzeRequest) -> AnalyzeResponse:
    for qid, ans in req.answers.items():
        err = validate_answer(qid, ans)
        if err:
            raise HTTPException(status_code=422, detail=f"{qid}: {err}")
    return analyze(req)


class AnswerCheck(BaseModel):
    question_id: str
    answer: Any


@app.post("/api/v1/followup/validate")
def check_answer(body: AnswerCheck) -> dict[str, Any]:
    err = validate_answer(body.question_id, body.answer)
    return {"ok": err is None, "error": err}


def _check_answers(req: AnalyzeRequest) -> None:
    for qid, ans in req.answers.items():
        err = validate_answer(qid, ans)
        if err:
            raise HTTPException(status_code=422, detail=f"{qid}: {err}")


@app.post("/api/v1/explain", response_model=ExplainResponse)
def explain_item(req: ExplainRequest) -> ExplainResponse:
    _check_answers(req.analysis)
    return explain(req)


@app.post("/api/v1/chat", response_model=ChatResponse)
def chat_message(req: ChatRequest) -> ChatResponse:
    _check_answers(req.analysis)
    return chat(req)


@app.post("/api/v1/lifestyle", response_model=LifestyleResponse)
def lifestyle(req: LifestyleRequest) -> LifestyleResponse:
    """生活作息 × 血糖规律、陪伴宠物状态与提醒（原型）。只接收打卡记录，不含身份信息。"""
    return analyze_lifestyle(req)


class LifestyleDemoRequest(BaseModel):
    days: int = 14
    today: str | None = None  # YYYY-MM-DD，示例数据以此为最后一天


@app.post("/api/v1/lifestyle/demo")
def lifestyle_demo(req: LifestyleDemoRequest) -> dict[str, Any]:
    """演示用：生成以 today 为最后一天的模拟打卡记录（合成数据，植入已知规律）。"""
    from datetime import date, timedelta

    import random

    from .lifestyle_sim import SCHEDULE, TRUE_RATES, simulate, simulate_reminders

    days = max(3, min(req.days, 60))
    end = date.fromisoformat(req.today) if req.today else date.today()
    start = end - timedelta(days=days - 1)
    rng = random.Random(7)
    reminders, _ = simulate_reminders(days, 7, lambda task, ev: rng.choice(list(TRUE_RATES[task])), start=start)
    events = simulate(days, seed=7, start=start, miss_rate=0.02) + reminders
    return {"synthetic": True, "events": [e.model_dump(mode="json", exclude_none=True) for e in events],
            "schedule": [s.model_dump() for s in SCHEDULE]}
