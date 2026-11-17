"""医师评阅表：从合成病人群抽样，每位附 14 天资料概况与系统整理（D 层：全部资料），供医师或临床老师盲评。

输出两个文件（合成资料，可以分享）：
- tests/eval/care_layers/医师评阅表.xlsx：评阅者填写的表（不含答案）
- tests/eval/care_layers/评阅答案.xlsx：每位病人事先放入的情境（评阅完成后再打开对照）

用法：backend/.venv/Scripts/python.exe tools/eval/care_review_sheet.py [人数=24]
"""
from __future__ import annotations

import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backend"))

from openpyxl import Workbook  # noqa: E402
from openpyxl.styles import Alignment, Font, PatternFill  # noqa: E402
from openpyxl.worksheet.datavalidation import DataValidation  # noqa: E402

from app.care import CareRequest, build_profile  # noqa: E402
from app.care_cohort import cohort  # noqa: E402

SCEN_ZH = {"dinner_high": "高碳水晚餐→餐后偏高", "late_med_low": "晚吃照常用药→夜间低值", "walk_helps": "饭后散步→餐后较低"}
PM = {"breakfast": "早餐后", "lunch": "午餐后", "dinner": "晚餐后"}


def case_text(p, r) -> str:
    m = r.metrics
    lab = r.background.lab or {}
    meals = [e for e in p.events if e.type == "meal" and e.meal_slot == "dinner"]
    late = len(p.truth["late_nights"])
    walks = sum(1 for e in p.events if e.type == "exercise")
    lines = [
        f"医院检验：HbA1c {lab.get('hba1c', '—')}%，空腹 {lab.get('fpg', '—')}，诊间血压 {lab.get('clinic_sbp', '—'):g}/{lab.get('clinic_dbp', '—'):g}",
        f"居家血糖：{'连续血糖监测' if p.cgm else '指血'}，{m.readings} 笔；范围内 {round((m.tir or 0) * 100)}%、偏低 {round((m.tbr or 0) * 100)}%",
        "餐后 2 小时中位数：" + "、".join(f"{PM[s]} {v['median']}（{v['n']} 次）" for s, v in m.post_meal.items()),
        f"夜间低值：{m.night_low_nights} 晚" + ("（指血复核）" if any(e.confirmed for e in r.low_episodes) else ""),
        f"晚餐 {len(meals)} 次记录（照片估算碳水，误差约 ±30%）；晚餐比平常晚的有 {late} 天；饭后步行 {walks} 次；用药照平常时间",
    ]
    return "\n".join(lines)


def output_text(r) -> str:
    zh = {"fact": "事实", "association": "关联", "ask_doctor": "待问医生", "unknown": "还不能判断"}
    parts = [f"【{zh[f.level]}】{f.headline}：{f.detail}" + (f"（边界：{f.boundary}）" if f.boundary else "") for f in r.findings]
    parts.append("复诊问题：" + ("；".join(f"{i + 1}. {q}" for i, q in enumerate(r.doctor_questions)) or "（无）"))
    return "\n".join(parts)


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 24
    pts = cohort(400)
    rng = random.Random(42)
    by_combo: dict[tuple, list] = {}
    for p in pts:
        by_combo.setdefault(p.scenarios, []).append(p)
    # 分层抽样：每种情境组合都抽到，监测仪与指血各半
    sample = []
    combos = list(by_combo)
    while len(sample) < n:
        for c in combos:
            pool = [p for p in by_combo[c] if p not in sample]
            if pool and len(sample) < n:
                sample.append(rng.choice(pool))
    rng.shuffle(sample)

    wb = Workbook()
    ws = wb.active
    ws.title = "评阅"
    head = ["编号", "14 天资料概况（合成）", "系统整理（事实/关联/待问医生/还不能判断）",
            "内容与资料相符（1–5）", "有无越界（诊断、调药）", "关联有无说成原因", "建议具体可执行（1–5）", "遗漏的重要问题", "备注"]
    ws.append(head)
    for c in ws[1]:
        c.font = Font(bold=True, color="FFFFFF")
        c.fill = PatternFill("solid", fgColor="1F7A6E")
        c.alignment = Alignment(wrap_text=True, vertical="center")
    for i, p in enumerate(sample, 1):
        r = build_profile(CareRequest(events=p.events, schedule=p.schedule))
        ws.append([f"R{i:02d}", case_text(p, r), output_text(r)])
    for col, w in zip("ABCDEFGHI", (7, 48, 80, 12, 12, 12, 12, 24, 20)):
        ws.column_dimensions[col].width = w
    for row in ws.iter_rows(min_row=2):
        for c in row:
            c.alignment = Alignment(wrap_text=True, vertical="top")
    score = DataValidation(type="whole", operator="between", formula1="1", formula2="5", allow_blank=True)
    yn = DataValidation(type="list", formula1='"无,有"', allow_blank=True)
    ws.add_data_validation(score)
    ws.add_data_validation(yn)
    score.add(f"D2:D{n + 1}")
    score.add(f"G2:G{n + 1}")
    yn.add(f"E2:F{n + 1}")
    ws.freeze_panes = "B2"
    note = wb.create_sheet("说明")
    for line in ["本表为合成病人（不是真实病人），用于评估 MediLens 照护核心整理居家资料的品质。",
                 "请依「14 天资料概况」判断「系统整理」：内容是否与资料相符、有无越界（诊断或调药建议）、",
                 "是否把「关联」说成「原因」、建议是否具体可执行，以及是否遗漏重要问题。",
                 "评阅完成前请不要打开「评阅答案.xlsx」。"]:
        note.append([line])
    note.column_dimensions["A"].width = 100
    out = ROOT / "tests" / "eval" / "care_layers"
    out.mkdir(parents=True, exist_ok=True)
    wb.save(out / "医师评阅表.xlsx")

    key = Workbook()
    ks = key.active
    ks.title = "答案"
    ks.append(["编号", "病人代号", "放入的情境", "真实夜间低值日期", "监测仪假低值", "其他偶发低值"])
    for i, p in enumerate(sample, 1):
        ks.append([f"R{i:02d}", p.pid, "、".join(SCEN_ZH[s] for s in p.scenarios) or "无（对照）",
                   "、".join(p.truth["low_nights"]) or "无", "有" if p.truth["false_low"] else "无",
                   "有" if p.truth["stray_low"] else "无"])
    for col, w in zip("ABCDEF", (7, 10, 50, 36, 12, 12)):
        ks.column_dimensions[col].width = w
    key.save(out / "评阅答案.xlsx")
    print(f"已输出 {n} 位：{out / '医师评阅表.xlsx'}、{out / '评阅答案.xlsx'}")


if __name__ == "__main__":
    main()
