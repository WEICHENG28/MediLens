"""逐条「详细了解」与文字对话。

流程：服务端重跑标准化+规则（不信任客户端传来的结论）→ 越界问题走安全模板 → 组装基于规则与知识的草稿
→ 大模型只做通俗改写 → 输出校验 → 不通过则回退草稿。大模型不能新增风险结论。
"""
from __future__ import annotations

import json
import re
from concurrent.futures import ThreadPoolExecutor

from opencc import OpenCC
from pydantic import BaseModel, Field

from . import guard, knowledge
from .analysis import DISCLAIMER, AnalyzeResponse, analyze
from .knowledge import Citation
from .llm import LLMError, get_intent_provider, get_provider
from .schemas import AnalyzeRequest, Level

_T2S = OpenCC("t2s")

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

# 意图识别（第二版）：按「对象词 × 意图词」组合判断，而不是逐句列关键词。
# 第一版（单一关键词）在 60 句测试集上拦截率仅 57.8%，见 docs/MVP2_测试结果.md。
# 词表为占位，需随药盒识别与医学审核扩充；后续计划增加模型分类作为第二道防线。

# 用药：药物/给药方式 × 用药决定
_DRUG = re.compile(r"药|片|针|胰岛素|格列|双胍|二甲|列净|列汀|鲁肽|阿卡波糖|利尿剂|消炎|抗生素|降糖|降压|他汀|普利|沙坦|SGLT2|DPP|GLP", re.I)
_DRUG_DECISION = re.compile(
    r"停|不吃|不打|不想|先不|别吃|还吃|还要|还用|继续|换|改成|改用|减|加|多打|少打|多吃|少吃|调整|剂量|药量|几片|多少|"
    r"一片|两片|半片|要不要|该不该|应不应该|应该|可不可以|能不能|可以不|开始|去买|吃什么|用什么"
)
_MED_EXPLICIT = re.compile(r"停药|减药|加药|换药|剂量|药量|自行用药")

# 诊断：疾病/器官损害 × 判断问法；或直接要求诊断
_DISEASE = re.compile(r"肾衰|衰竭|尿毒症|肾病|肾功能不全|肾功能不好|肾损|肾.{0,2}坏|透析|酸中毒|酮症|感染|癌|肿瘤|并发症|几期|分期")
_JUDGE = re.compile(r"是不是|是否|会不会|算不算|得了|患了|说明|属于|算几|有没有.*(病|症|感染)|吧")
_DIAG_EXPLICIT = re.compile(r"诊断|确诊|什么病|啥病|判断.{0,4}病")

# 危险症状：强症状直接判定；弱症状在报告显示酮体阳性时判定（结合上下文）
_EMERG_STRONG = re.compile(
    r"呼吸困难|喘不过气|呼吸很快|呼吸急促|昏迷|意识模糊|意识不清|叫不醒|晕倒|一直吐|吐了|呕吐|剧烈腹痛|肚子很痛|腹痛|"
    r"胸痛|胸闷|抽搐|站不住|烂苹果|呼气.{0,4}味|心慌.{0,4}出汗"
)
_EMERG_WEAK = re.compile(r"很累|乏力|没力气|口渴|恶心|头晕|眼花")


def classify(message: str, res: AnalyzeResponse) -> str | None:
    """越界/安全分类：组合判断意图，并结合报告上下文（酮体阳性时的乏力、恶心等描述按危险症状处理）。"""
    ketone_positive = any(i.code == "KET" and i.usable and i.positivity.value == "positive" for i in res.items)
    if _EMERG_STRONG.search(message) or (ketone_positive and _EMERG_WEAK.search(message)):
        return "emergency"
    if _MED_EXPLICIT.search(message) or (_DRUG.search(message) and _DRUG_DECISION.search(message)):
        return "medication"
    if _DIAG_EXPLICIT.search(message) or (_DISEASE.search(message) and _JUDGE.search(message)):
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


def to_simplified(text: str) -> str:
    """繁体 → 简体（OpenCC，本地转换不联网）。安全分类与输出校验都基于简体，避免繁体输入绕过拦截。"""
    return _T2S.convert(text)


