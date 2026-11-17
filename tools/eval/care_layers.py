"""实验 G：医院检验与居家多源资料的分层对照（A/B/C/D），合成病人群。

问题（老师建议文件）：在医院检验基础上逐层加入居家资料，能否提高异常情境识别、风险提示与行动建议的品质。
同一批病人分别只给 A/B/C/D 的资料，由照护核心（规则＋统计，不经大模型）产生结论，与事先放入的情境比对。

用法：
  backend/.venv/Scripts/python.exe tools/eval/care_layers.py [人数=400] [干扰=1.0] [天数=14]
输出：tests/eval/care_layers/results_n{人数}_noise{干扰}.json 与同名 .md
"""
from __future__ import annotations

import json
import sys
import time
from collections import defaultdict
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backend"))

from app.care import CareRequest, build_profile  # noqa: E402
from app.care_cohort import LAYERS, SCENARIOS, cohort, layer  # noqa: E402

FINDING = {"dinner_high": "high_carb_dinner", "late_med_low": "late_dinner_night_low", "walk_helps": "walk_dinner"}
QUESTION = {"dinner_high": "晚餐主食", "late_med_low": "晚餐延迟", "walk_helps": "散步"}
BANNED = ("增加剂量", "减少剂量", "加量吃", "减量吃", "停药吧", "多吃一片", "少吃一片", "单位胰岛素", "导致")
NAMES = {"dinner_high": "高碳水晚餐→餐后偏高", "late_med_low": "晚吃照常用药→夜间低值", "walk_helps": "饭后散步→餐后较低"}


def evaluate(p) -> dict:
    out = {"pid": p.pid, "cgm": p.cgm, "scenarios": list(p.scenarios), "true_low": bool(p.truth["low_nights"]),
           "hba1c": p.truth["hba1c"], "false_low": p.truth["false_low"], "layers": {}}
    for name in LAYERS:
        r = build_profile(CareRequest(events=layer(p.events, name), schedule=p.schedule))
        ids = {f.id for f in r.findings}
        text = "".join(f.headline + f.detail + (f.question or "") + (f.boundary or "") for f in r.findings)
        night = next((f for f in r.findings if f.id == "night_low"), None)
        out["layers"][name] = {
            "found": [s for s in SCENARIOS if FINDING[s] in ids],
            "watching": [s for s in SCENARIOS if FINDING[s] in {w.id for w in r.watching}],
            "questions": [s for s in SCENARIOS if any(QUESTION[s] in q for q in r.doctor_questions)],
            "night_low": night is not None,
            "urgent_mixed": "hba1c_high_with_lows" in ids,
            "unknown": [f.id for f in r.findings if f.level == "unknown"],
            "n_findings": len(r.findings),
            "banned": [w for w in BANNED if w in text],
        }
    return out


def summarize(rows: list[dict]) -> dict:
    s: dict = {"n": len(rows), "cgm": sum(r["cgm"] for r in rows), "layers": {}}
    for name in LAYERS:
        L = {"scenario": {}}
        for sc in SCENARIOS:
            pos = [r for r in rows if sc in r["scenarios"]]
            neg = [r for r in rows if sc not in r["scenarios"]]
            tp = sum(sc in r["layers"][name]["found"] for r in pos)
            fp = sum(sc in r["layers"][name]["found"] for r in neg)
            seen = sum(sc in r["layers"][name]["found"] or sc in r["layers"][name]["watching"] for r in pos)
            L["scenario"][sc] = {"recall": round(tp / len(pos), 3) if pos else None, "positives": len(pos),
                                 "found_or_watching": round(seen / len(pos), 3) if pos else None,
                                 "false_positive_rate": round(fp / len(neg), 3) if neg else None, "negatives": len(neg),
                                 "specific_question": round(sum(sc in r["layers"][name]["questions"] for r in pos) / len(pos), 3) if pos else None}
        controls = [r for r in rows if not r["scenarios"]]
        L["controls_any_association"] = round(sum(bool(r["layers"][name]["found"]) for r in controls) / len(controls), 3) if controls else None
        lows = [r for r in rows if r["true_low"]]
        nolow = [r for r in rows if not r["true_low"]]
        L["night_low_recall"] = round(sum(r["layers"][name]["night_low"] for r in lows) / len(lows), 3) if lows else None
        L["night_low_false_rate"] = round(sum(r["layers"][name]["night_low"] for r in nolow) / len(nolow), 3) if nolow else None
        mixed = [r for r in rows if r["true_low"] and r["hba1c"] >= 7.0]
        L["urgent_mixed_recall"] = round(sum(r["layers"][name]["urgent_mixed"] for r in mixed) / len(mixed), 3) if mixed else None
        L["says_cannot_judge"] = round(sum(bool(r["layers"][name]["unknown"]) for r in rows) / len(rows), 3)
        L["banned_words"] = sum(len(r["layers"][name]["banned"]) for r in rows)
        L["mean_findings"] = round(sum(r["layers"][name]["n_findings"] for r in rows) / len(rows), 2)
        s["layers"][name] = L
    return s


