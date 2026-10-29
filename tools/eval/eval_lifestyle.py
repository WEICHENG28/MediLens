"""生活规律分析与自适应提醒的模拟评测（合成数据）。
1. 规律检出：植入效应的模拟患者 vs 无效应的模拟患者，统计每条规律的检出率与误报率（14 天、28 天记录）。
2. 自适应提醒：30 天在线模拟，比较 Thompson 采样与随机选时段的任务完成率。
用法：backend\\.venv\\Scripts\\python tools\\eval\\eval_lifestyle.py   输出 tests/eval/lifestyle_results.json
"""
import json
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backend"))
from app.lifestyle import LifestyleRequest, _by_type, analyze_lifestyle, choose_slot  # noqa: E402
from app.lifestyle_sim import DEFAULT_EFFECTS, NO_EFFECTS, SCHEDULE, TRUE_RATES, simulate, simulate_reminders  # noqa: E402

IDS = {"insulin_timing": "late_insulin", "post_meal_walk": "walk", "sleep_fasting": "short_sleep",
       "evening_exercise_night_low": "evening_ex", "missed_dose_high": "missed"}
N = 100


def detection(days: int) -> dict:
    hit = {k: 0 for k in IDS}
    fp = {k: 0 for k in IDS}
    for s in range(N):
        found = {i.id for i in analyze_lifestyle(LifestyleRequest(events=simulate(days, seed=s), schedule=SCHEDULE, seed=s)).insights}
        none = {i.id for i in analyze_lifestyle(LifestyleRequest(events=simulate(days, seed=10_000 + s, effects=NO_EFFECTS),
                                                                 schedule=SCHEDULE, seed=s)).insights}
        for k in IDS:
            hit[k] += k in found
            fp[k] += k in none
    return {k: {"植入效应(mmol/L)": DEFAULT_EFFECTS[IDS[k]], "检出率": hit[k] / N, "误报率": fp[k] / N} for k in IDS}


def bandit(days: int = 30, runs: int = 200) -> dict:
    res = {}
    for name in ("thompson", "random"):
        total = 0
        for s in range(runs):
            rng = random.Random(s)
            if name == "thompson":
                def chooser(task, ev, rng=rng):
                    return choose_slot(task, _by_type(ev), rng)["slot"]
            else:
                def chooser(task, ev, rng=rng):
                    return rng.choice(list(TRUE_RATES[task]))
            _, done = simulate_reminders(days, s, chooser)
            total += done
        res[name] = round(total / (runs * days * len(TRUE_RATES)), 3)
    best = sum(max(r.values()) for r in TRUE_RATES.values()) / len(TRUE_RATES)
    res["已知最佳时段（理论上限）"] = round(best, 3)
    return res


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    out = {"说明": "合成数据；每组 100 位模拟患者；检出=输出该条规律；误报=在没有该效应的患者上输出该条规律。",
           "14天记录": detection(14), "28天记录": detection(28), "自适应提醒30天完成率": bandit()}
    (ROOT / "tests" / "eval" / "lifestyle_results.json").write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(out, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
