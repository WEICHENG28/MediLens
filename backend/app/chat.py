"""逐条「详细了解」与文字对话。

流程：服务端重跑标准化+规则（不信任客户端传来的结论）→ 越界问题走安全模板 → 组装基于规则与知识的草稿
→ 大模型只做通俗改写 → 输出校验 → 不通过则回退草稿。大模型不能新增风险结论。
"""
from __future__ import annotations

import json
import re

from pydantic import BaseModel, Field

from . import guard, knowledge
from .analysis import DISCLAIMER, AnalyzeResponse, analyze
from .knowledge import Citation
from .llm import LLMError, get_provider
from .schemas import AnalyzeRequest, Level

SYSTEM_PROMPT = (
    "你是 MediLens 的报告解释助手，面向糖尿病患者与家属，用简体中文、通俗短句回答。"
    "只能改写【草稿】中的内容，使其更易懂；不得新增任何医学结论、风险等级、数值或用药建议；"
    "不得建议停药、换药、调整剂量，不得做出诊断；医生医嘱优先。回答不超过 150 字。"
)


class ExplainRequest(BaseModel):
    analysis: AnalyzeRequest
    target: str  # 规则编号（如 R-01）或指标代码（如 PRO）


class ExplainSection(BaseModel):
    heading: str
    body: str


class ExplainResponse(BaseModel):
    target: str
    title: str
    short: str
    sections: list[ExplainSection]
    citations: list[Citation]
    doctor_questions: list[str]
    disclaimer: str = DISCLAIMER


class ChatTurn(BaseModel):
    role: str  # user / assistant
    content: str


class ChatRequest(BaseModel):
    analysis: AnalyzeRequest
    message: str = Field(max_length=500)
    focus: str | None = None  # 当前查看的规则或指标
    quick: str | None = None  # what / related / doctor：快捷问题
    history: list[ChatTurn] = Field(default_factory=list, max_length=20)


class ChatResponse(BaseModel):
    answer: str
    safety_category: str | None = None  # medication / diagnosis / emergency
    citations: list[Citation] = Field(default_factory=list)
    provider: str
    used_fallback: bool
    no_evidence: bool = False
    disclaimer: str = DISCLAIMER


# ---------- 详细了解 ----------

def explain(req: ExplainRequest) -> ExplainResponse:
    res = analyze(req.analysis)
    hit = next((h for h in res.hits if h.rule_id == req.target), None)
    if hit:
        cites = [c for c in (knowledge.get(i) for i in hit.evidence_ids) if c]
        related = [i for i in res.items if i.code in hit.related_items]
        rel_text = "；".join(f"{i.name}：{i.raw_value or '未识别'}{(' ' + i.unit) if i.unit else ''}" for i in related)
        sections = [
            ExplainSection(heading="为什么出现这条提示", body=hit.detail),
            ExplainSection(heading="相关指标", body=rel_text or "无"),
            ExplainSection(heading="依据", body=f"{hit.rule_id}（{hit.review_status}）；参考资料为占位说明，非指南原文"),
        ]
        return ExplainResponse(target=hit.rule_id, title=hit.title, short=hit.summary, sections=sections,
                               citations=cites, doctor_questions=hit.doctor_questions)

    item = next((i for i in res.items if i.code == req.target.upper()), None)
    if item is None:
        return ExplainResponse(target=req.target, title="未找到", short="报告中没有这一项，无法解释。",
                               sections=[], citations=[], doctor_questions=[])
    cites = knowledge.search(codes=[item.code], limit=2)
    related_hits = [h for h in res.hits if item.code in h.related_items]
    value = f"{item.raw_value or '未识别'}{(' ' + item.unit) if item.unit else ''}"
    short = f"{item.name}：{value}（{_status_text(item)}）"
    sections = [ExplainSection(heading="这个指标是什么", body=cites[0].text if cites else "暂无可核验的资料。")]
    if item.conversion_note:
        sections.append(ExplainSection(heading="单位换算", body=item.conversion_note))
    sections.append(ExplainSection(heading="判断依据", body=item.status_reason or "—"))
    if related_hits:
        sections.append(ExplainSection(heading="与其他指标的关系", body="；".join(h.summary for h in related_hits)))
    dq = [q for h in related_hits for q in h.doctor_questions]
    return ExplainResponse(target=item.code, title=item.name, short=short, sections=sections, citations=cites, doctor_questions=dq)


def _status_text(item) -> str:
    if not item.usable:
        return "无法确认，不参与判断"
    return {"normal": "在报告参考范围内", "abnormal": "超出报告参考范围", "unknown": "无法与参考范围比对"}[item.status.value]


# ---------- 对话 ----------

_MED = re.compile(r"停药|不吃药|减药|减量|加量|加药|换药|换个药|剂量")
# 药名/药物类别词表（占位，后续由药盒识别与医学审核扩充）
_DRUG = re.compile(r"药|格列净|格列|二甲双胍|胰岛素|列汀|鲁肽|阿卡波糖|SGLT2", re.I)
_DRUG_ACTION = re.compile(r"停|不吃|别吃|还吃|要不要吃|继续吃|换|减|加|少吃|多吃|少打|多打")
_DIAG = re.compile(r"(是不是|是否|会不会|有没有|算不算|能确诊|确诊).*(肾衰|尿毒症|肾病|肾功能衰竭|糖尿病|癌|肾损|病)|确诊")
_EMERG = re.compile(r"(呼吸困难|喘不过气|呼吸很快|昏迷|意识模糊|叫不醒|一直吐|呕吐|剧烈腹痛|肚子很痛|胸痛|抽搐)")


