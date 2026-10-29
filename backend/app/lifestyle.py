"""生活作息 × 血糖规律分析、陪伴宠物状态与自适应提醒（原型）。

设计原则（与解读模块一致）：
- 只做「个人规律的描述」，写「相关」不写「导致」；不给胰岛素或药物剂量建议，规律只建议「复诊时与医生讨论」。
- 宠物「健康」只随「是否按时用药/打针」变化：漏用会生病（警示），按时用药即可恢复，最低不会低于 20（不会死亡）；
  宠物不反映血糖值或检验结果的好坏，避免用户因为数值不好而不敢记录。可关闭负面反馈。
- 低血糖等危险情况只由醒目的提示卡传达，不靠宠物表情。
- 服务端无状态：每次由客户端提交最近的记录，算法可复现（随机数由 seed 决定）。
"""
from __future__ import annotations

import random
from collections import defaultdict
from datetime import date, datetime, time, timedelta
from statistics import median
from typing import Literal

from pydantic import BaseModel, Field

# ---------- 数据结构 ----------

EventType = Literal["insulin", "medication", "meal", "exercise", "sleep", "wake", "glucose", "reminder"]


class Event(BaseModel):
    type: EventType
    time: datetime
    taken: bool = True                 # insulin/medication：False 表示记录「漏了」
    insulin_kind: str | None = None    # rapid（餐时）/ basal（基础）——仅记录，不做剂量建议
    meal_size: Literal["small", "normal", "large"] | None = None
    minutes: int | None = None         # exercise 时长
    glucose: float | None = None       # mmol/L
    task: str | None = None            # reminder：提醒的任务
    slot: str | None = None            # reminder：提醒时段（自适应提醒用）


class ScheduleItem(BaseModel):
    task: Literal["insulin", "medication"]
    time: str                          # "HH:MM"，按医嘱
    label: str = ""


class LifestyleRequest(BaseModel):
    events: list[Event] = Field(default_factory=list, max_length=5000)
    schedule: list[ScheduleItem] = Field(default_factory=list, max_length=20)
    today: date | None = None
    negative_feedback: bool = True     # 宠物是否会因漏用药而「生病」
    seed: int = 0


class Group(BaseModel):
    label: str
    n: int
    median: float | None


class Insight(BaseModel):
    id: str
    title: str
    finding: str
    groups: list[Group]
    difference: float | None
    p_value: float | None
    confidence: Literal["初步", "较明确"]
    doctor_question: str


class Alert(BaseModel):
    level: Literal["red", "yellow"]
    title: str
    text: str


class Metrics(BaseModel):
    readings: int
    tir: float | None      # 3.9–10.0 mmol/L 比例
    tbr: float | None      # <3.9
    tar: float | None      # >10.0
    low_events: int
    adherence: float | None  # 按时用药/打针比例


class PetState(BaseModel):
    health: int            # 0–100，随用药依从变化（≥20）
    energy: int            # 0–100，随运动/睡眠/记录变化
    health_state: Literal["健康", "有点不舒服", "生病了"]
    energy_state: Literal["活泼", "平静", "困倦"]
    mood: Literal["开心", "普通", "担心"]
    message: str
    safety_note: str | None = None
    streak_days: int = 0


class Reminder(BaseModel):
    task: str
    when: str
    reason: str
    adaptive: dict | None = None


class LifestyleResponse(BaseModel):
    metrics: Metrics
    insights: list[Insight]
    alerts: list[Alert]
    pet: PetState
    reminders: list[Reminder]
    disclaimer: str = ("以上为根据您记录的数据整理的个人规律，只代表「相关」，不代表因果，也不是用药建议。"
                       "胰岛素与药物剂量请遵医嘱，可把规律带去复诊时和医生讨论。")


# ---------- 统计工具 ----------

LOW, HIGH, VERY_HIGH = 3.9, 10.0, 16.7


def _perm_p(a: list[float], b: list[float], rng: random.Random, n_perm: int = 2000) -> float:
    """两组中位数差的置换检验（双侧）。样本小、分布未知时比 t 检验稳妥。"""
    obs = abs(median(a) - median(b))
    pool, na, hits = a + b, len(a), 0
    for _ in range(n_perm):
        rng.shuffle(pool)
        if abs(median(pool[:na]) - median(pool[na:])) >= obs - 1e-9:
            hits += 1
    return (hits + 1) / (n_perm + 1)


