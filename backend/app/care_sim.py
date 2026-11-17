"""陈女士 14 天居家多源资料（合成数据，教学虚构病例），以及演示用的「起始状态」与「单一情境」。

依据老师建议文件《融合医院检验与居家多源时序数据……》的虚拟病例数值生成：
67 岁、2 型糖尿病 8 年并有高血压，使用二甲双胍与一种磺脲类药物；HbA1c 7.3%、空腹血糖 7.6、诊间血压 142/82。
居家 14 天：早/午/晚餐后 2 小时中位数约 9.0 / 9.7 / 12.1；两晚夜间低值（指血复核 3.8、3.7），
发生在晚餐比平常晚 60–80 分钟、用药仍照平常时间的那两晚；6 次高碳水晚餐中 5 次餐后 ≥12.0，其余 8 次中 2 次；
4 天饭后步行 20–30 分钟（餐后中位数约 10.2，久坐日约 12.4）；日均约 3,800 步；平均睡眠约 5 小时 50 分；
家庭血压约 138/78；体重 66.8 → 66.5 kg；米饭照片估算约 200 g，家属复秤约 280 g。

两个版本：
- cgm=True：连续血糖监测，每 15 分钟一笔，覆盖率约 92%；指血只用于复核。
- cgm=False：只有指血（空腹、三餐后 2 小时、症状时），每天约 5 笔，适合没有戴血糖仪的长辈。

这是为验证算法与演示而设的简化曲线模型，不是生理模型；所有资料都标注为合成资料。
"""
from __future__ import annotations

import json
import math
import random
import sys
from datetime import date, datetime, time, timedelta
from pathlib import Path
from statistics import mean, median

from .lifestyle import LOW, HIGH, Event, ScheduleItem

STEP = 15  # 连续血糖监测间隔（分钟）
DAYS = 14
DEFAULT_START = date(2026, 11, 3)

PROFILE = {
    "name": "陈女士（虚构病例）",
    "age": 67,
    "diagnosis": "2 型糖尿病 8 年，合并高血压",
    "medications": ["二甲双胍", "磺脲类药物"],
    "target_range": [LOW, HIGH],
    "note": "教学虚构病例，不用于个体诊断或调药；目标范围须由医师个体化确定。",
}
SCHEDULE = [ScheduleItem(task="medication", time="07:00", label="二甲双胍＋磺脲类药物（早）"),
            ScheduleItem(task="medication", time="18:00", label="二甲双胍＋磺脲类药物（晚）")]
LAB = {"hba1c": 7.3, "fpg": 7.6, "clinic_sbp": 142, "clinic_dbp": 82}

# ---- 每日计划（第 0–13 天）。数值按文件凑出，各组中位数见 tests/test_care_sim.py ----
HIGH_CARB = {1, 3, 5, 8, 10, 12}          # 主食偏多或有甜饮料、点心的晚餐
LATE = {4: 75, 9: 60}                     # 晚餐比平常晚的分钟数；当晚出现夜间低值
WALK = {2, 6, 7, 11}                      # 晚饭后步行
CORRECTED = 8                             # 米饭 200 g → 家属复秤 280 g
DIZZY = {3, 10}                           # 晚饭后头晕
FASTING = [7.4, 6.9, 7.8, 7.2, 6.6, 7.6, 7.3, 8.0, 7.5, 6.8, 7.4, 8.2, 7.1, 7.7]
BREAKFAST_2H = [8.3, 9.4, 8.8, 9.1, 8.6, 9.6, 8.9, 9.0, 9.3, 8.5, 9.2, 8.7, 9.0, 9.8]
LUNCH_2H = [9.5, 10.2, 9.1, 9.8, 9.7, 10.6, 9.3, 9.6, 10.1, 9.0, 9.9, 9.4, 10.4, 9.7]
DINNER_2H = [12.3, 12.8, 9.6, 13.4, 10.9, 11.9, 10.4, 10.0, 12.9, 11.8, 13.1, 11.9, 12.4, 12.4]
CONFIRM = {4: 3.8, 9: 3.7}                # 夜间指血复核
BREAKFASTS = [("稀饭＋馒头＋鸡蛋", 55, 100), ("豆浆＋菜包子", 52, 120), ("燕麦粥＋鸡蛋＋全麦面包", 50, 80)]
LUNCHES = [("米饭＋炒青菜＋清蒸鱼", 66, 200), ("面条＋青菜＋鸡蛋", 68, 250), ("米饭＋家常豆腐＋炒青菜", 63, 190)]
DINNERS = [("米饭＋炒青菜＋鸡肉", 60, 180), ("米饭＋番茄炒蛋＋青菜汤", 58, 170)]
HIGH_DINNERS = {1: ("米饭（大碗）＋红烧肉＋甜饮料", 104, 300, True), 3: ("面条（大碗）＋点心", 98, 380, False),
                5: ("米饭＋炒面＋甜饮料", 110, 260, True), 8: ("米饭＋红烧排骨＋炒青菜", 85, 280, False),
                10: ("饺子＋甜点", 92, 350, False), 12: ("米饭（大碗）＋糖醋排骨＋甜饮料", 106, 300, True)}
