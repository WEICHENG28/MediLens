"""确定性规则引擎（三值逻辑）。

每个条件返回 True / False / None（信息缺失，无法判断），并收集缺失的信息。
规则命中 = 条件为 True；条件为 None 的规则记入「无法判断」，绝不当作未命中/正常。
大模型不参与本模块。
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, timedelta
from functools import lru_cache
from pathlib import Path
from typing import Any

import yaml

from .normalize import load_dictionary, normalize_items
from .schemas import HistoryReport, LabItemOut, Level, NotEvaluable, Positivity, RuleHit

RULES_PATH = Path(__file__).parent / "knowledge_base" / "rules.yaml"

# 选择题的「非实质回答」：不能当作否定
NON_ANSWERS = {"__unknown__", "__decline__", "__skip__"}



def is_non_answer(ans: Any) -> bool:
    """未答、不确定、不愿透露、跳过：都不能当作否定。"""
    return ans is None or (isinstance(ans, str) and ans in NON_ANSWERS) or ans == []


LEVEL_ORDER = {Level.red: 3, Level.yellow: 2, Level.green: 1, Level.unknown: 0}


@lru_cache
def load_rules() -> dict:
    with open(RULES_PATH, encoding="utf-8") as f:
        return yaml.safe_load(f)


@dataclass
class Context:
    items: dict[str, LabItemOut]  # 本次报告，按代码索引（包含不可用项）
    answers: dict[str, Any]
    history: list[tuple[str, dict[str, LabItemOut]]]  # (日期, 指标)
    test_date: str | None
    missing: set[str] = field(default_factory=set)

    def item_name(self, code: str) -> str:
        meta = load_dictionary()["items"].get(code)
        return meta["name"] if meta else code


def build_context(items: list[LabItemOut], answers: dict, history: list[HistoryReport], test_date: str | None) -> Context:
    by_code = {i.code: i for i in items if i.code}
    hist = []
    for h in history:
        hist.append((h.test_date, {i.code: i for i in normalize_items(h.items) if i.code and i.usable}))
    hist.sort(key=lambda x: x[0])
    return Context(items=by_code, answers=answers, history=hist, test_date=test_date)


def _usable(ctx: Context, code: str) -> LabItemOut | None:
    it = ctx.items.get(code)
    if it is None or not it.usable:
        reason = "未识别到" if it is None else "未确认或无法使用"
        ctx.missing.add(f"{ctx.item_name(code)}（{reason}）")
        return None
    return it


def evaluate(cond: dict, ctx: Context) -> bool | None:
    if "all" in cond:
        results = [evaluate(c, ctx) for c in cond["all"]]
        if any(r is False for r in results):
            return False
        return None if any(r is None for r in results) else True
    if "any" in cond:
        results = [evaluate(c, ctx) for c in cond["any"]]
        if any(r is True for r in results):
            return True
        return None if any(r is None for r in results) else False
    if "item" in cond:
        return _eval_item(cond, ctx)
    if "first_elevation" in cond:
        return _eval_first_elevation(cond, ctx)
    if "answer" in cond:
        ans = ctx.answers.get(cond["answer"])
        if is_non_answer(ans):
            ctx.missing.add(f"问题「{cond['answer']}」未回答或不确定")
            return None
        values = ans if isinstance(ans, list) else [ans]
        return any(v in cond["in"] for v in values)
    if "grade_rise" in cond:
        return _eval_grade_rise(cond, ctx)
    if "no_recent" in cond:
        return _eval_no_recent(cond, ctx)
    raise ValueError(f"未知条件：{cond}")


def _eval_item(cond: dict, ctx: Context) -> bool | None:
    it = _usable(ctx, cond["item"])
    if it is None:
        return None
    if "positivity" in cond:
        want = cond["positivity"]
        if it.positivity == Positivity.unknown:
            ctx.missing.add(f"{it.name}（无法判断阴阳性）")
            return None
        if want == "trace_or_positive":
            return it.positivity in (Positivity.trace, Positivity.positive)
        return it.positivity.value == want
    v = it.normalized_value
    if v is None:
        ctx.missing.add(f"{it.name}（无可用数值）")
        return None
    if "gte" in cond:
        return v >= cond["gte"]
    if "lt" in cond:
        return v < cond["lt"]
    raise ValueError(f"未知条件：{cond}")


def _eval_grade_rise(cond: dict, ctx: Context) -> bool | None:
    code = cond["grade_rise"]
    it = _usable(ctx, code)
    if it is None or it.grade is None:
        return None
    prior = [h[code].grade for _, h in ctx.history if code in h and h[code].grade is not None]
    if not prior:
        ctx.missing.add(f"本机历史中没有可比较的{ctx.item_name(code)}记录")
        return None
    return min(prior) <= cond["from_max"] and it.grade >= cond["to_min"]


def _parse_date(s: str | None) -> date | None:
    try:
        return date.fromisoformat(s) if s else None
    except ValueError:
        return None


def _eval_no_recent(cond: dict, ctx: Context) -> bool | None:
    code = cond["no_recent"]
    cur = ctx.items.get(code)
    if cur is not None and cur.usable:
        return False
    ref = _parse_date(ctx.test_date) or date.today()
    since = ref - timedelta(days=cond["days"])
    for d, items in ctx.history:
        dd = _parse_date(d)
        if dd and dd >= since and code in items:
            return False
    return True


def _eval_first_elevation(cond: dict, ctx: Context) -> bool | None:
    code, thr = cond["first_elevation"], cond["threshold"]
    prior = [h[code].normalized_value for _, h in ctx.history if code in h and h[code].normalized_value is not None]
    if prior:
        return all(v < thr for v in prior)
    ans = ctx.answers.get(cond["answer"])
    if is_non_answer(ans):
        ctx.missing.add(f"不清楚以前是否查过{ctx.item_name(code)}升高（本机无历史记录）")
        return None
    return ans == "first"


@dataclass
class RuleResult:
    hits: list[RuleHit]
    not_evaluable: list[NotEvaluable]
    version: str


def run_rules(ctx: Context) -> RuleResult:
    data = load_rules()
    hits: list[RuleHit] = []
    not_eval: list[NotEvaluable] = []
    for rule in data["rules"]:
        ctx.missing = set()
        if any(code not in ctx.items for code in rule.get("applies_if_present", [])):
            continue  # 报告中没有该项目：规则不适用
        result = evaluate(rule["when"], ctx)
        if result is True:
            hits.append(
                RuleHit(
                    rule_id=rule["id"],
                    title=rule["title"],
                    level=Level(rule["level"]),
                    priority=rule["priority"],
                    summary=rule["summary"],
                    detail=rule["detail"].strip(),
                    doctor_questions=rule.get("doctor_questions", []),
                    evidence_ids=rule.get("evidence_ids", []),
                    related_items=rule.get("related_items", []),
                    review_status=data["review_status"],
                    urgent=bool(rule.get("urgent")),
                    followup_task=rule.get("followup_task"),
                )
            )
        elif result is None and not rule.get("silent_if_missing"):
            not_eval.append(
                NotEvaluable(
                    rule_id=rule["id"],
                    title=rule["title"],
                    missing=sorted(ctx.missing),
                    note="因信息缺失无法判断，不代表正常",
                )
            )
    hits.sort(key=lambda h: (-LEVEL_ORDER[h.level], -h.priority))
    return RuleResult(hits=hits, not_evaluable=not_eval, version=data["version"])