def _compare(id_, title, a_label, a, b_label, b, rng, min_n=4, min_diff=1.0, finding=None, question=""):
    """比较两组血糖；样本不足或差异太小时不输出。"""
    if len(a) < min_n or len(b) < min_n:
        return None
    d = median(a) - median(b)
    if abs(d) < min_diff:
        return None
    p = _perm_p(list(a), list(b), rng)
    if p > 0.2:
        return None
    conf = "较明确" if (p < 0.05 and min(len(a), len(b)) >= 6) else "初步"
    return Insight(
        id=id_, title=title,
        finding=finding(d) if finding else f"{a_label}时，血糖中位数比{b_label}{'高' if d > 0 else '低'} {abs(d):.1f} mmol/L。",
        groups=[Group(label=a_label, n=len(a), median=round(median(a), 1)), Group(label=b_label, n=len(b), median=round(median(b), 1))],
        difference=round(d, 1), p_value=round(p, 3), confidence=conf, doctor_question=question)


# ---------- 事件整理 ----------

def _by_type(events: list[Event]) -> dict[str, list[Event]]:
    out: dict[str, list[Event]] = defaultdict(list)
    for e in sorted(events, key=lambda e: e.time):
        out[e.type].append(e)
    return out


def _glucose_between(gl: list[Event], start: datetime, end: datetime) -> list[float]:
    return [g.glucose for g in gl if g.glucose is not None and start <= g.time <= end]


def _post_meal(gl, meal: Event) -> float | None:
    """餐后约 2 小时血糖：进餐开始后 90–150 分钟内最接近 120 分钟的读数。"""
    cands = [g for g in gl if g.glucose is not None and timedelta(minutes=90) <= g.time - meal.time <= timedelta(minutes=150)]
    if not cands:
        return None
    return min(cands, key=lambda g: abs((g.time - meal.time) - timedelta(minutes=120))).glucose


def _fasting(gl, wake: Event, meals) -> float | None:
    """空腹血糖：起床后、第一餐之前（2 小时内）的第一个读数。"""
    first_meal = next((m.time for m in meals if m.time > wake.time), wake.time + timedelta(hours=2))
    limit = min(first_meal, wake.time + timedelta(hours=2))
    vals = [g for g in gl if g.glucose is not None and wake.time - timedelta(minutes=30) <= g.time <= limit]
    return vals[0].glucose if vals else None


# ---------- 规律分析 ----------

