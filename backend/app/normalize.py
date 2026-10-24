"""指标标准化：同义词映射、定性分级、单位换算、参考范围比对与矛盾检测。

原则：
- 不改写原值，换算结果另存并记录依据；
- 无法解析或未确认的值标记为不可用（usable=False），不进入确定性规则；
- 「未知」不等于「正常」。
"""
from __future__ import annotations

import re
from functools import lru_cache
from pathlib import Path

import yaml

from .schemas import ItemStatus, LabItemIn, LabItemOut, Positivity, ReviewStatus

DICT_PATH = Path(__file__).parent / "knowledge_base" / "dictionary.yaml"

_USABLE_STATUSES = {ReviewStatus.auto_accepted, ReviewStatus.confirmed}


@lru_cache
def load_dictionary() -> dict:
    with open(DICT_PATH, encoding="utf-8") as f:
        return yaml.safe_load(f)


def _canon(text: str) -> str:
    t = text.strip().upper().replace(" ", "").replace("　", "")
    t = t.replace("（", "(").replace("）", ")")
    t = re.sub(r"\(.*?\)", "", t)  # 去掉括号内的英文缩写或注释
    return t


@lru_cache
def _synonym_index() -> dict[str, str]:
    index: dict[str, str] = {}
    for code, meta in load_dictionary()["items"].items():
        for syn in meta["synonyms"]:
            index[_canon(syn)] = code
    return index


def map_code(label: str, code_hint: str | None = None) -> str | None:
    """把报告上的项目名映射到统一代码；无法映射返回 None。"""
    items = load_dictionary()["items"]
    if code_hint and code_hint.upper() in items:
        return code_hint.upper()
    index = _synonym_index()
    c = _canon(label)
    if c in index:
        return index[c]
    # 「尿蛋白(PRO)」之类：尝试括号内缩写
    m = re.search(r"[(（]\s*([A-Za-z\-/]+)\s*[)）]", label)
    if m and _canon(m.group(1)) in index:
        return index[_canon(m.group(1))]
    for prefix in ("U-", "尿"):
        if c.startswith(_canon(prefix)) and c[len(_canon(prefix)):] in index:
            return index[c[len(_canon(prefix)):]]
    return None


def parse_grade(raw: str | None) -> float | None:
    if raw is None:
        return None
    grades = load_dictionary()["qualitative_grades"]
    t = raw.strip().replace(" ", "").replace("＋", "+").replace("－", "-").replace("﹢", "+")
    t = t.replace("(", "").replace(")", "").replace("（", "").replace("）", "")
    if t.lower() in grades:
        return float(grades[t.lower()])
    if t in grades:
        return float(grades[t])
    # 「1+(15)mmol/L」等半定量写法：取等级部分
    m = re.match(r"^([1-4]\+|\+{1,4}|±|-)", t)
    if m and m.group(1) in grades:
        return float(grades[m.group(1)])
    return None


def positivity_of(grade: float | None) -> Positivity:
    if grade is None:
        return Positivity.unknown
    if grade == 0:
        return Positivity.negative
    if grade == 0.5:
        return Positivity.trace
    return Positivity.positive


def parse_number(raw: str | None) -> float | None:
    if raw is None:
        return None
    t = raw.strip().replace(",", "").replace("，", "")
    t = re.sub(r"[↑↓HLhl*]+$", "", t).strip()
    m = re.fullmatch(r"[<>≤≥]?\s*(-?\d+(?:\.\d+)?)", t)
    return float(m.group(1)) if m else None


def parse_range(text: str | None) -> tuple[float | None, float | None] | None:
    """解析数值参考范围：'0-30'、'<30'、'≤30'、'1.005~1.030'、'>=4.5'。"""
    if not text:
        return None
    t = text.strip().replace(" ", "").replace("—", "-").replace("～", "-").replace("~", "-")
    m = re.fullmatch(r"(\d+(?:\.\d+)?)-(\d+(?:\.\d+)?)", t)
    if m:
        return float(m.group(1)), float(m.group(2))
    m = re.fullmatch(r"(<|≤|<=)(\d+(?:\.\d+)?)", t)
    if m:
        return None, float(m.group(2))
    m = re.fullmatch(r"(>|≥|>=)(\d+(?:\.\d+)?)", t)
    if m:
        return float(m.group(2)), None
    return None


def _norm_unit(unit: str | None) -> str | None:
    if not unit:
        return None
    return unit.strip().lower().replace(" ", "").replace("µ", "μ").replace("cr", "cr")


