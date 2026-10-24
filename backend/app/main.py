"""MediLens 后端入口。

只接收端侧识别并经用户确认的结构化指标；不接收原始报告图像（云 OCR 待实现，且仅注册用户授权后可用）。
"""
from __future__ import annotations

from typing import Any

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

from .analysis import AnalyzeResponse, analyze
from .followup import validate_answer
from .schemas import AnalyzeRequest

app = FastAPI(title="MediLens API", version="0.2.0", docs_url="/docs", redoc_url=None)


@app.get("/api/v1/health")
def health() -> dict[str, Any]:
    return {"status": "ok", "service": "medilens", "test_rules": True}


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