def analyze_patterns(ev: dict[str, list[Event]], rng: random.Random) -> list[Insight]:
    gl, meals = ev["glucose"], ev["meal"]
    rapid = [i for i in ev["insulin"] if i.taken and (i.insulin_kind or "rapid") == "rapid"]
    out: list[Insight | None] = []

    # 1. 餐时胰岛素与进餐间隔 × 餐后 2 小时血糖
    ontime, late = [], []
    for m in meals:
        pm = _post_meal(gl, m)
        if pm is None:
            continue
        shot = min(rapid, key=lambda i: abs(i.time - m.time), default=None)
        if shot is None or abs(shot.time - m.time) > timedelta(minutes=90):
            continue
        gap = (m.time - shot.time).total_seconds() / 60  # 正数：先打针后吃饭
        (late if gap < 0 else ontime).append(pm)
    out.append(_compare("insulin_timing", "打针与吃饭的先后", "饭后才打餐时胰岛素", late, "饭前按时打", ontime, rng,
                        finding=lambda d: f"饭后才打餐时胰岛素的那几餐，饭后 2 小时血糖中位数{'高' if d > 0 else '低'} {abs(d):.1f} mmol/L。",
                        question="我打餐时胰岛素的时间点合适吗？和吃饭应该间隔多久？"))

    # 2. 饭后 1 小时内运动 × 餐后血糖
    walked, sat = [], []
    for m in meals:
        pm = _post_meal(gl, m)
        if pm is None:
            continue
        moved = any(timedelta(0) <= x.time - m.time <= timedelta(minutes=60) and (x.minutes or 0) >= 10 for x in ev["exercise"])
        (walked if moved else sat).append(pm)
    out.append(_compare("post_meal_walk", "饭后活动", "饭后 1 小时内活动", walked, "饭后没有活动", sat, rng,
                        finding=lambda d: f"饭后 1 小时内有活动的那几餐，饭后 2 小时血糖中位数{'低' if d < 0 else '高'} {abs(d):.1f} mmol/L。",
                        question="饭后散步对我的血糖有帮助，我适合的运动量和时间是多少？"))

    # 3. 睡眠时长 × 次日空腹血糖
    short, enough = [], []
    for w in ev["wake"]:
        slept = max((s for s in ev["sleep"] if timedelta(hours=2) <= w.time - s.time <= timedelta(hours=14)), key=lambda s: s.time, default=None)
        fb = _fasting(gl, w, meals)
        if slept is None or fb is None:
            continue
        hours = (w.time - slept.time).total_seconds() / 3600
        if hours < 6:
            short.append(fb)
        elif hours >= 7:
            enough.append(fb)
    out.append(_compare("sleep_fasting", "睡眠与空腹血糖", "睡不到 6 小时的隔天", short, "睡满 7 小时的隔天", enough, rng,
                        min_diff=0.8,
                        finding=lambda d: f"睡不到 6 小时的隔天，空腹血糖中位数{'高' if d > 0 else '低'} {abs(d):.1f} mmol/L。",
                        question="睡眠不足时我的空腹血糖偏高，需要注意什么？"))

    # 4. 晚间运动 × 夜间低血糖（0–6 点读数）
    def night_min(day_end: datetime) -> float | None:
        vals = _glucose_between(gl, day_end, day_end + timedelta(hours=6))
        return min(vals) if vals else None
    eve, no_eve = [], []
    days = sorted({e.time.date() for e in gl})
    for d in days:
        nm = night_min(datetime.combine(d + timedelta(days=1), time(0)))
        if nm is None:
            continue
        had = any(x.time.date() == d and x.time.hour >= 18 and (x.minutes or 0) >= 20 for x in ev["exercise"])
        (eve if had else no_eve).append(nm)
    out.append(_compare("evening_exercise_night_low", "晚间运动与夜间血糖", "晚上运动过的夜里", eve, "晚上没运动的夜里", no_eve, rng,
                        min_n=3, min_diff=0.8,
                        finding=lambda d: f"晚上运动过的夜里，夜间最低血糖中位数{'低' if d < 0 else '高'} {abs(d):.1f} mmol/L。",
                        question="我晚上运动后夜里血糖会偏低，运动时间或睡前加餐需要怎么安排？"))

    # 5. 漏用药/漏打针当天 × 高血糖
    missed_days = {e.time.date() for t in ("insulin", "medication") for e in ev[t] if not e.taken}
    hi_miss, hi_ok = [], []
    for d in days:
        vals = [g.glucose for g in gl if g.time.date() == d and g.glucose is not None]
        if vals:
            (hi_miss if d in missed_days else hi_ok).append(max(vals))
    out.append(_compare("missed_dose_high", "漏用药与高血糖", "有漏用药/漏打针的日子", hi_miss, "按时用药的日子", hi_ok, rng,
                        min_n=2, min_diff=1.5,
                        finding=lambda d: f"有漏用药或漏打针的日子，当天最高血糖中位数{'高' if d > 0 else '低'} {abs(d):.1f} mmol/L。",
                        question="如果忘了打针或吃药，我应该怎么处理？"))
    return [i for i in out if i]


# ---------- 指标与提示 ----------

def scheduled_doses(schedule: list[ScheduleItem], ev, day: date, now: datetime) -> tuple[int, int]:
    """返回（应用药次数, 实际按时次数）。按医嘱时间 ±2 小时内有「已用」记录算按时；时间未到不计。"""
    due = taken = 0
    for s in schedule:
        hh, mm = (int(x) for x in s.time.split(":"))
        t = datetime.combine(day, time(hh, mm))
        if t + timedelta(hours=2) > now:
            continue
        due += 1
        if any(e.taken and abs(e.time - t) <= timedelta(hours=2) for e in ev[s.task]):
            taken += 1
    return due, taken


def _missed_records(ev, day: date) -> int:
    return sum(1 for t in ("insulin", "medication") for e in ev[t] if e.time.date() == day and not e.taken)


def compute_metrics(ev, schedule, days: list[date], now) -> Metrics:
    vals = [g.glucose for g in ev["glucose"] if g.glucose is not None]
    n = len(vals)
    due = taken = 0
    for d in days:
        a, b = scheduled_doses(schedule, ev, d, now)
        due, taken = due + a, taken + b
    return Metrics(readings=n,
                   tir=round(sum(LOW <= v <= HIGH for v in vals) / n, 3) if n else None,
                   tbr=round(sum(v < LOW for v in vals) / n, 3) if n else None,
                   tar=round(sum(v > HIGH for v in vals) / n, 3) if n else None,
                   low_events=sum(v < LOW for v in vals),
                   adherence=round(taken / due, 3) if due else None)


