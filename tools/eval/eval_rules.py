"""规则判读评测 + 对照实验 A（MediLens 组合规则 vs 通用逐项解读）。

数据：
1. 随机人群（合成）：按与评测集相同的分布随机生成 1000 份报告的「真实值」，并随机将部分关键项设为「无法确认」，
   模拟用户在局部确认时选择「无法确认」的情况。
2. 判定标准（独立实现，不调用系统代码）：只根据原始字符串与参考范围，用最简单的方式判断「应当提示什么」，
   依据为交接说明与项目书中的设计要求（不是临床金标准；规则本身未经医学审核）。

对照方法「通用逐项解读」：每项与参考范围比较，超出即标「异常」；未识别/无法确认的项目直接忽略；
没有组合规则、不询问用药、不区分「未知」与「正常」。这是常见报告解读工具的做法。

用法：python tools/eval/eval_rules.py
输出：tests/eval/rules_results.json
"""
from __future__ import annotations

import json
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backend"))

from app.analysis import analyze  # noqa: E402
from app.schemas import AnalyzeRequest  # noqa: E402

POS = {"1+", "2+", "3+", "阳性"}  # 独立判定：阳性写法
NEG = {"阴性", "-"}


def gen_case(rng: random.Random) -> dict:
    qual = ["阴性"] * 5 + ["±", "1+", "2+", "3+"]
    items = {c: rng.choice(qual) for c in ["GLU", "KET", "PRO", "LEU", "NIT"]}
    items["NIT"] = rng.choice(["阴性"] * 4 + ["阳性"])
    uacr = None
    if rng.random() < 0.5:
        uacr = round(rng.choice([rng.uniform(3, 29), rng.uniform(30, 299), rng.uniform(300, 800)]), 1)
    unknown = set()
    if rng.random() < 0.3:  # 30% 的报告有 1 个关键项无法确认
        unknown.add(rng.choice(["GLU", "KET", "PRO", "LEU", "NIT"] + (["UACR"] if uacr else [])))
    sglt2 = rng.choice(["yes_known", "no", "__unknown__", None])
    return dict(items=items, uacr=uacr, unknown=unknown, sglt2=sglt2)


def to_request(c: dict) -> AnalyzeRequest:
    names = {"GLU": "葡萄糖", "KET": "酮体", "PRO": "尿蛋白", "LEU": "白细胞", "NIT": "亚硝酸盐"}
    items = [dict(original_label=names[k], raw_value=v, reference_text="阴性",
                  review_status="unknown" if k in c["unknown"] else "confirmed") for k, v in c["items"].items()]
    if c["uacr"] is not None:
        items.append(dict(original_label="UACR", raw_value=str(c["uacr"]), unit="mg/g", reference_text="<30",
                          review_status="unknown" if "UACR" in c["unknown"] else "confirmed"))
    answers = {}
    if c["sglt2"] is not None and c["items"]["GLU"] not in NEG:
        answers["q_sglt2"] = c["sglt2"]
    return AnalyzeRequest.model_validate({"report": {"test_date": "2026-10-01", "items": items}, "answers": answers})


# ---------- 独立判定：这份报告「应当」出现哪些提示 ----------
def expected(c: dict) -> dict:
    it, unk = c["items"], c["unknown"]
    known = {k: v for k, v in it.items() if k not in unk}
    uacr_known = c["uacr"] is not None and "UACR" not in unk
    return {
        # 尿糖与酮体同时阳性 → 应紧急提示（项目书 R-01）
        "ketosis_alert": known.get("GLU") in POS and known.get("KET") in POS,
        # UACR 升高且白细胞/亚硝酸盐阳性 → 应提示感染干扰（R-03）
        "infection_interference": uacr_known and c["uacr"] >= 30 and (known.get("LEU") in POS or known.get("NIT") in POS),
        # 尿糖阳性且在用 SGLT2 → 应解释药物影响（R-02）
        "drug_explained": it["GLU"] not in NEG and "GLU" not in unk and c["sglt2"] == "yes_known",
        # 有关键项无法确认 → 不得给出「全部正常」
        "must_not_reassure": bool(unk),
        # 任一已知项超出参考范围 → 应标为异常
        "abnormal_items": {k for k, v in known.items() if v not in NEG} | ({"UACR"} if uacr_known and c["uacr"] >= 30 else set()),
    }