def classify(message: str, res: AnalyzeResponse) -> str | None:
    """越界/安全分类：结合关键词与报告上下文（如酮体阳性时的呕吐描述）。"""
    if _EMERG.search(message):
        return "emergency"
    if _MED.search(message) or (_DRUG.search(message) and _DRUG_ACTION.search(message)):
        return "medication"
    if _DIAG.search(message):
        return "diagnosis"
    return None


def _safety_answer(category: str, res: AnalyzeResponse) -> str:
    if category == "emergency":
        return ("您描述的情况可能需要紧急处理。请立即就医或拨打 120，不要等待软件解读。"
                "就医时带上这份报告。")
    if category == "medication":
        extra = ""
        if any(h.rule_id == "R-02" for h in res.hits):
            extra = "您报告中的尿糖阳性可能与正在使用的降糖药有关，这本身不代表需要停药。"
        return (extra + "是否停药、换药或调整剂量，必须由您的医生决定，请不要自行改变用药。"
                "如果医生已有医嘱，请以医嘱为准；可以把疑问记下来在复诊时询问。")
    kidney = [h.summary for h in res.hits if set(h.related_items) & {"PRO", "UACR"}]
    basis = ("本次与肾脏相关的提示：" + "；".join(kidney)) if kidney else "本次报告没有命中与肾脏相关的测试规则。"
    return ("仅凭一份尿检报告不能判断是否患有某种疾病，诊断需要医生结合血液检查、重复检测和病史评估。"
            + basis + "建议复诊时直接向医生提出这个问题。")


def _draft(req: ChatRequest, res: AnalyzeResponse) -> tuple[str, list[Citation]]:
    focus = (req.focus or "").upper()
    hit = next((h for h in res.hits if h.rule_id.upper() == focus), None)
    item = next((i for i in res.items if i.code and i.code == focus), None)
    codes = hit.related_items if hit else ([item.code] if item else [])

    if req.quick == "doctor":
        qs = (hit.doctor_questions if hit else res.doctor_questions) or ["这份报告有哪些需要我注意的地方？"]
        return "复诊时可以问医生：\n" + "\n".join(f"· {q}" for q in qs), []
    if req.quick == "related":
        if hit:
            names = [i.name for i in res.items if i.code in hit.related_items]
            return f"这条提示与{ '、'.join(names) }有关：{hit.summary}", knowledge.search(codes=codes)
        if item:
            hs = [h for h in res.hits if item.code in h.related_items]
            if hs:
                return "；".join(h.summary for h in hs), knowledge.search(codes=[item.code])
            return f"本次报告中，{item.name}没有与其他指标一起触发测试规则。", knowledge.search(codes=[item.code])

    cites = knowledge.search(query=req.message, codes=codes)
    parts = []
    if hit:
        parts.append(hit.summary)
    if item:
        parts.append(f"您的{item.name}结果是 {item.raw_value or '未识别'}{(' ' + item.unit) if item.unit else ''}，{_status_text(item)}。")
    if cites:
        parts.append(cites[0].text)
    if not parts:
        return "", []
    return "".join(parts), cites


def _facts_text(res: AnalyzeResponse, draft: str, cites: list[Citation]) -> str:
    facts = {
        "items": [{"name": i.name, "raw": i.raw_value, "unit": i.unit, "normalized": i.normalized_value,
                   "ref": i.reference_text, "usable": i.usable} for i in res.items],
        "hits": [{"id": h.rule_id, "summary": h.summary, "detail": h.detail} for h in res.hits],
    }
    return json.dumps(facts, ensure_ascii=False) + "\n" + "\n".join(c.text for c in cites) + "\n" + draft


def chat(req: ChatRequest) -> ChatResponse:
    res = analyze(req.analysis)
    provider = get_provider()
    category = classify(req.message, res)
    if category:
        return ChatResponse(answer=_safety_answer(category, res), safety_category=category,
                            provider="safety-template", used_fallback=False)

    draft, cites = _draft(req, res)
    if not draft:
        return ChatResponse(
            answer="这个问题暂时没有可核验的资料，我无法据此回答。建议把问题记下来，复诊时询问医生。",
            provider="template", used_fallback=False, no_evidence=True)

    facts = _facts_text(res, draft, cites)
    user = f"报告事实：\n{facts}\n\n用户问题：{req.message}\n\n【草稿】{draft}"
    urgent_allowed = res.urgent_alert.show or res.overall.level == Level.red
    try:
        text = provider.complete(SYSTEM_PROMPT, user)
        result = guard.check(text, facts, urgent_allowed)
        if result.ok:
            return ChatResponse(answer=text, citations=cites, provider=provider.name, used_fallback=False)
    except LLMError:
        pass
    # 校验失败或服务不可用：回退到基于规则与知识的草稿
    return ChatResponse(answer=draft, citations=cites, provider=provider.name, used_fallback=True)