def safety_alerts(ev, now: datetime) -> list[Alert]:
    """最近 3 小时内的危险读数。处理措辞待医学审核。"""
    recent = [g for g in ev["glucose"] if g.glucose is not None and timedelta(0) <= now - g.time <= timedelta(hours=3)]
    if not recent:
        return []
    last = recent[-1].glucose
    if last < LOW:
        return [Alert(level="red", title="血糖偏低",
                      text=f"最近一次血糖 {last} mmol/L，低于 3.9。请按医生教过的低血糖处理方法处理，并在 15 分钟后复测；"
                           "如出现意识不清、抽搐，请家人立即拨打 120。")]
    if last >= VERY_HIGH:
        return [Alert(level="yellow", title="血糖很高",
                      text=f"最近一次血糖 {last} mmol/L。如同时有口渴多尿、恶心呕吐、腹痛或呼吸深快，请尽快就医。")]
    return []


# ---------- 宠物 ----------

def pet_state(ev, schedule, days: list[date], now: datetime, negative: bool, metrics_week: tuple[float | None, float | None]) -> PetState:
    health, energy, streak = 100.0, 60.0, 0
    prev_h, prev_e = "健康", "平静"
    missed_today = False
    for d in days:
        due, taken = scheduled_doses(schedule, ev, d, now)
        missed = (due - taken) + _missed_records(ev, d)
        if d == days[-1]:
            missed_today = missed > 0
        if missed and negative:
            health = max(20.0, health - 25 * missed)       # 漏一次扣 25，最低 20，不会「死亡」
            streak = 0
        elif due:
            health = min(100.0, health + 20)               # 按时用药一天恢复 20：1–2 天就能好转
            streak += 1
        # 活力：当天运动 ≥20 分钟、睡眠 6–9 小时、有记录血糖，各占 1/3，指数平滑 λ=0.8
        moved = sum(x.minutes or 0 for x in ev["exercise"] if x.time.date() == d) >= 20
        slept = any(6 <= (w.time - s.time).total_seconds() / 3600 <= 9 for w in ev["wake"] if w.time.date() == d
                    for s in ev["sleep"] if timedelta(hours=2) <= w.time - s.time <= timedelta(hours=14))
        logged = any(g.time.date() == d for g in ev["glucose"])
        c = (moved + slept + logged) / 3
        energy = 0.8 * energy + 0.2 * 100 * c
        prev_h = _band(health, prev_h, [(70, "健康"), (40, "有点不舒服"), (0, "生病了")])
        prev_e = _band(energy, prev_e, [(70, "活泼"), (40, "平静"), (0, "困倦")])

    tir_now, tir_before = metrics_week
    celebrate = tir_now is not None and tir_before is not None and tir_now - tir_before >= 0.05  # 只奖励不惩罚
    if prev_h == "生病了":
        mood, msg = "担心", "小兔连着几次没按时吃药，生病躺下了……按医嘱用药，我们一起慢慢好起来！"
    elif missed_today and negative:
        mood, msg = "担心", "今天忘了用药，小兔也觉得不舒服了。记得按医嘱用药哦！"
    elif prev_h == "有点不舒服" and negative:
        mood, msg = "普通", "小兔前几天漏了药，还有点不舒服；接下来按时用药，很快就能恢复精神！"
    elif not negative and missed_today:
        mood, msg = "普通", "小兔在等你一起按时用药～"
    elif celebrate:
        mood, msg = "开心", "这一周血糖在目标范围的时间变多了，小兔开心得转圈圈！"
    elif streak >= 3:
        mood, msg = "开心", f"已经连续 {streak} 天按时用药，小兔精神满满！"
    elif prev_e == "困倦":
        mood, msg = "普通", "小兔有点没精神，饭后一起去散散步吧？"
    else:
        mood, msg = "普通", "今天也一起照顾好自己吧！"
    note = None
    if missed_today and any(not e.taken and e.time.date() == days[-1] for e in ev["insulin"]):
        note = "漏打了胰岛素：不要自己补打双倍，请按医生交代的方法处理；不确定时先监测血糖并咨询医生。"
    return PetState(health=round(health), energy=round(energy), health_state=prev_h, energy_state=prev_e,
                    mood=mood, message=msg, safety_note=note, streak_days=streak)


