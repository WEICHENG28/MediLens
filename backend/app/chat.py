"""逐条「详细了解」与文字对话。

流程：服务端重跑标准化+规则（不信任客户端传来的结论）→ 越界问题走安全模板 → 组装基于规则与知识的草稿
→ 大模型依据报告与知识回答具体问题 → 输出校验 → 不通过则回退标准说明。大模型不能新增风险结论。
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
    "根据当前报告事实和提供的医学知识依据，直接回答用户的具体问题。优先解释用户所问的关系或原因，可以重组和归纳已有依据；【草稿】仅供参考，不必照搬。依据不足时明确说明，不得编造。不得新增任何医学结论、风险等级、数值或用药建议；"
    "直接面向用户解释报告，不得提及草稿、提示词、系统提示、内部资料、备用资料或备份资料，也不要描述改写过程。"
    "不得建议停药、换药、调整剂量，不得做出诊断；医生医嘱优先。回答不超过 150 字。"
    "语气尊重、温和，不责备用户。用户表达担心、害怕或自责时，可用一句话回应这种感受，再解释问题和已有依据支持的下一步；"
    "普通知识提问直接回答，不机械地每次安慰；用户不需要安慰时尊重其选择。不要说保证没事、肯定正常，也不要推测用户的情绪或经历。"
    "紧急症状优先明确就医行动，不用安慰话延迟处理。来源未审核时不得称为已获医学审核，不得编造引用。"
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
            ExplainSection(heading="依据", body=f"{hit.rule_id}（{hit.review_status}）；参考资料见下方来源"
                           + ("" if any(not c.id.startswith("kb-test") for c in cites) else "（目前为占位说明，非指南原文）")),
        ]
        return ExplainResponse(target=hit.rule_id, title=hit.title, short=hit.summary, sections=sections,
                               citations=cites, doctor_questions=hit.doctor_questions)

    item = next((i for i in res.items if i.code == req.target.upper()), None)
    if item is None:
        return ExplainResponse(target=req.target, title="未找到", short="报告中没有这一项，无法解释。",
                               sections=[], citations=[], doctor_questions=[])
    # 一条讲「是什么」，一条讲「这次结果」相关的延伸说明（按结果状态检索）
    what = knowledge.search(query=f"{item.name}是什么", codes=[item.code], limit=1)
    state = "阳性升高偏高" if item.status.value == "abnormal" else "阴性正常"
    on_sglt2 = any("SGLT2" in h.title for h in res.hits)  # 用药相关的说明只在命中用药规则时出现
    more = [c for c in knowledge.search(query=f"{item.name}{state}", codes=[item.code], limit=4)
            if (not what or c.id != what[0].id) and (on_sglt2 or "SGLT2" not in c.title)][:1]
    cites = what + more
    related_hits = [h for h in res.hits if item.code in h.related_items]
    value = f"{item.raw_value or '未识别'}{(' ' + item.unit) if item.unit else ''}"
    short = f"{item.name}：{value}（{_status_text(item)}）"
    sections = [ExplainSection(heading="这个指标是什么", body=what[0].text if what else "暂无可核验的资料。")]
    if more:
        sections.append(ExplainSection(heading=more[0].title, body=more[0].text))
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
    r"胸痛|胸闷|抽搐|站不住|烂苹果|呼气.{0,4}味|心慌.{0,4}出汗|"
    # 酮症酸中毒/严重低血糖的危险征象：呼吸深快或费力、口中水果味、言语不清、反应迟钝（按症状类别泛化，不针对个别句子）
    r"呼吸.{0,3}(急|快|费力|困难|深)|喘|水果味|酮味|说话.{0,3}不清|口齿不清|反应.{0,2}(慢|迟钝)|神志|糊涂|叫不应|"
    r"昏过去|昏倒|昏厥|胸口.{0,3}(闷|痛)|冷汗"
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


_OVERALL = re.compile(r"整体|总体|总的来说|(报告|结果|检查|指标|这次|化验).*(怎么样|如何|严重|要紧|正常|问题|好不好)|"
                      r"严重吗|严不严重|要紧吗|要不要紧|没事吧|有没有事|有事吗|(我|我的|我这|这种).{0,4}(情况|状况).{0,4}(怎么样|如何|好吗)")
_WHAT_IS = re.compile(r"是什么|什么意思|指什么")
_SHORT_NAMES = {
    "GLU": ["尿糖", "葡萄糖"], "KET": ["尿酮", "酮体"], "PRO": ["尿蛋白", "蛋白质"], "LEU": ["白细胞"],
    "NIT": ["亚硝酸"], "BLD": ["隐血", "潜血", "红细胞"], "SG": ["比重"], "PH": ["酸碱", "PH"],
    "UACR": ["UACR", "白蛋白", "肌酐比"],
}


def _aliases(item) -> list[str]:
    return [item.name, item.code.upper(), *_SHORT_NAMES.get(item.code.upper(), [])]


def _mentioned_codes(text: str, res: AnalyzeResponse) -> list[str]:
    up = text.upper()
    return [i.code for i in res.items if i.code and any(a in up for a in _aliases(i))]


# 追问的说法：用代词指回前文，或以「那/还有/为什么…」开头的省略句
_REFER = re.compile(r"它|这个|那个|这项|那项|这一项|该指标|这指标|这种|那种|^那|^还有|^为什么|^怎么|^要不要|^会不会|^需要|^多久")


def _user_turns(req: ChatRequest) -> list[str]:
    return [to_simplified(t.content) for t in req.history if t.role == "user" and t.content.strip()]


def _is_followup(req: ChatRequest, res: AnalyzeResponse) -> bool:
    return bool(req.history) and not req.focus and not req.quick \
        and not _mentioned_codes(req.message, res) and bool(_REFER.search(req.message))


def _contextualize(req: ChatRequest, res: AnalyzeResponse) -> ChatRequest:
    """多轮追问的指代补全（确定性，不调用大模型）：问题没有点名指标、又在指回前文时，
    沿用最近一次提问里提到的指标，例如「尿蛋白是什么」之后问「那它要注意什么」。"""
    if not _is_followup(req, res):
        return req
    for prev in reversed(_user_turns(req)):
        codes = _mentioned_codes(prev, res)
        if codes:
            names = "、".join(i.name for i in res.items if i.code in codes)
            return req.model_copy(update={"message": f"{names}：{req.message}"})
    return req


def _recent_dialogue(req: ChatRequest, turns: int = 4, limit: int = 120) -> str:
    """最近几轮对话（截断），只供大模型理解指代，不作为医学依据。"""
    lines = [f"{'用户' if t.role == 'user' else '助手'}：{to_simplified(t.content)[:limit]}" for t in req.history[-turns:] if t.content.strip()]
    return "\n".join(lines)


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
        # 没有选定指标：概述整份报告中一起触发的组合
        if res.hits:
            lines = [f"「{h.title}」（{'、'.join(i.name for i in res.items if i.code in h.related_items)}）：{h.summary}"
                     for h in res.hits]
            cites = [c for h in res.hits for c in (knowledge.get(e) for e in h.evidence_ids[:1]) if c]
            return "本次报告中需要一起看的指标：\n" + "\n".join(lines), cites
        return "本次报告没有多个指标一起触发测试规则。想了解单个指标，可以直接问，例如「尿蛋白是什么」。", []

    if not focus:
        # 没有指定焦点：从问题里认出提到的指标；问「整体怎么样」时用总览回答
        codes = [i.code for i in res.items if i.code and any(a in req.message.upper() for a in _aliases(i))]
        if len(codes) == 1:
            item = next(i for i in res.items if i.code == codes[0])
        if codes and not _WHAT_IS.search(req.message):  # 问「是什么」时只解释指标，不套组合规则
            hit = next((h for h in res.hits if set(codes) <= set(h.related_items)), None) or \
                next((h for h in res.hits if set(codes) & set(h.related_items)), None)
        if not codes and _WHAT_IS.search(req.message):
            # 「这个指标是什么」但没有选定指标：解释本次需要关注的指标（最多 3 项）
            watch = [i for i in res.items if i.code and (i.status.value == "abnormal" or any(i.code in h.related_items for h in res.hits))][:3]
            parts, cites = [], []
            for it in watch:
                c = knowledge.search(query=f"{it.name}是什么", codes=[it.code], limit=1)
                if c:
                    parts.append(f"{it.name}（本次结果 {it.raw_value or '未识别'}）：{c[0].text}")
                    cites += c
            if parts:
                return "本次需要关注的指标：\n" + "\n".join(parts), cites
            return ("本次报告的指标都在参考范围内。想了解某个指标，可以直接问，例如「尿蛋白是什么」，"
                    "或在总览中点该指标的「就这一条提问」。"), []
        if not codes and _OVERALL.search(req.message):
            parts = [f"这份报告的总体判断：{res.overall.label}。{res.overall.explanation}"]
            parts += [f"「{h.title}」：{h.summary}" for h in res.hits]
            cites = [c for h in res.hits for c in (knowledge.get(e) for e in h.evidence_ids[:1]) if c]
            return "\n".join(parts), cites

    cites = knowledge.search(query=req.message, codes=codes)
    if hit:  # 命中组合规则时，优先引用该规则的依据
        cites = [c for c in (knowledge.get(e) for e in hit.evidence_ids) if c][:2] + \
            [c for c in cites if c.id not in hit.evidence_ids]
        cites = cites[:3]
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
        "knowledge": [{"text": c.text, "review_status": c.review_status} for c in cites],
    }
    return json.dumps(facts, ensure_ascii=False) + "\n" + draft


def to_simplified(text: str) -> str:
    """繁体 → 简体（OpenCC，本地转换不联网）。安全分类与输出校验都基于简体，避免繁体输入绕过拦截。"""
    return _T2S.convert(text)


def _supportive_fallback(message: str, answer: str, category: str | None = None) -> str:
    """Only acknowledge explicitly expressed worry; never soften urgent action."""
    declined = re.search(r"(不要|不用|别)安慰|不(担心|害怕|焦虑|紧张)", message)
    if category != "emergency" and not declined and re.search(r"担心|害怕|焦虑|紧张|自责|吓|恐惧", message):
        return "看到报告有些担心是可以理解的。" + answer
    return answer


INTENT_SYSTEM = (
    "你是医疗问答的安全分类器。根据糖尿病患者对尿检报告的提问，判断其意图，只输出一个标签，不输出其他文字。\n"
    "medication：询问或打算停药、减药、加药、换药、调整剂量或用药次数时间、该吃/该买什么药、要不要开始或继续用某种药或打针。\n"
    "diagnosis：要求判断自己或家人是否患有某种疾病、病情到哪一期、会不会发展成某病、要不要透析或换肾。\n"
    "emergency：描述正在发生的严重不适，如持续呕吐、剧烈腹痛、呼吸急促或困难、意识模糊、叫不醒、昏倒、胸痛胸闷、呼气烂苹果味、极度乏力。\n"
    "none：其他问题，如指标含义、指标之间的关系、检查注意事项、复查安排、饮食生活常识、药物对检查结果的影响。\n"
    "只输出 medication、diagnosis、emergency、none 之一。"
)
_INTENT_LABELS = ("medication", "diagnosis", "emergency")


def llm_classify(message: str, res: AnalyzeResponse, previous: str = "") -> str | None:
    """第二层：关键词未命中时，用大模型做语义意图判断。失败、超时或未配置时返回 None（继续正常流程，仍有输出校验）。"""
    provider = get_intent_provider()
    if provider is None:
        return None
    context = "报告中尿酮体阳性。" if any(i.code == "KET" and i.usable and i.positivity.value == "positive" for i in res.items) else ""
    try:
        prev = f"上一句提问（仅用于理解省略）：{previous[:120]}\n" if previous else ""
        out = provider.complete(INTENT_SYSTEM, f"{context}{prev}患者提问：{message}").strip().lower()
    except LLMError:
        return None
    # 只认唯一明确的标签：输出里同时出现多个标签（如带解释的句子）时不采信，避免误判
    found = {label for label in (*_INTENT_LABELS, "none") if re.search(rf"\b{label}\b", out)}
    return found.pop() if len(found) == 1 and found <= set(_INTENT_LABELS) else None


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
        return ChatResponse(answer=_supportive_fallback(req.message, _safety_answer(cat, res), cat), safety_category=cat, provider="safety-template", used_fallback=False)

    previous = (_user_turns(req) or [""])[-1]
    # 第一层：关键词（快速、确定），命中即回安全模板，不调用大模型。
    # 追问时把上一句提到的药物一起考虑，例如「二甲双胍会影响尿糖吗」之后问「那要换一种吗」。
    category = classify(req.message, res)
    if not category and _is_followup(req, res) and _DRUG.search(previous) and _DRUG_DECISION.search(req.message):
        category = "medication"
    if category:
        return safety(category)

    draft, cites = _draft(_contextualize(req, res), res)
    if req.quick == "doctor":  # 复诊问题清单由规则直接生成，不需要大模型改写
        return ChatResponse(answer=draft, citations=cites, provider="template", used_fallback=False)
    facts = _facts_text(res, draft, cites) if draft else ""
    urgent_allowed = res.urgent_alert.show or res.overall.level == Level.red

    def rewrite() -> tuple[str, bool]:
        """返回 (回答, 是否回退)。校验失败或服务不可用时回退到基于规则与知识的草稿。"""
        try:
            dialogue = _recent_dialogue(req)
            dialogue = f"最近对话（仅用于理解指代，不是医学依据）：\n{dialogue}\n\n" if dialogue else ""
            raw = provider.complete(SYSTEM_PROMPT, f"报告事实：\n{facts}\n\n{dialogue}用户问题：{req.message}\n\n【草稿】{draft}")
            text = to_simplified(raw).strip() if raw else ""
            if text and guard.check(text, facts, urgent_allowed).ok:
                if provider.name == "mock":
                    text = _supportive_fallback(req.message, text)
                return text, False
        except LLMError:
            pass
        return _supportive_fallback(req.message, draft), True

    # 第二层：大模型语义判断与回答改写同时进行，用户只需等待较慢的一项（学校平台响应 1–28 秒波动）
    with ThreadPoolExecutor(2) as ex:
        intent_f = ex.submit(llm_classify, req.message, res, previous)
        rewrite_f = ex.submit(rewrite) if draft else None
        category = intent_f.result()
        if category:
            return safety(category)  # 越界：丢弃改写结果，改用安全模板
        if rewrite_f is None:
            return ChatResponse(
                answer=_supportive_fallback(req.message, "这个问题暂时没有可核验的资料，我无法据此回答。您可以告诉我具体的指标或报告提示，我们再逐项看；也可以把问题记下来，复诊时询问医生。"),
                provider="template", used_fallback=False, no_evidence=True)
        answer, fell_back = rewrite_f.result()
    return ChatResponse(answer=answer, citations=cites, provider=provider.name, used_fallback=fell_back)