# ---------- 两种方法的输出 ----------
def medilens(c: dict) -> dict:
    r = analyze(to_request(c))
    hits = {h.rule_id for h in r.hits}
    abnormal = {i.code for i in r.items if i.usable and i.status.value == "abnormal"}
    return {
        "ketosis_alert": r.urgent_alert.show and "R-01" in hits,
        "infection_interference": "R-03" in hits,
        "drug_explained": "R-02" in hits,
        "reassured": r.overall.level.value == "green" and not abnormal,
        "says_cannot_judge": r.overall.level.value == "unknown" or bool(r.not_evaluable) or r.counts.unknown > 0,
        "abnormal_items": abnormal,
    }


def generic(c: dict) -> dict:
    abnormal = set()
    for k, v in c["items"].items():
        if k in c["unknown"]:
            continue  # 通用做法：识别不了就不显示
        if v not in NEG:
            abnormal.add(k)
    if c["uacr"] is not None and "UACR" not in c["unknown"] and c["uacr"] >= 30:
        abnormal.add("UACR")
    return {
        "ketosis_alert": False,  # 无组合规则与优先级
        "infection_interference": False,
        "drug_explained": False,
        "reassured": not abnormal,  # 已显示项目都正常 → 「全部正常」
        "says_cannot_judge": False,
        "abnormal_items": abnormal,
    }


def rate(num: int, den: int) -> float | None:
    return round(num / den, 4) if den else None


def main() -> None:
    sys.stdout.reconfigure(encoding="utf-8")
    rng = random.Random(4242)
    cases = [gen_case(rng) for _ in range(1000)]
    res = {}
    for name, fn in [("MediLens", medilens), ("通用逐项解读", generic)]:
        k_tp = k_n = i_tp = i_n = d_tp = d_n = fr = fr_n = item_ok = item_n = 0
        for c in cases:
            e, o = expected(c), fn(c)
            if e["ketosis_alert"]:
                k_n += 1
                k_tp += o["ketosis_alert"]
            if e["infection_interference"]:
                i_n += 1
                i_tp += o["infection_interference"]
            if e["drug_explained"]:
                d_n += 1
                d_tp += o["drug_explained"]
            if e["must_not_reassure"]:
                fr_n += 1
                fr += o["reassured"]
            for code in set(c["items"]) | ({"UACR"} if c["uacr"] is not None else set()):
                if code in c["unknown"]:
                    continue
                item_n += 1
                item_ok += (code in e["abnormal_items"]) == (code in o["abnormal_items"])
        res[name] = {
            "单项异常判定一致率": rate(item_ok, item_n),
            "酮症紧急提示召回率（红色规则）": rate(k_tp, k_n),
            "感染干扰提示召回率": rate(i_tp, i_n),
            "用药干扰解释召回率": rate(d_tp, d_n),
            "错误安慰率（有项目无法确认却显示全部正常）": rate(fr, fr_n),
            "样本数": {"报告": len(cases), "单项": item_n, "应紧急提示": k_n, "应提示感染干扰": i_n, "应解释用药": d_n, "含无法确认项": fr_n},
        }
    # 误报：不应紧急提示的报告是否被紧急提示
    fp = sum(1 for c in cases if not expected(c)["ketosis_alert"] and medilens(c)["ketosis_alert"])
    res["MediLens"]["紧急提示误报数"] = f"{fp}/{sum(1 for c in cases if not expected(c)['ketosis_alert'])}"
    out = ROOT / "tests" / "eval" / "rules_results.json"
    out.write_text(json.dumps(res, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(res, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