def normalize_item(item: LabItemIn) -> LabItemOut:
    d = load_dictionary()
    code = map_code(item.original_label, item.code)
    meta = d["items"].get(code) if code else None
    out = LabItemOut(
        code=code,
        name=meta["name"] if meta else item.original_label,
        original_label=item.original_label,
        raw_value=item.raw_value,
        unit=item.unit,
        reference_text=item.reference_text,
        review_status=item.review_status,
        usable=False,
        image_box=item.image_box,
    )
    if meta is None:
        out.status_reason = "该项目不在首期支持范围内，不做解读"
        return out
    if item.review_status not in _USABLE_STATUSES:
        out.status_reason = {
            ReviewStatus.unknown: "用户标记为无法确认，不参与判读",
            ReviewStatus.excluded: "用户已排除，不参与判读",
            ReviewStatus.needs_confirmation: "尚未确认，不参与判读",
        }[item.review_status]
        return out
    if item.raw_value is None or not item.raw_value.strip():
        out.status_reason = "结果缺失"
        return out

    if meta["kind"] == "qualitative":
        _normalize_qualitative(item, out)
    else:
        _normalize_quantitative(code, meta, item, out)

    _check_flag_conflict(item, out)
    # 自动接受但有矛盾 → 需要复核，不进入规则；用户已确认的保留其确认值
    if out.conflicts and item.review_status == ReviewStatus.auto_accepted:
        out.usable = False
        out.status = ItemStatus.unknown
        out.status_reason = "识别结果存在矛盾，需要确认：" + "；".join(out.conflicts)
    return out


def _normalize_qualitative(item: LabItemIn, out: LabItemOut) -> None:
    grade = parse_grade(item.raw_value)
    if grade is None:
        if parse_number(item.raw_value) is not None:
            out.conflicts.append(f"定性项目出现纯数值「{item.raw_value}」")
        out.status_reason = f"无法解析结果「{item.raw_value}」"
        return
    out.grade = grade
    out.positivity = positivity_of(grade)
    out.usable = True
    ref = (item.reference_text or "").strip()
    ref_grade = parse_grade(ref) if ref else None
    if ref_grade is None:
        ref_grade = 0.0  # 字典通用参考：阴性
        source = "报告无参考范围，按字典通用参考「阴性」比对（测试，未经审核）"
    else:
        source = f"按报告参考范围「{ref}」比对"
    out.status = ItemStatus.normal if grade <= ref_grade else ItemStatus.abnormal
    out.status_reason = source


def _normalize_quantitative(code: str, meta: dict, item: LabItemIn, out: LabItemOut) -> None:
    value = parse_number(item.raw_value)
    if value is None:
        out.status_reason = f"无法解析数值「{item.raw_value}」"
        if parse_grade(item.raw_value) is not None:
            out.conflicts.append(f"定量项目出现定性结果「{item.raw_value}」")
        return
    out.numeric_value = value
    lo, hi = meta.get("plausible_range") or (None, None)
    if lo is not None and not (lo <= value <= hi):
        out.conflicts.append(f"数值 {value} 超出合理范围 {lo}–{hi}，可能识别错误")

    factor = 1.0
    target_unit = meta.get("unit")
    if target_unit:
        conversions = load_dictionary()["unit_conversions"].get(code, {})
        u = _norm_unit(item.unit)
        if u is None:
            out.conflicts.append("缺少单位，无法换算")
            out.status_reason = "缺少单位"
            return
        if u not in conversions:
            out.conflicts.append(f"无法识别的单位「{item.unit}」")
            out.status_reason = "单位无法识别"
            return
        factor = conversions[u]
        if factor != 1.0:
            out.conversion_note = f"{value} {item.unit} × {factor} ≈ {round(value * factor, 1)} {target_unit}（换算系数待医学审核）"
    out.normalized_value = round(value * factor, 3)
    out.normalized_unit = target_unit
    out.usable = not out.conflicts

    rng = parse_range(item.reference_text)
    if rng is None:
        out.status = ItemStatus.unknown
        out.status_reason = "报告缺少可解析的参考范围"
        return
    rlo, rhi = rng
    abnormal = (rlo is not None and value < rlo) or (rhi is not None and value > rhi)
    out.status = ItemStatus.abnormal if abnormal else ItemStatus.normal
    out.status_reason = f"按报告参考范围「{item.reference_text}」比对（原单位）"


def _check_flag_conflict(item: LabItemIn, out: LabItemOut) -> None:
    flag = (item.abnormal_flag or "").strip()
    if not flag or out.status == ItemStatus.unknown:
        return
    flagged = flag in {"↑", "↓", "H", "L", "*", "+", "阳性"}
    if flagged and out.status == ItemStatus.normal:
        out.conflicts.append(f"报告异常标记「{flag}」与参考范围比对结果不一致")


def normalize_items(items: list[LabItemIn]) -> list[LabItemOut]:
    return [normalize_item(i) for i in items]


def detect_report_type(items: list[LabItemOut]) -> str:
    codes = {i.code for i in items if i.code}
    if not codes:
        return "unsupported"
    if codes == {"UACR"}:
        return "uacr"
    if "UACR" in codes:
        return "urinalysis+uacr"
    return "urinalysis"
