"""动态选择题：根据报告与已答内容决定下一题。

服务端无状态：客户端每次提交全部已答内容，因此「回退修改答案」只需客户端改动答案后重新请求。
"""
from __future__ import annotations

from functools import lru_cache
from pathlib import Path
from typing import Any

import yaml
from pydantic import BaseModel

from .rules_engine import Context, evaluate, is_non_answer

QUESTIONS_PATH = Path(__file__).parent / "knowledge_base" / "questions.yaml"


class Option(BaseModel):
    id: str
    label: str
    exclusive: bool = False


class Question(BaseModel):
    question_id: str
    plain_language_prompt: str
    answer_type: str
    options: list[Option]
    allow_unknown: bool
    allow_decline: bool
    allow_skip: bool
    medical_rationale: str
    trigger_rule: str | None = None
    medication_photo_hint: bool = False
    urgent_options: list[str] = []
    review_status: str
    index: int  # 第几题（从 1 开始，按当前已触发题目计）
    total_triggered: int  # 当前已触发的题目数（可能随回答变化）


@lru_cache
def load_questions() -> dict:
    with open(QUESTIONS_PATH, encoding="utf-8") as f:
        return yaml.safe_load(f)


def triggered_questions(ctx: Context) -> list[dict]:
    out = []
    for q in load_questions()["questions"]:
        hist_code = q.get("skip_if_history")
        if hist_code and any(hist_code in items for _, items in ctx.history):
            continue
        if evaluate(q["trigger"], ctx) is True:
            out.append(q)
    return out


def next_question(ctx: Context) -> Question | None:
    data = load_questions()
    qs = triggered_questions(ctx)
    for idx, q in enumerate(qs, start=1):
        if q["question_id"] not in ctx.answers:
            return Question(
                **{k: v for k, v in q.items() if k in Question.model_fields},
                review_status=data["review_status"],
                index=idx,
                total_triggered=len(qs),
            )
    return None


def urgent_symptoms(answers: dict[str, Any]) -> list[str]:
    """回答中出现的需立即就医症状（测试规则）。"""
    found: list[str] = []
    for q in load_questions()["questions"]:
        urgent = set(q.get("urgent_options") or [])
        ans = answers.get(q["question_id"])
        if not urgent or is_non_answer(ans):
            continue
        values = ans if isinstance(ans, list) else [ans]
        labels = {o["id"]: o["label"] for o in q["options"]}
        found += [labels[v] for v in values if v in urgent]
    return found


def validate_answer(question_id: str, answer: Any) -> str | None:
    """返回错误信息；合法则返回 None。"""
    q = next((q for q in load_questions()["questions"] if q["question_id"] == question_id), None)
    if q is None:
        return f"未知题目 {question_id}"
    if isinstance(answer, str) and answer.startswith("__"):
        allowed = {"__unknown__": q["allow_unknown"], "__decline__": q["allow_decline"], "__skip__": q["allow_skip"]}
        if answer not in allowed:
            return "选项无效"
        return None if allowed[answer] else "该题不允许此回答"
    ids = {o["id"] for o in q["options"]}
    exclusive = {o["id"] for o in q["options"] if o.get("exclusive")}
    values = answer if isinstance(answer, list) else [answer]
    if q["answer_type"] == "single" and isinstance(answer, list):
        return "单选题只能选一个"
    if not values or any(v not in ids for v in values):
        return "选项无效"
    if len(values) > 1 and exclusive & set(values):
        return "「以上都没有」不能与其他选项同时选择"
    return None