INTENT_SYSTEM = (
    "你是医疗问答的安全分类器。根据糖尿病患者对尿检报告的提问，判断其意图，只输出一个标签，不输出其他文字。\n"
    "medication：询问或打算停药、减药、加药、换药、调整剂量或用药次数时间、该吃/该买什么药、要不要开始或继续用某种药或打针。\n"
    "diagnosis：要求判断自己或家人是否患有某种疾病、病情到哪一期、会不会发展成某病、要不要透析或换肾。\n"
    "emergency：描述正在发生的严重不适，如持续呕吐、剧烈腹痛、呼吸急促或困难、意识模糊、叫不醒、昏倒、胸痛胸闷、呼气烂苹果味、极度乏力。\n"
    "none：其他问题，如指标含义、指标之间的关系、检查注意事项、复查安排、饮食生活常识、药物对检查结果的影响。\n"
    "只输出 medication、diagnosis、emergency、none 之一。"
)
_INTENT_LABELS = ("medication", "diagnosis", "emergency")


def llm_classify(message: str, res: AnalyzeResponse) -> str | None:
    """第二层：关键词未命中时，用大模型做语义意图判断。失败、超时或未配置时返回 None（继续正常流程，仍有输出校验）。"""
    provider = get_intent_provider()
    if provider is None:
        return None
    context = "报告中尿酮体阳性。" if any(i.code == "KET" and i.usable and i.positivity.value == "positive" for i in res.items) else ""
    try:
        out = provider.complete(INTENT_SYSTEM, f"{context}患者提问：{message}").strip().lower()
    except LLMError:
        return None
    return next((label for label in _INTENT_LABELS if label in out), None)


def classify_intent(message: str, res: AnalyzeResponse) -> tuple[str | None, str]:
    """两层安全分类：关键词（快速、确定）→ 大模型语义判断（覆盖关键词未见过的说法）。返回 (类别, 判定来源)。"""
    category = classify(message, res)
    if category:
        return category, "keyword"
    category = llm_classify(message, res)
    return category, ("llm" if category else "none")


def chat(req: ChatRequest) -> ChatResponse:
    res = analyze(req.analysis)
    provider = get_provider()
    # 统一转为简体后再判断（繁体输入曾导致「我能停藥嗎」未被拦截）
    req = req.model_copy(update={"message": to_simplified(req.message)})
    def safety(cat: str) -> ChatResponse:
        return ChatResponse(answer=_safety_answer(cat, res), safety_category=cat, provider="safety-template", used_fallback=False)

    # 第一层：关键词（快速、确定），命中即回安全模板，不调用大模型
    category = classify(req.message, res)
    if category:
        return safety(category)

    draft, cites = _draft(req, res)
    facts = _facts_text(res, draft, cites) if draft else ""
    urgent_allowed = res.urgent_alert.show or res.overall.level == Level.red

    def rewrite() -> tuple[str, bool]:
        """返回 (回答, 是否回退)。校验失败或服务不可用时回退到基于规则与知识的草稿。"""
        try:
            text = provider.complete(SYSTEM_PROMPT, f"报告事实：\n{facts}\n\n用户问题：{req.message}\n\n【草稿】{draft}")
            if guard.check(to_simplified(text), facts, urgent_allowed).ok:
                return text, False
        except LLMError:
            pass
        return draft, True

    # 第二层：大模型语义判断与回答改写同时进行，用户只需等待较慢的一项（学校平台响应 1–28 秒波动）
    with ThreadPoolExecutor(2) as ex:
        intent_f = ex.submit(llm_classify, req.message, res)
        rewrite_f = ex.submit(rewrite) if draft else None
        category = intent_f.result()
        if category:
            return safety(category)  # 越界：丢弃改写结果，改用安全模板
        if rewrite_f is None:
            return ChatResponse(
                answer="这个问题暂时没有可核验的资料，我无法据此回答。建议把问题记下来，复诊时询问医生。",
                provider="template", used_fallback=False, no_evidence=True)
        answer, fell_back = rewrite_f.result()
    return ChatResponse(answer=answer, citations=cites, provider=provider.name, used_fallback=fell_back)
