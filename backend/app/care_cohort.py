"""评测用的合成病人群（合成数据）：每位病人事先放入已知情境，并加入真实干扰，用来计算辨识率与误报率。

情境（可组合，也有完全没有规律的对照）：
- dinner_high：主食多或有甜饮料的晚餐，餐后 2 小时血糖较高
- late_med_low：晚餐比平常晚、晚间用药仍按平常时间的那几晚，夜里出现低血糖
- walk_helps：晚饭后步行的那几天，餐后血糖较低

干扰：漏记血糖与餐点、测量误差、照片估算碳水误差（±30%）、指血读数漏测、监测仪偶发假低值（指血复核不低）、
对照组也会偶尔晚吃、偶尔有与晚吃无关的低值、散步与饮食同时改变（混杂）。

这是为验证算法而设的简化模型，不是生理模型；每位病人由 seed 决定，可完全复现。
"""
from __future__ import annotations

import math
import random
from dataclasses import dataclass, field
from datetime import date, datetime, time, timedelta

from .care_sim import _bump
from .lifestyle import Event, ScheduleItem

SCENARIOS = ("dinner_high", "late_med_low", "walk_helps")
STEP = 15


@dataclass
class Patient:
    pid: str
    seed: int
    scenarios: tuple[str, ...]
    cgm: bool
    events: list[Event]
    schedule: list[ScheduleItem]
    truth: dict = field(default_factory=dict)


def _dt(d: date, minutes: float) -> datetime:
    return datetime.combine(d, time(0)) + timedelta(minutes=round(minutes))


