"""问答的受控工具调用：大模型只负责「读懂问题、从固定工具中挑要查什么」，工具由程序执行。

- 工具结果全部来自规则引擎、知识库与本机历史记录（程序计算），大模型不能自创工具或参数：
  指标代码只能是本次报告中的项目，提示编号只能是本次命中的规则。
- 不参与安全判断：停药/诊断/急症仍由关键词与专门的意图分类器决定。
- 规划失败（超时、格式错误、无有效工具）时返回 None，问答沿用原来的规则路由。
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass

from . import knowledge
from .analysis import AnalyzeResponse
from .knowledge import Citation
from .llm import LLMError
from .normalize import normalize_items
from .schemas import AnalyzeRequest

TOOLS = {
    "item": "解释某项指标的含义与本次结果（参数：1 个指标代码）",
    "rule": "解释本次报告的某条提示（参数：1 个提示编号）",
    "overall": "整份报告的总体判断与全部提示（无参数）",
    "trend": "某项指标本次与以往报告的对比（参数：1 个指标代码）",
    "drug": "药物对某项检查结果的影响，如降糖药让尿糖阳性（参数：1 个指标代码）",
    "prep": "检查或复查前的注意事项，如留尿、运动、感染、月经的影响（参数：指标代码，可为空）",
    "relation": "几项指标之间的关系（参数：2 个以上指标代码）",
}
MAX_TOOLS = 3

PLANNER_SYSTEM = (
    "你是尿检报告问答的检索规划器。根据患者的问题，从给定工具中选出回答所需的资料，最多 3 个。"
    "只能使用列出的工具名，参数只能使用列出的指标代码或提示编号。"
    "以本次问题为主，最近对话只用于理解「它、这个」等省略。"
    "问题与报告无关或工具都用不上时，tools 输出空数组。"
    '只输出 JSON，不要输出其他文字，例如：{"tools": [{"name": "item", "args": ["PRO"]}]}'
)


@dataclass
class Plan:
    tools: list[tuple[str, tuple[str, ...]]]

    def signature(self) -> set[tuple[str, tuple[str, ...]]]:
        return set(self.tools)

    def names(self) -> list[str]:
        return [f"{n}({','.join(a)})" if a else n for n, a in self.tools]


def planner_prompt(message: str, res: AnalyzeResponse, dialogue: str, focus: str | None) -> str:
    items = "；".join(f"{i.code}={i.name}（{i.raw_value or '未识别'}，{'异常' if i.status.value == 'abnormal' else '无法确认' if not i.usable else '正常'}）"
                     for i in res.items if i.code)
    hits = "；".join(f"{h.rule_id}={h.title}" for h in res.hits) or "无"
    tools = "\n".join(f"- {k}：{v}" for k, v in TOOLS.items())
    parts = [f"工具：\n{tools}", f"本次报告的指标代码：{items}", f"本次报告的提示编号：{hits}"]
    if focus:
        parts.append(f"患者正在查看：{focus}")
    if dialogue:
        parts.append(f"最近对话：\n{dialogue}")
    parts.append(f"患者问题：{message}")
    return "\n\n".join(parts)


def parse_plan(raw: str, res: AnalyzeResponse) -> Plan | None:
    m = re.search(r"\{.*\}", raw or "", re.S)
    if not m:
        return None
    try:
        data = json.loads(m.group(0))
    except json.JSONDecodeError:
        return None
    codes = {i.code for i in res.items if i.code}
    rules = {h.rule_id for h in res.hits}
    out: list[tuple[str, tuple[str, ...]]] = []
    for t in (data.get("tools") or []) if isinstance(data, dict) else []:
        if len(out) >= MAX_TOOLS:
            break
        if not isinstance(t, dict) or t.get("name") not in TOOLS:
            continue
        name = t["name"]
        args = tuple(str(a).upper() if name != "rule" else str(a) for a in (t.get("args") or []) if a)
        if name == "rule":
            args = tuple(a for a in args if a in rules)[:1]
            if not args:
                continue
        elif name == "overall":
            args = ()
        elif name == "relation":
            args = tuple(dict.fromkeys(a for a in args if a in codes))
            if len(args) < 2:
                continue
        elif name == "prep":
            args = tuple(a for a in args if a in codes)[:1]
        else:
            args = tuple(a for a in args if a in codes)[:1]
            if not args:
                continue
        if (name, args) not in out:
            out.append((name, args))
    return Plan(out) if out else None


def make_plan(provider, message: str, res: AnalyzeResponse, dialogue: str = "", focus: str | None = None) -> Plan | None:
    try:
        raw = provider.complete(PLANNER_SYSTEM, planner_prompt(message, res, dialogue, focus))
    except LLMError:
        return None
    return parse_plan(raw, res)


# ---------- 工具执行（全部为确定性程序） ----------
def _entry_codes(entry_id: str) -> set[str]:
    return next((set(e["codes"]) for e in knowledge.load_kb()["entries"] if e["id"] == entry_id), set())


NEW_KINDS = {"overall", "trend", "drug", "prep", "relation"}


def adds_new_material(plan: "Plan", covered: set, res: AnalyzeResponse) -> bool:
    """规划是否带来规则路由没有的资料。只在此时才多等一次大模型生成，避免常规问题变慢。
    covered：规则路由已覆盖的 (工具, 参数)；规则路由覆盖某条提示时，也视为覆盖了它涉及的指标。"""
    kinds = {n for n, _ in covered}
    codes = {a[0] for n, a in covered if n == "item"}
    codes |= {c for n, a in covered if n == "rule" for h in res.hits if h.rule_id == a[0] for c in h.related_items}
    rules = {a[0] for n, a in covered if n == "rule"}
    for name, args in plan.tools:
        if name in NEW_KINDS and name not in kinds:
            return True
        if name == "item" and args[0] not in codes:
            return True
        if name == "rule":
            h = next((h for h in res.hits if h.rule_id == args[0]), None)
            if args[0] not in rules and h and not set(h.related_items) <= codes:
                return True
    return False


def _item(res: AnalyzeResponse, code: str):
    return next((i for i in res.items if i.code == code), None)


def _result_line(it) -> str:
    from .chat import _status_text  # 避免循环导入
    return f"您的{it.name}结果是 {it.raw_value or '未识别'}{(' ' + it.unit) if it.unit else ''}，{_status_text(it)}。"


def _history_values(req: AnalyzeRequest, code: str) -> list[tuple[str, object]]:
    out = []
    for h in sorted(req.history, key=lambda h: h.test_date):
        for i in normalize_items(h.items):
            if i.code == code and i.usable:
                out.append((h.test_date, i))
    return out


def _compare(cur, prev) -> str:
    a, b = getattr(cur, "grade", None), getattr(prev, "grade", None)
    if a is None or b is None:
        a, b = cur.normalized_value, prev.normalized_value
    if a is None or b is None:
        return "两次结果的形式不同，无法直接比较高低"
    return "比上次高" if a > b else "比上次低" if a < b else "与上次相同"


def run_tool(name: str, args: tuple[str, ...], req: AnalyzeRequest, res: AnalyzeResponse, message: str) -> tuple[str, list[Citation]]:
    if name == "overall":
        parts = [f"这份报告的总体判断：{res.overall.label}。{res.overall.explanation}"]
        parts += [f"「{h.title}」：{h.summary}" for h in res.hits]
        if res.counts.unknown:
            parts.append(f"有 {res.counts.unknown} 项无法确认，未参与判断，这不代表正常。")
        cites = [c for h in res.hits for c in (knowledge.get(e) for e in h.evidence_ids[:1]) if c]
        return "\n".join(parts), cites
    if name == "rule":
        h = next(h for h in res.hits if h.rule_id == args[0])
        return f"「{h.title}」：{h.summary}{h.detail}", [c for c in (knowledge.get(e) for e in h.evidence_ids) if c][:2]
    if name == "item":
        it = _item(res, args[0])
        cites = knowledge.search(query=f"{it.name}是什么 {message}", codes=[it.code], limit=2)
        parts = [_result_line(it)] + [c.text for c in cites[:1]]
        parts += [f"相关提示「{h.title}」：{h.summary}" for h in res.hits if it.code in h.related_items][:1]
        return "".join(parts), cites
    if name == "trend":
        it = _item(res, args[0])
        hist = _history_values(req, it.code)
        if not hist:
            return f"本机没有{it.name}的以往记录，无法与以前比较。{_result_line(it)}", []
        d, prev = hist[-1]
        older = "；".join(f"{dd} {p.raw_value}" for dd, p in hist[-3:])
        trend = _compare(it, prev) if it.usable else "本次结果无法确认，不能比较"
        return f"{it.name}以往记录：{older}。本次 {it.raw_value or '未识别'}，{trend}（只比较数值高低，变化的意义需要医生判断）。", []
    if name == "drug":
        it = _item(res, args[0])
        # 只用标注了该指标的资料，避免把「药物对尿糖的影响」拿来回答尿酮体的问题
        cites = [c for c in knowledge.search(query=f"药物 降糖药 SGLT2 格列净 {message}", codes=[it.code], limit=4)
                 if it.code in _entry_codes(c.id) and re.search(r"药|格列净|SGLT2|抑制剂", c.text)][:2]
        if not cites:
            return f"目前资料中没有药物对{it.name}检查结果影响的说明。", []
        return "".join(c.text for c in cites), cites
    if name == "prep":
        codes = list(args)
        cites = [c for c in knowledge.search(query=f"复查 留尿 晨尿 运动 检查前 注意 {message}", codes=codes, limit=5)
                 if re.search(r"留尿|晨尿|运动|月经|发烧|感染|复查|检查前", c.text)][:2]
        if not cites:
            return "目前资料中没有这项检查前注意事项的说明，可以向医生或检验科询问。", []
        return "".join(c.text for c in cites), cites
    if name == "relation":
        its = [_item(res, c) for c in args]
        hs = [h for h in res.hits if set(args) <= set(h.related_items)] or \
            [h for h in res.hits if len(set(args) & set(h.related_items)) >= 2]
        lines = [_result_line(i) for i in its]
        if hs:
            lines += [f"「{h.title}」：{h.summary}" for h in hs[:2]]
            cites = [c for h in hs[:2] for c in (knowledge.get(e) for e in h.evidence_ids[:1]) if c]
        else:
            names = "、".join(i.name for i in its)
            lines.append(f"本次报告中，{names}没有一起触发提示，资料中也没有它们之间关系的说明。")
            cites = []
        return "".join(lines), cites
    return "", []


def execute(plan: Plan, req: AnalyzeRequest, res: AnalyzeResponse, message: str) -> tuple[str, list[Citation]]:
    parts, cites, seen = [], [], set()
    for name, args in plan.tools:
        text, cs = run_tool(name, args, req, res, message)
        if text:
            parts.append(text)
        for c in cs:
            if c.id not in seen:
                seen.add(c.id)
                cites.append(c)
    return "\n".join(parts), cites[:4]