RICE_CARBS_PER_100G = 25.9  # 熟米饭（USDA FNDDS 约值）


def _dt(d: date, minutes: float) -> datetime:
    return datetime.combine(d, time(0)) + timedelta(minutes=round(minutes))


def _bump(tau: float, T: float, k: float = 2.0) -> float:
    """餐后上升形状：τ 分钟后的相对高度，峰在 T 分钟；k 越小回落越慢。"""
    if tau <= 0:
        return 0.0
    x = tau / T
    return x ** k * math.exp(k * (1 - x))


def _plan(start: date) -> list[dict]:
    rng = random.Random(20261103)
    days = []
    for i in range(DAYS):
        d = start + timedelta(days=i)
        dinner_min = 18 * 60 + LATE.get(i, rng.choice([-15, 0, 0, 15]))
        days.append({
            "i": i, "date": d,
            "wake": _dt(d, 5 * 60 + 50 + rng.randint(-15, 15)),
            "sleep": _dt(d, 23 * 60 + 55 + rng.randint(-25, 25)),  # 当晚入睡（次日凌晨前后）
            "meals": [("breakfast", _dt(d, 6 * 60 + 45), BREAKFAST_2H[i]),
                      ("lunch", _dt(d, 11 * 60 + 45), LUNCH_2H[i]),
                      ("dinner", _dt(d, dinner_min), DINNER_2H[i])],
        })
    return days


# 餐后曲线形状（峰值分钟 T、回落 k）与白天基线抬高，已校准到文件的 TIR/TAR（见 tests/test_care_sim.py）
SHAPE = {"breakfast": (50, 1.5), "lunch": (50, 1.5), "dinner": (90, 0.6)}
DAY_RISE = 0.4    # 中午到傍晚基线比空腹高多少（mmol/L）
NIGHT_RISE = 3.0  # 午夜时基线比次日空腹高多少（晚餐后回落较慢）
NIGHT_LOW = 3.4  # 夜间低值平台