def make_patient(seed: int, scenarios: tuple[str, ...], cgm: bool, days: int = 14,
                 start: date = date(2026, 9, 1), noise: float = 1.0) -> Patient:
    """noise=1 为一般干扰；0 为没有干扰（检查上限）；2 为加倍干扰。"""
    rng = random.Random(seed)
    sc = set(scenarios)
    base_f = rng.uniform(6.0, 8.5)
    usual_dinner = rng.choice([17 * 60 + 30, 18 * 60, 18 * 60 + 30, 19 * 60])
    slot_base = {"breakfast": rng.uniform(8.0, 10.0), "lunch": rng.uniform(8.5, 10.5), "dinner": rng.uniform(9.0, 11.0)}
    carb_effect = rng.uniform(2.0, 3.5) if "dinner_high" in sc else 0.0     # 高碳水晚餐多出的餐后血糖
    walk_effect = -rng.uniform(1.5, 2.8) if "walk_helps" in sc else 0.0
    sd = 0.9 * noise                                                       # 个人每日波动＋测量误差
    schedule = [ScheduleItem(task="medication", time="07:30", label="早"),
                ScheduleItem(task="medication", time=f"{usual_dinner // 60:02d}:{usual_dinner % 60:02d}", label="晚")]
    ev: list[Event] = []
    truth = {"late_nights": [], "low_nights": [], "high_dinners": 0, "walk_days": 0}
    late_days = set(rng.sample(range(days), rng.choice([2, 3]))) if "late_med_low" in sc else \
        set(rng.sample(range(days), rng.choice([0, 1, 2])))   # 对照组也会偶尔晚吃，但不会因此低
    walk_days = set(rng.sample(range(days), rng.randint(4, 6))) if "walk_helps" in sc else \
        set(rng.sample(range(days), rng.randint(0, 5)))
    stray_low = rng.random() < 0.15 * noise and "late_med_low" not in sc  # 与晚吃无关的偶发低值
    stray_day = rng.randrange(days)
    false_low = cgm and rng.random() < 0.2 * noise                        # 监测仪假低值（指血复核不低）
    false_day = rng.randrange(days)

    points: dict[datetime, float] = {}
    for i in range(days):
        d = start + timedelta(days=i)
        wake = _dt(d, 6 * 60 + rng.randint(-30, 30))
        if i:
            ev.append(Event(type="sleep", time=wake - timedelta(hours=rng.uniform(5.5, 8.0))))
        ev.append(Event(type="wake", time=wake))
        f = base_f + rng.gauss(0, 0.4 * noise)
        late = i in late_days
        dinner_t = usual_dinner + (rng.randint(60, 90) if late else rng.choice([-15, 0, 0, 15]))
        meals = [("breakfast", 7 * 60 + rng.randint(-10, 20)), ("lunch", 12 * 60 + rng.randint(-15, 15)), ("dinner", dinner_t)]
        targets = {}
        for slot, mt in meals:
            hc = slot == "dinner" and rng.random() < 0.4
            sweet = hc and rng.random() < 0.5
            carbs = rng.uniform(85, 110) if hc else rng.gauss({"breakfast": 52, "lunch": 65, "dinner": 60}[slot], 6)
            walked = slot == "dinner" and i in walk_days
            # 混杂：散步那几天比较少吃高碳水（对照组也一样），检查算法会提示「饮食也不同」
            if walked and hc and rng.random() < 0.5:
                hc, sweet, carbs = False, False, rng.gauss(60, 5)
            v = slot_base[slot] + (carb_effect if hc else 0) + (walk_effect if walked else 0) + rng.gauss(0, sd)
            if "dinner_high" not in sc and slot == "dinner" and hc:
                v += rng.gauss(0, 0.3)  # 对照组：高碳水与餐后没有关系
            targets[(slot, mt)] = round(max(4.5, v), 1)
            est = carbs * (1 + rng.uniform(-0.3, 0.3) * noise)                # 照片估算误差
            mtime = _dt(d, mt)
            if rng.random() > 0.05 * noise:                                    # 偶尔漏记一餐
                ev.append(Event(type="meal", time=mtime, meal_slot=slot, carbs_g=round(max(10, est), 1),
                                sweet_drink=sweet, estimate="photo", meal_size="large" if hc else "normal"))
            if slot == "dinner":
                truth["high_dinners"] += hc
                if walked:
                    ev.append(Event(type="exercise", time=mtime + timedelta(minutes=rng.randint(10, 30)), minutes=rng.randint(20, 35)))
                    truth["walk_days"] += 1
        for t_med in (7 * 60 + 30, usual_dinner):                                # 晚吃那天也照平常时间用药
            ev.append(Event(type="medication", time=_dt(d, t_med + rng.randint(-8, 8)), med_name="降糖药"))
        ev.append(Event(type="steps", time=_dt(d, 21 * 60 + 30), steps=rng.randint(2500, 7000)))
        ev.append(Event(type="bp", time=_dt(d, 7 * 60 + 40), systolic=rng.randint(122, 146), diastolic=rng.randint(70, 88)))
        ev.append(Event(type="weight", time=_dt(d, 6 * 60 + 20), weight_kg=round(65 + rng.gauss(0, 0.2), 1)))

        night_low = (late and "late_med_low" in sc) or (stray_low and i == stray_day)
        if late:
            truth["late_nights"].append(d.isoformat())
        if night_low:
            truth["low_nights"].append(d.isoformat())
        # 当天曲线：基线＋三餐（反推幅度，使餐后 120 分钟等于目标）＋夜间
        day_pts = {}
        for k in range(6 * 60 // STEP, 24 * 60 // STEP):  # 白天 06:00–24:00；00:00–06:00 由前一晚的夜间资料负责
            t = _dt(d, k * STEP)
            day_pts[t] = f + 0.6 * min(1, max(0, (t - wake).total_seconds() / 3600 / 6)) + rng.gauss(0, 0.12 * noise)
        for (slot, mt), target in targets.items():
            m0 = _dt(d, mt)
            t2 = min(day_pts, key=lambda t: abs((t - m0) - timedelta(minutes=120)))
            amp = (target - day_pts[t2]) / max(0.2, _bump((t2 - m0).total_seconds() / 60, 60, 1.5))
            for t in day_pts:
                tau = (t - m0).total_seconds() / 60
                if 0 < tau < 360:
                    day_pts[t] += amp * _bump(tau, 60, 1.5)
        points.update(day_pts)
        nxt = d + timedelta(days=1)
        night = {_dt(nxt, m): None for m in range(0, 6 * 60, STEP)}
        low_min = rng.uniform(3.1, 3.7)
        for t in night:
            h = (t - _dt(nxt, 0)).total_seconds() / 3600
            if night_low and 0.5 <= h <= 3.5:
                points[t] = low_min + rng.gauss(0, 0.1)
            elif false_low and i == false_day and 2 <= h <= 2.6:
                points[t] = 3.5   # 假低值
            else:
                points[t] = f + 0.3 + rng.gauss(0, 0.2 * noise)
        if night_low:
            if rng.random() < 0.75:
                ev.append(Event(type="symptom", time=_dt(nxt, 3 * 60), symptoms=["出汗", "心悸"]))
            ev.append(Event(type="glucose", time=_dt(nxt, 3 * 60 + 5), glucose=round(low_min + 0.2, 1),
                            glucose_source="finger", confirmatory=True))
        if false_low and i == false_day:
            ev.append(Event(type="glucose", time=_dt(nxt, 2 * 60 + 40), glucose=round(rng.uniform(5.2, 6.0), 1),
                            glucose_source="finger", confirmatory=True))
        if not cgm:   # 指血：空腹、三餐后（偶尔漏测）
            fp = min((t for t in points if t >= wake and t.date() == d), key=lambda t: t - wake)
            ev.append(Event(type="glucose", time=fp, glucose=round(points[fp], 1), glucose_source="finger"))
            for (slot, mt), target in targets.items():
                if rng.random() > 0.12 * noise:
                    ev.append(Event(type="glucose", time=_dt(d, mt) + timedelta(minutes=120),
                                    glucose=round(target + rng.gauss(0, 0.2 * noise), 1), glucose_source="finger"))
    if cgm:
        drop = 0.06 * noise
        ev += [Event(type="glucose", time=t, glucose=round(v, 1), glucose_source="cgm")
               for t, v in sorted(points.items()) if rng.random() > drop]
    vals = list(points.values())
    gmi = 3.31 + 0.02392 * (sum(vals) / len(vals)) * 18.016
    hba1c = round(gmi + rng.gauss(0, 0.3), 1)
    ev.append(Event(type="lab", time=_dt(start - timedelta(days=3), 9 * 60),
                    lab={"hba1c": hba1c, "fpg": round(base_f + rng.gauss(0.2, 0.3), 1), "clinic_sbp": rng.randint(128, 150),
                         "clinic_dbp": rng.randint(76, 90)}))
    ev.sort(key=lambda e: e.time)
    truth.update({"scenarios": list(scenarios), "hba1c": hba1c, "stray_low": stray_low, "false_low": false_low})
    return Patient(pid=f"P{seed:04d}", seed=seed, scenarios=tuple(scenarios), cgm=cgm, events=ev, schedule=schedule, truth=truth)


def cohort(n: int = 400, seed: int = 2026, noise: float = 1.0, days: int = 14) -> list[Patient]:
    """情境组合平均分配；约 1/4 为没有任何规律的对照。一半有监测仪，一半只有指血。"""
    combos = [(), ("dinner_high",), ("late_med_low",), ("walk_helps",), ("dinner_high", "late_med_low"),
              ("dinner_high", "walk_helps"), ("late_med_low", "walk_helps"), (), ("dinner_high", "late_med_low", "walk_helps")]
    out = []
    for k in range(n):
        out.append(make_patient(seed * 1000 + k, combos[k % len(combos)], cgm=k % 2 == 0, noise=noise, days=days))
    return out


# ---------- 分层（A/B/C/D） ----------

LAYERS = {
    "A": "只有医院检验",
    "B": "医院＋居家血糖（含症状）",
    "C": "医院＋血糖＋饮食与用药时间",
    "D": "再加入活动、睡眠、血压、体重",
}
_LAYER_TYPES = {
    "A": {"lab"},
    "B": {"lab", "glucose", "symptom"},
    "C": {"lab", "glucose", "symptom", "meal", "medication", "insulin"},
    "D": None,  # 全部
}


def layer(events: list[Event], name: str) -> list[Event]:
    keep = _LAYER_TYPES[name]
    return list(events) if keep is None else [e for e in events if e.type in keep]