def _band(value: float, prev: str, bands: list[tuple[float, str]], hysteresis: float = 5) -> str:
    """带滞回的分段：从当前状态切换需越过阈值 ±5，避免在阈值附近来回跳。"""
    lo_of = {name: lo for lo, name in bands}
    order = [name for _, name in bands]
    raw = next(name for lo, name in bands if value >= lo)
    if raw == prev:
        return raw
    if order.index(raw) < order.index(prev):          # 变好：要超过新状态门槛 +5
        return raw if value >= lo_of[raw] + hysteresis else prev
    return raw if value < lo_of[prev] - hysteresis else prev  # 变差：要低于原状态门槛 −5


# ---------- 自适应提醒（Thompson 采样） ----------

ADAPTIVE_TASKS = {
    "饭后散步": {"slots": {"饭后马上": 0, "饭后 15 分钟": 15, "饭后 30 分钟": 30}, "done": "exercise"},
    "记录血糖": {"slots": {"早上 7 点": 7 * 60, "中午 12 点": 12 * 60, "晚上 8 点": 20 * 60}, "done": "glucose"},
}


def choose_slot(task: str, ev, rng: random.Random) -> dict:
    """每个时段维护 Beta(1+成功, 1+失败)；提醒后 2 小时内完成任务记为成功。抽样取最大者。"""
    conf = ADAPTIVE_TASKS[task]
    stats = {s: [1, 1] for s in conf["slots"]}
    for r in ev["reminder"]:
        if r.task != task or r.slot not in stats:
            continue
        ok = any(timedelta(0) <= e.time - r.time <= timedelta(hours=2) for e in ev[conf["done"]])
        stats[r.slot][0 if ok else 1] += 1
    draws = {s: rng.betavariate(a, b) for s, (a, b) in stats.items()}
    best = max(draws, key=draws.get)
    return {"slot": best, "posterior_mean": {s: round(a / (a + b), 2) for s, (a, b) in stats.items()},
            "trials": {s: a + b - 2 for s, (a, b) in stats.items()}}


def build_reminders(req: LifestyleRequest, ev, now: datetime, rng: random.Random, insights: list[Insight]) -> list[Reminder]:
    out = [Reminder(task="打胰岛素" if s.task == "insulin" else "用药", when=s.time, reason=s.label or "按医嘱时间")
           for s in sorted(req.schedule, key=lambda s: s.time)]
    for task in ADAPTIVE_TASKS:
        choice = choose_slot(task, ev, rng)
        out.append(Reminder(task=task, when=choice["slot"], reason="根据您过去完成提醒的情况自动调整时段", adaptive=choice))
    recent_evening = [x for x in ev["exercise"] if x.time.hour >= 18 and timedelta(0) <= now - x.time <= timedelta(hours=6)]
    if recent_evening or any(i.id == "evening_exercise_night_low" for i in insights):
        out.append(Reminder(task="睡前测一次血糖", when="睡前", reason="晚上运动后夜间血糖可能偏低"))
    return out


# ---------- 入口 ----------

def analyze_lifestyle(req: LifestyleRequest) -> LifestyleResponse:
    rng = random.Random(req.seed)
    ev = _by_type(req.events)
    now = max([e.time for e in req.events], default=datetime.now())
    today = req.today or now.date()
    first = min([e.time.date() for e in req.events], default=today)
    days = [first + timedelta(days=i) for i in range((today - first).days + 1)][-60:]
    metrics = compute_metrics(ev, req.schedule, days, now)
    insights = analyze_patterns(ev, rng)

    def tir_between(a: date, b: date):
        vals = [g.glucose for g in ev["glucose"] if g.glucose is not None and a <= g.time.date() <= b]
        return sum(LOW <= v <= HIGH for v in vals) / len(vals) if len(vals) >= 10 else None
    week = (tir_between(today - timedelta(days=6), today), tir_between(today - timedelta(days=13), today - timedelta(days=7)))
    pet = pet_state(ev, req.schedule, days, now, req.negative_feedback, week)
    return LifestyleResponse(metrics=metrics, insights=insights, alerts=safety_alerts(ev, now), pet=pet,
                             reminders=build_reminders(req, ev, now, rng, insights))