def _cgm_curve(plan: list[dict], shape: dict | None = None, day_rise: float = DAY_RISE, night_rise: float = NIGHT_RISE, seed: int = 1) -> dict[datetime, float]:
    """在 15 分钟网格上生成血糖曲线；每餐的上升幅度反推，使餐后 120 分钟的读数正好等于计划值。"""
    shape = shape or SHAPE
    rng = random.Random(seed)
    start = datetime.combine(plan[0]["date"], time(0))
    n = DAYS * 24 * 60 // STEP
    grid = [start + timedelta(minutes=STEP * k) for k in range(n)]

    # 基线：凌晨 05:00 为当天空腹值，白天抬高，深夜回落到次日空腹值
    knots: list[tuple[datetime, float]] = []
    for p in plan:
        f = FASTING[p["i"]]
        knots += [(_dt(p["date"], 0), f + night_rise), (_dt(p["date"], 5 * 60), f), (_dt(p["date"], 12 * 60), f + day_rise),
                  (_dt(p["date"], 20 * 60), f + day_rise)]
    knots.append((grid[-1] + timedelta(minutes=STEP), FASTING[-1] + 0.2))

    def base(t: datetime) -> float:
        for (t0, v0), (t1, v1) in zip(knots, knots[1:]):
            if t0 <= t <= t1:
                return v0 + (v1 - v0) * (t - t0) / (t1 - t0)
        return knots[-1][1]

    noise, x = [], 0.0
    for _ in grid:
        x = 0.8 * x + rng.gauss(0, 0.12)
        noise.append(x)
    vals = [base(t) + nz for t, nz in zip(grid, noise)]
    idx = {t: k for k, t in enumerate(grid)}
    for slot, mt, target in sorted((m for p in plan for m in p["meals"]), key=lambda m: m[1]):
        T, kk = shape[slot]
        k2 = idx.get(mt + timedelta(minutes=120))
        if k2 is None:
            continue
        amp = (target - vals[k2]) / _bump(120, T, kk)
        for k in range(idx[mt], min(n, idx[mt] + 10 * 60 // STEP)):
            vals[k] += amp * _bump((grid[k] - mt).total_seconds() / 60, T, kk)

    # 夜间低值：晚吃那晚 23:00 起下降，约 23:45–03:30 低于 3.9；03:20 出汗心悸醒来、指血复核、喝糖水，约 1 小时回升
    for p in plan:
        if p["i"] not in LATE:
            continue
        nxt = p["date"] + timedelta(days=1)
        a, b, c, e = _dt(p["date"], 23 * 60), _dt(nxt, 0), _dt(nxt, 3 * 60 + 30), _dt(nxt, 4 * 60 + 30)
        for k, t in enumerate(grid):
            w = (t - a) / (b - a) if a <= t < b else 1.0 if b <= t < c else 1 - (t - c) / (e - c) if c <= t < e else 0.0
            if w:
                vals[k] = (1 - w) * vals[k] + w * (NIGHT_LOW + noise[k])
    return {t: round(v, 1) for t, v in zip(grid, vals)}


def _protected(plan: list[dict]) -> set[datetime]:
    """覆盖率抽掉读数时不能抽到的关键点（餐后 2 小时、空腹、夜间低值）。"""
    keep: set[datetime] = set()
    for p in plan:
        for _, mt, _ in p["meals"]:
            keep |= {mt + timedelta(minutes=m) for m in (105, 120, 135)}
        w = p["wake"].replace(minute=p["wake"].minute // STEP * STEP)
        keep |= {w + timedelta(minutes=m) for m in range(-60, 31, STEP)}
        if p["i"] in LATE:
            nxt = p["date"] + timedelta(days=1)
            keep |= {_dt(p["date"], 23 * 60 + m) for m in range(0, 5 * 60, STEP)}
            keep |= {_dt(nxt, m) for m in range(0, 5 * 60 + 1, STEP)}
    return keep


def _thin(curve: dict[datetime, float], plan: list[dict], coverage: float = 0.92) -> dict[datetime, float]:
    """模拟传感器信号中断：第 7 天下午一段连续缺失，其余随机零星缺失，凑到目标覆盖率。"""
    rng = random.Random(7)
    keep = _protected(plan)
    gap_day = plan[7]["date"]
    drop = {t for t in curve if _dt(gap_day, 14 * 60 + 15) <= t < _dt(gap_day, 19 * 60 + 45)} - keep
    need = round(len(curve) * (1 - coverage)) - len(drop)
    pool = sorted(set(curve) - keep - drop)
    drop |= set(rng.sample(pool, max(0, need)))
    return {t: v for t, v in curve.items() if t not in drop}


def _scale_mean(vals: list[float], target: float) -> list[float]:
    m = mean(vals)
    return [v - m + target for v in vals]


def chen_case(start: date = DEFAULT_START, cgm: bool = True, **curve) -> dict:
    """返回 {profile, schedule, events, truth}。truth 记录植入的情境，供测试与评测核对。"""
    plan = _plan(start)
    rng = random.Random(42)
    curve = _cgm_curve(plan, **curve)
    ev: list[Event] = [Event(type="lab", time=_dt(start - timedelta(days=2), 9 * 60), lab=dict(LAB),
                             text="医院检查：血常规、肾功能等本例未见明显异常")]

    if cgm:
        ev += [Event(type="glucose", time=t, glucose=v, glucose_source="cgm") for t, v in sorted(_thin(curve, plan).items())]

    def finger(t: datetime, v: float | None = None, confirm: bool = False) -> Event:
        t = t.replace(minute=t.minute // STEP * STEP, second=0)
        return Event(type="glucose", time=t, glucose=v if v is not None else curve[t], glucose_source="finger",
                     confirmatory=confirm)

    sbp = _scale_mean([138 + rng.gauss(0, 4) for _ in range(DAYS)], 138)
    dbp = _scale_mean([78 + rng.gauss(0, 3) for _ in range(DAYS)], 78)
    steps = [rng.randint(4900, 5600) if p["i"] in WALK else rng.randint(2700, 3700) for p in plan]
    steps = [round(s) for s in _scale_mean(steps, 3800)]
    for p in plan:
        i, d = p["i"], p["date"]
        if i > 0:  # 第 0 天之前的入睡不记，避免多出一天「没打卡」
            ev.append(Event(type="sleep", time=plan[i - 1]["sleep"]))
        ev.append(Event(type="wake", time=p["wake"]))
        if not cgm:
            ev.append(finger(p["wake"] + timedelta(minutes=10)))
        w = 66.8 - 0.3 * i / (DAYS - 1) + (0 if i in (0, DAYS - 1) else rng.uniform(-0.1, 0.1))
        ev.append(Event(type="weight", time=p["wake"] + timedelta(minutes=5), weight_kg=round(w, 1)))
        ev.append(Event(type="bp", time=_dt(d, 7 * 60 + 30), systolic=round(sbp[i]), diastolic=round(dbp[i])))
        for t_med in ("07:00", "18:00"):  # 晚吃那天也照平常时间用药
            hh, mm = map(int, t_med.split(":"))
            for name in ("二甲双胍", "磺脲类药物"):
                ev.append(Event(type="medication", time=_dt(d, hh * 60 + mm + rng.randint(-8, 8)), med_name=name))

        for slot, mt, _ in p["meals"]:
            if slot == "dinner" and i in HIGH_CARB:
                food, carbs, grams, sweet = HIGH_DINNERS[i]
            else:
                menu = {"breakfast": BREAKFASTS, "lunch": LUNCHES, "dinner": DINNERS}[slot]
                food, carbs, grams = menu[i % len(menu)]
                sweet = False
            meal = Event(type="meal", time=mt, meal_slot=slot, food=food, carbs_g=float(carbs), grams=float(grams),
                         sweet_drink=sweet, estimate="photo",
                         meal_size="large" if slot == "dinner" and i in HIGH_CARB else "normal")
            if slot == "dinner" and i == CORRECTED:
                meal = meal.model_copy(update={
                    "original_grams": 200.0, "grams": 280.0,
                    "original_carbs_g": round(carbs - 80 * RICE_CARBS_PER_100G / 100, 1),
                    "corrected_by": "家属", "corrected_at": mt + timedelta(minutes=20)})
            ev.append(meal)
            if not cgm and not (slot == "lunch" and i in (3, 11)):  # 指血版：偶尔漏测午餐后
                ev.append(finger(mt + timedelta(minutes=120)))
        dinner = p["meals"][2][1]
        if i in WALK:
            ev.append(Event(type="exercise", time=dinner + timedelta(minutes=20), minutes=rng.randint(20, 30)))
        if i in DIZZY:
            ev.append(Event(type="symptom", time=dinner + timedelta(minutes=100), symptoms=["头晕"]))
        ev.append(Event(type="steps", time=_dt(d, 21 * 60 + 45), steps=steps[i]))
        if i in LATE:
            nxt = d + timedelta(days=1)
            ev.append(Event(type="symptom", time=_dt(nxt, 3 * 60 + 20), symptoms=["出汗", "心悸"]))
            ev.append(finger(_dt(nxt, 3 * 60 + 30), CONFIRM[i], confirm=True))
            ev.append(Event(type="meal", time=_dt(nxt, 3 * 60 + 35), meal_slot="snack", food="糖水（低血糖处理）",
                            carbs_g=15.0, estimate="manual"))
    ev.sort(key=lambda e: e.time)

    truth = {
        "synthetic": True,
        "cgm": cgm,
        "start": start.isoformat(),
        "days": DAYS,
        "high_carb_dinner_days": [(start + timedelta(days=i)).isoformat() for i in sorted(HIGH_CARB)],
        "late_dinner_days": {(start + timedelta(days=i)).isoformat(): m for i, m in LATE.items()},
        "low_nights": [(start + timedelta(days=i)).isoformat() for i in sorted(LATE)],
        "walk_days": [(start + timedelta(days=i)).isoformat() for i in sorted(WALK)],
        "corrected_meal": plan[CORRECTED]["meals"][2][1].isoformat(),
        "expected": {"post_meal_median": {"breakfast": 9.0, "lunch": 9.7, "dinner": 12.1},
                     "fasting_median": 7.4, "tir": 0.58, "tar": 0.39, "tbr": 0.03, "coverage": 0.92,
                     "steps_mean": 3800, "sleep_hours_mean": 5.83, "home_bp": [138, 78], "weight": [66.8, 66.5]},
    }
    return {"profile": PROFILE, "schedule": SCHEDULE, "events": ev, "truth": truth}


# ---------- 资料概况（核对生成结果用） ----------

def describe(events: list[Event]) -> dict:
    gl = [e for e in events if e.type == "glucose"]
    cgm = [e for e in gl if e.glucose_source == "cgm"]
    src = cgm or gl
    vals = [e.glucose for e in src]
    by_t = {e.time: e.glucose for e in src}
    post = {}
    for slot in ("breakfast", "lunch", "dinner"):
        v = [by_t[m.time + timedelta(minutes=120)] for m in events
             if m.type == "meal" and m.meal_slot == slot and m.time + timedelta(minutes=120) in by_t]
        post[slot] = round(median(v), 2) if v else None
    days = {e.time.date() for e in events if e.type == "wake"}
    sleeps = sorted(e.time for e in events if e.type == "sleep")
    wakes = sorted(e.time for e in events if e.type == "wake")
    hours = [(w - s).total_seconds() / 3600 for s in sleeps for w in wakes if timedelta(hours=2) < w - s < timedelta(hours=12)]
    bp = [e for e in events if e.type == "bp"]
    wt = [e.weight_kg for e in events if e.type == "weight"]
    return {
        "records": len(events),
        "glucose_readings": len(gl),
        "coverage": round(len(cgm) / (len(days) * 24 * 60 / STEP), 3) if cgm else None,
        "tir": round(sum(LOW <= v <= HIGH for v in vals) / len(vals), 3),
        "tar": round(sum(v > HIGH for v in vals) / len(vals), 3),
        "tbr": round(sum(v < LOW for v in vals) / len(vals), 3),
        "post_meal_median": post,
        "meals": sum(e.type == "meal" and e.meal_slot != "snack" for e in events),
        "steps_mean": round(mean(e.steps for e in events if e.type == "steps")),
        "sleep_hours_mean": round(mean(hours), 2) if hours else None,
        "home_bp_mean": [round(mean(e.systolic for e in bp)), round(mean(e.diastolic for e in bp))],
        "weight_first_last": [wt[0], wt[-1]] if wt else None,
    }


# ---------- 演示：起始状态与单一情境 ----------

START_STATES = ("new", "day3", "chen14")


def start_state(state: str, end: date, cgm: bool = True) -> list[Event]:
    """new：空白；day3：陈女士前 3 天；chen14：完整 14 天。日期平移到以 end 为最后一天。"""
    if state == "new":
        return []
    case = chen_case(start=end - timedelta(days=DAYS - 1), cgm=cgm)
    if state == "chen14":
        return case["events"]
    if state == "day3":
        cut = datetime.combine(end - timedelta(days=DAYS - 1) + timedelta(days=3), time(0))
        return [e for e in case["events"] if e.time < cut]
    raise ValueError(f"未知的起始状态：{state}")


def day_slice(events: list[Event], day: date) -> list[Event]:
    """逐日播放：某一天（00:00–23:59）的记录。"""
    return [e for e in events if e.time.date() == day]


SCENARIOS = {
    "normal_dinner": "一般晚餐（准时、碳水正常）",
    "late_high_carb_dinner": "晚吃＋高碳水晚餐（用药照平常时间）",
    "post_meal_high": "餐后血糖偏高",
    "night_low": "半夜低血糖（伴出汗、心悸，指血复核）",
    "missed_med": "漏吃药",
    "post_meal_walk": "饭后散步",
    "new_lab": "新的医院检验",
}


def scenario(name: str, at: datetime, cgm: bool = True) -> list[Event]:
    """在时间 at 模拟「刚刚发生」的一件事，返回要加入的记录。"""
    src = "cgm" if cgm else "finger"
    if name == "normal_dinner":
        return [Event(type="medication", time=at, med_name="二甲双胍"), Event(type="medication", time=at, med_name="磺脲类药物"),
                Event(type="meal", time=at, meal_slot="dinner", food="米饭＋炒青菜＋鸡肉", carbs_g=60.0, grams=180.0,
                      estimate="photo", meal_size="normal")]
    if name == "late_high_carb_dinner":
        med = at - timedelta(minutes=70)
        return [Event(type="medication", time=med, med_name="二甲双胍"), Event(type="medication", time=med, med_name="磺脲类药物"),
                Event(type="meal", time=at, meal_slot="dinner", food="米饭（大碗）＋红烧肉＋甜饮料", carbs_g=88.0,
                      grams=260.0, sweet_drink=True, estimate="photo", meal_size="large")]
    if name == "post_meal_high":
        return [Event(type="glucose", time=at, glucose=12.8, glucose_source="finger")]
    if name == "night_low":
        return [Event(type="glucose", time=at, glucose=3.6, glucose_source=src),
                Event(type="symptom", time=at + timedelta(minutes=2), symptoms=["出汗", "心悸"]),
                Event(type="glucose", time=at + timedelta(minutes=5), glucose=3.8, glucose_source="finger", confirmatory=True)]
    if name == "missed_med":
        return [Event(type="medication", time=at, med_name="二甲双胍", taken=False),
                Event(type="medication", time=at, med_name="磺脲类药物", taken=False)]
    if name == "post_meal_walk":
        return [Event(type="exercise", time=at, minutes=20)]
    if name == "new_lab":
        return [Event(type="lab", time=at, lab=dict(LAB), text="医院检查：血常规、肾功能等本例未见明显异常")]
    raise ValueError(f"未知的情境：{name}")


def dump(events: list[Event]) -> list[dict]:
    return [e.model_dump(mode="json", exclude_none=True, exclude_defaults=True) | {"type": e.type, "time": e.time.isoformat()}
            for e in events]


def export(out_dir: Path) -> list[Path]:
    """导出两个版本的 JSON（合成资料），供组员查看或外部工具使用。"""
    out_dir.mkdir(parents=True, exist_ok=True)
    paths = []
    for cgm, tag in ((True, "cgm"), (False, "finger")):
        case = chen_case(cgm=cgm)
        p = out_dir / f"chen_14d_{tag}.synthetic.json"
        p.write_text(json.dumps({"synthetic": True, "profile": case["profile"],
                                 "schedule": [s.model_dump() for s in case["schedule"]],
                                 "truth": case["truth"], "summary": describe(case["events"]),
                                 "events": dump(case["events"])}, ensure_ascii=False, indent=1), encoding="utf-8")
        paths.append(p)
    return paths


if __name__ == "__main__":
    for p in export(Path(sys.argv[1] if len(sys.argv) > 1 else "../tests/fixtures/care")):
        print(p)
