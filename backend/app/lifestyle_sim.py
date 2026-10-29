"""模拟患者两周的生活打卡与血糖（合成数据），植入已知效应，用于测试、评测与 APP 演示。

效应（mmol/L，可设为 0 表示不存在）：
- late_insulin：饭后才打餐时胰岛素 → 餐后 2 小时血糖升高
- walk：饭后 1 小时内活动 → 餐后血糖下降（填负数）
- short_sleep：睡不到 6 小时 → 次日空腹血糖升高
- evening_ex：晚上运动 → 夜间最低血糖下降（填负数）
- missed：漏打/漏服当天 → 血糖整体升高
这只是为验证算法而设的简化模型，不是生理模型。
"""
from __future__ import annotations

import random
from datetime import date, datetime, time, timedelta

from .lifestyle import Event, ScheduleItem

DEFAULT_EFFECTS = {"late_insulin": 2.5, "walk": -1.5, "short_sleep": 1.2, "evening_ex": -1.2, "missed": 3.0}
NO_EFFECTS = {k: 0.0 for k in DEFAULT_EFFECTS}
SCHEDULE = [ScheduleItem(task="insulin", time="07:30", label="早餐前餐时胰岛素"),
            ScheduleItem(task="insulin", time="11:45", label="午餐前餐时胰岛素"),
            ScheduleItem(task="insulin", time="17:45", label="晚餐前餐时胰岛素")]
# 自适应提醒的「真实」完成率（模拟用户偏好，算法事先不知道）
TRUE_RATES = {"饭后散步": {"饭后马上": 0.3, "饭后 15 分钟": 0.7, "饭后 30 分钟": 0.45},
              "记录血糖": {"早上 7 点": 0.6, "中午 12 点": 0.35, "晚上 8 点": 0.5}}


def _at(d: date, hh: float) -> datetime:
    return datetime.combine(d, time(0)) + timedelta(hours=hh)


def simulate(days: int = 14, seed: int = 0, effects: dict | None = None, start: date = date(2026, 10, 1),
             miss_rate: float = 0.08, late_rate: float = 0.3) -> list[Event]:
    fx = {**DEFAULT_EFFECTS, **(effects or {})}
    rng = random.Random(seed)
    ev: list[Event] = []
    for i in range(days):
        d = start + timedelta(days=i)
        # 睡眠：前一晚入睡，今早起床
        short = rng.random() < 0.3
        wake = _at(d, rng.uniform(6.3, 7.3))
        sleep = wake - timedelta(hours=rng.uniform(4.5, 5.8) if short else rng.uniform(7.0, 8.5))
        ev += [Event(type="sleep", time=sleep), Event(type="wake", time=wake)]
        missed_today = False
        fasting = 6.3 + (fx["short_sleep"] if short else 0) + rng.gauss(0, 0.5)
        ev.append(Event(type="glucose", time=wake + timedelta(minutes=10), glucose=round(fasting, 1)))
        for meal_h in (7.75, 12.0, 18.0):
            meal = _at(d, meal_h + rng.uniform(-0.25, 0.25))
            ev.append(Event(type="meal", time=meal, meal_size=rng.choice(["small", "normal", "normal", "large"])))
            late = rng.random() < late_rate
            missed = rng.random() < miss_rate
            shot_t = meal + timedelta(minutes=rng.uniform(10, 30)) if late else meal - timedelta(minutes=rng.uniform(10, 25))
            ev.append(Event(type="insulin", time=shot_t, insulin_kind="rapid", taken=not missed))
            missed_today |= missed
            walked = rng.random() < 0.4
            if walked:
                ev.append(Event(type="exercise", time=meal + timedelta(minutes=rng.uniform(5, 40)), minutes=rng.randint(15, 35)))
            if rng.random() < 0.85:
                pm = 9.0 + (fx["late_insulin"] if late else 0) + (fx["walk"] if walked else 0) \
                    + (fx["missed"] if missed else 0) + rng.gauss(0, 1.0)
                ev.append(Event(type="glucose", time=meal + timedelta(minutes=rng.uniform(105, 135)), glucose=round(pm, 1)))
        evening = rng.random() < 0.35
        if evening:
            ev.append(Event(type="exercise", time=_at(d, rng.uniform(19.0, 20.5)), minutes=rng.randint(25, 50)))
        if rng.random() < 0.6:
            night = 6.0 + (fx["evening_ex"] if evening else 0) + rng.gauss(0, 0.5)
            ev.append(Event(type="glucose", time=_at(d + timedelta(days=1), rng.uniform(2.5, 3.5)), glucose=round(night, 1)))
        if missed_today:
            pass  # 漏打的效应已体现在该餐的餐后血糖
    return ev


def simulate_reminders(days: int, seed: int, chooser, start: date = date(2026, 10, 1)) -> tuple[list[Event], int]:
    """逐日在线模拟：每天由 chooser(task, 已有事件) 选时段发提醒，按真实完成率决定是否完成。返回事件与完成次数。"""
    rng = random.Random(seed)
    ev: list[Event] = []
    done = 0
    for i in range(days):
        d = start + timedelta(days=i)
        for task, rates in TRUE_RATES.items():
            slot = chooser(task, ev)
            t = _at(d, 15)
            ev.append(Event(type="reminder", time=t, task=task, slot=slot))
            if rng.random() < rates[slot]:
                done += 1
                ev.append(Event(type="exercise" if task == "饭后散步" else "glucose", time=t + timedelta(minutes=30),
                                minutes=20, glucose=7.0))
    return ev, done
