"""解读总览：标准化 → 规则 → 安全提示 → 下一题。

总览原则：高风险置顶；紧急提示不等待问卷或大模型；未知数据不自动变绿。
"""
from __future__ import annotations

from pydantic import BaseModel, Field

from .followup import Question, load_questions, next_question, urgent_symptoms
from .normalize import detect_report_type, load_dictionary, normalize_items
from .rules_engine import LEVEL_ORDER, build_context, run_rules
from .schemas import AnalyzeRequest, ItemStatus, LabItemOut, Level, NotEvaluable, RuleHit

DISCLAIMER = "本结果仅帮助理解报告，不能替代医生诊断。当前使用测试规则，未经医学审核，请勿据此用药或调整治疗。"
TEST_RULE_BADGE = "测试规则，未经医学审核"

KEY_ITEMS = {
    "urinalysis": ["GLU", "KET", "PRO", "LEU", "NIT"],
    "uacr": ["UACR"],
    "urinalysis+uacr": ["GLU", "KET", "PRO", "LEU", "NIT", "UACR"],
}

LEVEL_LABELS = {
    Level.red: "建议尽快就医",
    Level.yellow: "建议近期复诊时咨询医生",
    Level.green: "常规关注",
    Level.unknown: "部分信息无法判断",
}

URGENT_MESSAGE = "如出现恶心、呕吐、腹痛、呼吸深快、明显乏力或意识模糊，请立即就医或拨打 120。"


class UrgentAlert(BaseModel):
    show: bool
    message: str = ""
    reasons: list[str] = Field(default_factory=list)


class Overall(BaseModel):
    level: Level
    label: str
    explanation: str


class Counts(BaseModel):
    total: int
    recognized: int  # 可用于判读的项目
    abnormal: int
    unknown: int


class AnalyzeResponse(BaseModel):
    disclaimer: str = DISCLAIMER
    is_test_rules: bool = True
    badge: str = TEST_RULE_BADGE
    versions: dict[str, str]
    report_type: str
    supported: bool
    unsupported_message: str | None = None
    items: list[LabItemOut]
    counts: Counts
    urgent_alert: UrgentAlert
    overall: Overall
    hits: list[RuleHit]
    not_evaluable: list[NotEvaluable]
    uncovered_abnormal: list[str]  # 超出参考范围但没有规则覆盖：无法据此判断
    missing_key_items: list[str]
    doctor_questions: list[str]
    next_question: Question | None


def analyze(req: AnalyzeRequest) -> AnalyzeResponse:
    items = normalize_items(req.report.items)
    report_type = detect_report_type(items)
    if req.report.report_type not in ("auto", report_type) and report_type != "unsupported":
        report_type = req.report.report_type
    versions = {
        "dictionary": load_dictionary()["version"],
        "questions": load_questions()["version"],
    }
    counts = Counts(
        total=len(items),
        recognized=sum(1 for i in items if i.usable),
        abnormal=sum(1 for i in items if i.status == ItemStatus.abnormal and i.usable),
        unknown=sum(1 for i in items if not i.usable),
    )

    if report_type == "unsupported":
        from .rules_engine import load_rules

        versions["rules"] = load_rules()["version"]
        return AnalyzeResponse(
            versions=versions,
            report_type=report_type,
            supported=False,
            unsupported_message="未识别到尿常规或 UACR 项目。当前版本只支持尿常规与尿白蛋白/肌酐比（UACR）报告，无法解读这份报告。",
            items=items,
            counts=counts,
            urgent_alert=UrgentAlert(show=False),
            overall=Overall(level=Level.unknown, label="无法解读", explanation="非支持的报告类型"),
            hits=[],
            not_evaluable=[],
            uncovered_abnormal=[],
            missing_key_items=[],
            doctor_questions=[],
            next_question=None,
        )

    ctx = build_context(items, req.answers, req.history, req.report.test_date)
    result = run_rules(ctx)
    versions["rules"] = result.version

    # 紧急提示：命中紧急规则或选择题中报告了危险症状，立即置顶
    reasons = [h.title for h in result.hits if h.urgent]
    symptoms = urgent_symptoms(req.answers)
    if symptoms:
        reasons.append("您报告了：" + "、".join(symptoms))
    urgent = UrgentAlert(show=bool(reasons), message=URGENT_MESSAGE if reasons else "", reasons=reasons)

    covered = {c for h in result.hits for c in h.related_items}
    uncovered = [i.name for i in items if i.usable and i.status == ItemStatus.abnormal and i.code not in covered]
    present = {i.code for i in items if i.usable}
    missing_key = [load_dictionary()["items"][c]["name"] for c in KEY_ITEMS.get(report_type, []) if c not in present]

    overall = _overall(result.hits, uncovered, missing_key, counts, bool(symptoms))
    doctor_qs: list[str] = []
    for h in result.hits:
        for q in h.doctor_questions:
            if q not in doctor_qs:
                doctor_qs.append(q)

    return AnalyzeResponse(
        versions=versions,
        report_type=report_type,
        supported=True,
        items=items,
        counts=counts,
        urgent_alert=urgent,
        overall=overall,
        hits=result.hits,
        not_evaluable=result.not_evaluable,
        uncovered_abnormal=uncovered,
        missing_key_items=missing_key,
        doctor_questions=doctor_qs,
        next_question=next_question(ctx),
    )


def _overall(hits: list[RuleHit], uncovered: list[str], missing_key: list[str], counts: Counts, urgent_symptom: bool) -> Overall:
    level = max((h.level for h in hits), key=lambda lv: LEVEL_ORDER[lv], default=None)
    if urgent_symptom:
        level = Level.red
    incomplete = bool(uncovered or missing_key or counts.unknown)
    if level is None or (level == Level.green and incomplete):
        # 未知数据不自动变绿
        if incomplete or counts.recognized == 0:
            parts = []
            if uncovered:
                parts.append("以下异常项目暂无规则覆盖，无法据此判断：" + "、".join(uncovered))
            if missing_key:
                parts.append("未识别到：" + "、".join(missing_key))
            if counts.unknown:
                parts.append(f"{counts.unknown} 个项目无法确认")
            return Overall(level=Level.unknown, label=LEVEL_LABELS[Level.unknown], explanation="；".join(parts))
        level = Level.green
    explanation = "根据已确认的指标和测试规则得出" + ("；部分信息缺失，结论可能不完整" if incomplete else "")
    return Overall(level=level, label=LEVEL_LABELS[level], explanation=explanation)