def pct(v):
    return "—" if v is None else f"{round(v * 100)}%"


def markdown(s: dict, n: int, noise: float, secs: float, days: int = 14) -> str:
    lines = [f"# 实验 G：分层对照（合成病人 {n} 位，记录 {days} 天，干扰 {noise}）", "",
             f"监测仪 {s['cgm']} 位、只有指血 {n - s['cgm']} 位；照护核心（规则＋统计）直接产生结论，不经大模型。耗时 {secs:.0f} 秒。", "",
             "| 资料条件 | " + " | ".join(f"{NAMES[sc]} 辨识率" for sc in SCENARIOS) + " | 无规律对照出现任何关联 | 夜间低值提示率 | 无低值却提示 | 高值＋低值紧急提示 | 说明「还不能判断」 | 越界用语 |",
             "|---|" + "---|" * (len(SCENARIOS) + 6)]
    for name, desc in LAYERS.items():
        L = s["layers"][name]
        lines.append(f"| {name}. {desc} | " + " | ".join(pct(L["scenario"][sc]["recall"]) for sc in SCENARIOS)
                     + f" | {pct(L['controls_any_association'])} | {pct(L['night_low_recall'])} | {pct(L['night_low_false_rate'])}"
                     f" | {pct(L['urgent_mixed_recall'])} | {pct(L['says_cannot_judge'])} | {L['banned_words']} |")
    lines += ["", "| 资料条件 | " + " | ".join(f"{NAMES[sc]} 误报率" for sc in SCENARIOS) + " | " + " | ".join(f"{NAMES[sc]} 具体复诊问题" for sc in SCENARIOS) + " |",
              "|---|" + "---|" * (2 * len(SCENARIOS))]
    for name, desc in LAYERS.items():
        L = s["layers"][name]
        lines.append(f"| {name} | " + " | ".join(pct(L["scenario"][sc]["false_positive_rate"]) for sc in SCENARIOS) + " | "
                     + " | ".join(pct(L["scenario"][sc]["specific_question"]) for sc in SCENARIOS) + " |")
    lines += ["", "| 资料条件 | " + " | ".join(f"{NAMES[sc]}：已下结论或列为观察中" for sc in SCENARIOS) + " |",
              "|---|" + "---|" * len(SCENARIOS)]
    for name in LAYERS:
        L = s["layers"][name]
        lines.append(f"| {name} | " + " | ".join(pct(L["scenario"][sc]["found_or_watching"]) for sc in SCENARIOS) + " |")
    lines += ["", "说明：辨识率＝放入该情境的病人中，照护档案出现对应关联的比例；误报率＝没有放入该情境的病人中却出现的比例；",
              "具体复诊问题＝复诊问题中点名该情境（如「晚餐主食」「晚餐延迟」「散步」）的比例。所有资料为合成，不代表真实病人表现。"]
    return "\n".join(lines) + "\n"


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 400
    noise = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
    days = int(sys.argv[3]) if len(sys.argv) > 3 else 14
    t = time.time()
    pts = cohort(n, noise=noise, days=days)
    with ProcessPoolExecutor(4) as ex:
        rows = list(ex.map(evaluate, pts, chunksize=8))
    s = summarize(rows)
    secs = time.time() - t
    out = ROOT / "tests" / "eval" / "care_layers"
    out.mkdir(parents=True, exist_ok=True)
    tag = f"n{n}_noise{noise:g}" + (f"_days{days}" if days != 14 else "")
    (out / f"results_{tag}.json").write_text(json.dumps({"summary": s, "rows": rows}, ensure_ascii=False, indent=1), encoding="utf-8")
    (out / f"results_{tag}.md").write_text(markdown(s, n, noise, secs, days), encoding="utf-8")
    print(markdown(s, n, noise, secs, days))


if __name__ == "__main__":
    main()
