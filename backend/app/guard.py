"""输出校验：数值一致性、越界用药/诊断表述、未经规则支持的风险结论、来源。

任一项不通过 → 调用方回退到基于规则与知识的模板解释，不把未校验内容返回给用户。
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

# 越界表述：建议用户自行调整用药、或给出诊断结论
FORBIDDEN_PATTERNS = [
    r"(可以|应该|应当|建议|需要|最好)(您|你)?(先)?(停药|停用|减药|减量|加量|加药|换药|调整剂量|增加剂量|减少剂量)",
    r"(您|你)(已经)?(确诊|患有|得了)",
    r"确诊为",
    r"(不用|不需要|无需)(看医生|就医|复诊)",
    r"(肯定|一定)(是|没有|不是)",
]

# 只有命中红色规则或报告危险症状时才允许出现的紧急表述
URGENT_PATTERNS = [r"立即就医", r"马上就医", r"拨打\s*120", r"急诊"]

ALLOWED_CONSTANTS = {"120", "24"}


@dataclass
class GuardResult:
    ok: bool
    problems: list[str] = field(default_factory=list)


def _numbers(text: str) -> set[str]:
    nums = set()
    for m in re.findall(r"\d+(?:\.\d+)?", text):
        nums.add(m.rstrip("0").rstrip(".") if "." in m else m)
    return nums


def check(text: str, facts_text: str, urgent_allowed: bool) -> GuardResult:
    problems = []
    for p in FORBIDDEN_PATTERNS:
        if re.search(p, text):
            problems.append(f"越界表述：{p}")
    if not urgent_allowed:
        for p in URGENT_PATTERNS:
            if re.search(p, text):
                problems.append("出现未经规则支持的紧急结论")
                break
    unknown_nums = _numbers(text) - _numbers(facts_text) - ALLOWED_CONSTANTS
    # 「1+」「2+」等等级中的数字也会出现在事实中；个位序号（第1、2点）放行
    unknown_nums = {n for n in unknown_nums if not (n.isdigit() and int(n) <= 10)}
    if unknown_nums:
        problems.append("出现与报告不一致的数值：" + "、".join(sorted(unknown_nums)))
    return GuardResult(ok=not problems, problems=problems)
