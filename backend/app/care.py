"""照护核心：由全部记录算出「照护档案」，把每类资料放进同一个人的整体状况里判断。

原则（与尿检解读一致，并依老师建议文件）：
- 结论分级：事实 / 多次出现的关联 / 待问医生 / 仍然不能判断。只写「相关」，不写「导致」。
- 一次只记录，重复出现才升级为关联；证据不够时列为「观察中」并显示进度。
- 照片估算不当作实测；智能设备与照片资料都不能作为诊断或调药依据。
- 不给药物或剂量建议，用药相关一律归入「待问医生」；危险读数只由安全提示卡传达。
- 服务端无状态：每次由客户端提交记录，同样的资料一定得到同样的结果。
"""
from __future__ import annotations

import random
from datetime import date, datetime, time, timedelta
from statistics import mean, median
from typing import Literal

from pydantic import BaseModel, Field

from .lifestyle import (HIGH, LOW, VERY_HIGH, Event, ScheduleItem, _by_type, _fasting, _perm_p, analyze_patterns,
                        scheduled_doses)

SLOTS = ("breakfast", "lunch", "dinner")
SLOT_ZH = {"breakfast": "早餐", "lunch": "午餐", "dinner": "晚餐", "snack": "加餐"}
LEVEL_ORDER = {"fact": 0, "association": 1, "ask_doctor": 2, "unknown": 3}
NIGHT_START, NIGHT_END = 22, 6  # 夜间：当天 22:00 至次日 06:00
POST_MEAL_HIGH = 12.0           # 老师文件中用于描述晚餐后高值的水平（仅作描述，不是诊断标准）
LATE_MIN = 45                   # 比平常晚这么多分钟算「晚吃」
HBA1C_ABOVE = 7.0               # 常见控制目标；个人目标须由医生确定


# ---------- 请求与回应 ----------

class CareRequest(BaseModel):
    events: list[Event] = Field(default_factory=list, max_length=20000)
    schedule: list[ScheduleItem] = Field(default_factory=list, max_length=20)
    target_low: float = Field(default=LOW, ge=3.0, le=6.0)
    target_high: float = Field(default=HIGH, ge=7.0, le=14.0)
    now: datetime | None = None
    seed: int = 0


class Finding(BaseModel):
    id: str
    level: Literal["fact", "association", "ask_doctor", "unknown"]
    title: str
    headline: str                 # 一句白话（APP 第一层只显示这一句）
    detail: str = ""              # 点开后的依据与数字
    confidence: Literal["初步", "较明确"] | None = None
    evidence: dict = Field(default_factory=dict)
    question: str | None = None   # 复诊可以问医生的问题
    boundary: str | None = None   # 不能据此做什么（安全边界）
    urgent: bool = False


class Watch(BaseModel):
    """观察中的推测：证据还不够，显示进度。"""
    id: str
    title: str
    progress: str
    support: int
    against: int
    needed: int


class Alert(BaseModel):
    level: Literal["red", "yellow"]
    title: str
    text: str


class LowEpisode(BaseModel):
    start: datetime
    end: datetime
    minimum: float
    night: bool
    readings: int
    confirmed: bool | None        # True：指血复核也偏低；False：指血复核不低；None：没有复核
    confirm_value: float | None = None
    symptoms: list[str] = Field(default_factory=list)


class Metrics(BaseModel):
    source: Literal["cgm", "finger", "none"]
    readings: int
    days: int
    coverage: float | None = None   # 连续血糖监测覆盖率
    tir: float | None = None
    tar: float | None = None
    tbr: float | None = None
    mean_glucose: float | None = None
    gmi: float | None = None        # 仅在监测 ≥10 天且覆盖率 ≥70% 时计算
    fasting_median: float | None = None
    fasting_range: list[float] | None = None
    post_meal: dict[str, dict] = Field(default_factory=dict)  # 餐次 → {median, n, high_count}
    low_episodes: int = 0
    night_low_nights: int = 0
    adherence: float | None = None
    steps_mean: int | None = None
    sleep_hours_mean: float | None = None
    home_bp_mean: list[int] | None = None
    weight_change: list[float] | None = None


class Background(BaseModel):
    lab: dict[str, float] | None = None
    lab_date: date | None = None
    lab_note: str | None = None
    medications: list[str] = Field(default_factory=list)
    schedule: list[ScheduleItem] = Field(default_factory=list)
    target: list[float]
    sources: list[str] = Field(default_factory=list)  # 有哪些类资料


class Personal(BaseModel):
    """这个人自己的常态，用于即时回馈时「和你平常比较」。"""
    usual_meal_time: dict[str, str] = Field(default_factory=dict)   # 餐次 → HH:MM
    usual_carbs: dict[str, float] = Field(default_factory=dict)     # 餐次 → 碳水中位数
    usual_post_meal: dict[str, float] = Field(default_factory=dict)
    usual_fasting: list[float] | None = None                        # 四分位范围


class Today(BaseModel):
    date: date
    records: int
    meals: list[str]
    carbs_g: float | None
    meds_due: int
    meds_taken: int
    last_glucose: float | None = None
    last_glucose_time: datetime | None = None
    steps: int | None = None
    exercise_minutes: int = 0


class CareResponse(BaseModel):
    background: Background
    personal: Personal
    metrics: Metrics
    today: Today | None
    findings: list[Finding]
    watching: list[Watch]
    alerts: list[Alert]
    low_episodes: list[LowEpisode]
    doctor_questions: list[str]
    disclaimer: str = ("以上根据您记录的资料整理：「事实」是记录本身，「关联」只代表相关、不代表原因，"
                       "照片估算的份量仅供参考。这不是诊断，也不是用药建议；药物与剂量请遵医嘱，可把这些整理带去复诊。")


# ---------- 工具 ----------

def _hhmm(minutes: float) -> str:
    m = round(minutes)
    return f"{m // 60:02d}:{m % 60:02d}"


def _mins(t: datetime) -> int:
    return t.hour * 60 + t.minute


def _night_of(t: datetime) -> date:
    """夜间读数归到「哪一晚」：凌晨的读数属于前一天晚上。"""
    return t.date() - timedelta(days=1) if t.hour < NIGHT_END else t.date()


def _is_night(t: datetime) -> bool:
    return t.hour >= NIGHT_START or t.hour < NIGHT_END


def _is_deep_night(t: datetime) -> bool:
    """判断「这晚有没有夜间血糖资料」用 23:00–05:00，避免把起床的空腹读数当成夜间资料。"""
    return t.hour >= 23 or t.hour < 5


def _glucose_source(gl: list[Event]) -> list[Event]:
    """有连续血糖监测时用它算整体指标（避免指血与监测重复计算）；否则用全部读数。"""
    cgm = [g for g in gl if g.glucose_source == "cgm"]
    return cgm if len(cgm) >= max(20, len(gl) // 2) else gl


def _post_meal_value(gl: list[Event], meal: Event) -> float | None:
    c = [g for g in gl if timedelta(minutes=90) <= g.time - meal.time <= timedelta(minutes=150)]
    if not c:
        return None
    return min(c, key=lambda g: (abs((g.time - meal.time) - timedelta(minutes=120)), g.glucose_source != "finger")).glucose


def _slot_by_time(t: datetime) -> str:
    return "breakfast" if t.hour < 10 else "lunch" if t.hour < 15 else "dinner"


def _is_high_carb(m: Event, usual: float | None) -> bool:
    if m.sweet_drink:
        return True
    if m.carbs_g is not None:
        return m.carbs_g >= max(75.0, 1.3 * usual) if usual else m.carbs_g >= 80
    return m.meal_size == "large"


MIN_N = 4        # 每组至少几次才比较
P_MAX = 0.05     # 置换检验门槛。每人约比较 6 组：无规律的合成对照 200 人中约 2.5% 出现任何一条误报（见测试）


def _compare(a: list[float], b: list[float], rng: random.Random, min_n: int = MIN_N, min_diff: float = 1.0):
    """两组中位数差＋置换检验。返回 (差, p, 可信度) 或 None（样本不足、差异太小或可能只是巧合）。"""
    if len(a) < min_n or len(b) < min_n:
        return None
    d = median(a) - median(b)
    if abs(d) < min_diff:
        return None
    p = _perm_p(list(a), list(b), rng)
    if p > P_MAX:
        return None
    return round(d, 1), round(p, 3), "较明确" if (p < 0.01 and min(len(a), len(b)) >= 6) else "初步"


# ---------- 低值事件 ----------

def low_episodes(gl: list[Event], symptoms: list[Event]) -> list[LowEpisode]:
    """把低于 3.9 的读数按时间分组（间隔超过 60 分钟另起一段），并检查指血复核与症状。"""
    src = _glucose_source(gl)
    # 有监测仪时，指血复核只用来确认；只有指血时，复核读数本身就是低值的证据
    lows = sorted((g for g in src if g.glucose < LOW), key=lambda g: g.time)
    groups: list[list[Event]] = []
    for g in lows:
        if groups and g.time - groups[-1][-1].time <= timedelta(minutes=60):
            groups[-1].append(g)
        else:
            groups.append([g])
    fingers = [g for g in gl if g.glucose_source == "finger" or g.confirmatory]
    out = []
    for grp in groups:
        s, e = grp[0].time, grp[-1].time
        near = [f for f in fingers if s - timedelta(minutes=30) <= f.time <= e + timedelta(minutes=60) and f not in grp]
        conf = min(near, key=lambda f: f.glucose) if near else None
        sym = sorted({x for ev in symptoms if s - timedelta(minutes=60) <= ev.time <= e + timedelta(minutes=60)
                      for x in (ev.symptoms or [])})
        only_finger = all(g.glucose_source == "finger" or g.glucose_source is None for g in grp)
        confirmed = True if only_finger else (None if conf is None else conf.glucose < 4.0)
        out.append(LowEpisode(start=s, end=e, minimum=min(g.glucose for g in grp), night=_is_night(s),
                              readings=len(grp), confirmed=confirmed,
                              confirm_value=min(g.glucose for g in grp) if only_finger else conf.glucose if conf else None,
                              symptoms=sym))
    return out


# ---------- 照护档案 ----------

def build_profile(req: CareRequest) -> CareResponse:
    rng = random.Random(req.seed)
    ev = _by_type(req.events)
    home = [e for e in req.events if e.type != "lab"]
    now = req.now or max((e.time for e in req.events), default=datetime.now())
    gl = [g for g in ev["glucose"] if g.glucose is not None]
    src = _glucose_source(gl)
    # 旧记录没有餐次：按时间推断（复制一份，不改动传入的记录）
    meals = [m if m.meal_slot else m.model_copy(update={"meal_slot": _slot_by_time(m.time)})
             for m in ev["meal"] if m.meal_slot != "snack"]
    days = sorted({e.time.date() for e in home})
    lo, hi = req.target_low, req.target_high

    # 背景
    labs = ev["lab"]
    lab = labs[-1] if labs else None
    sources = [name for name, ok in (("连续血糖监测", any(g.glucose_source == "cgm" for g in gl)),
                                     ("指血", any(g.glucose_source != "cgm" for g in gl)),
                                     ("饮食", bool(meals)), ("用药", bool(ev["medication"] or ev["insulin"])),
                                     ("活动", bool(ev["exercise"] or ev["steps"])), ("睡眠", bool(ev["sleep"])),
                                     ("血压", bool(ev["bp"])), ("体重", bool(ev["weight"])), ("医院检验", bool(labs)))
               if ok]
    background = Background(lab=lab.lab if lab else None, lab_date=lab.time.date() if lab else None,
                            lab_note=lab.text if lab else None,
                            medications=sorted({m.med_name for m in ev["medication"] if m.med_name}),
                            schedule=req.schedule, target=[lo, hi], sources=sources)

    # 个人常态
    personal = Personal()
    post: dict[str, list[tuple[Event, float]]] = {s: [] for s in SLOTS}
    for m in meals:
        v = _post_meal_value(gl, m)
        if v is not None and m.meal_slot in post:
            post[m.meal_slot].append((m, v))
    for s in SLOTS:
        times = [_mins(m.time) for m in meals if m.meal_slot == s]
        if len(times) >= 3:
            personal.usual_meal_time[s] = _hhmm(median(times))
        carbs = [m.carbs_g for m in meals if m.meal_slot == s and m.carbs_g is not None]
        if len(carbs) >= 3:
            personal.usual_carbs[s] = round(median(carbs), 1)
        if len(post[s]) >= 3:
            personal.usual_post_meal[s] = round(median(v for _, v in post[s]), 1)
    fasting = [v for w in ev["wake"] if (v := _fasting(src, w, meals)) is not None]
    if len(fasting) >= 4:
        q = sorted(fasting)
        personal.usual_fasting = [q[len(q) // 4], q[(3 * len(q)) // 4]]

    # 指标
    vals = [g.glucose for g in src]
    cgm_days = sorted({g.time.date() for g in src if g.glucose_source == "cgm"})
    metrics = Metrics(source="cgm" if cgm_days else ("finger" if vals else "none"), readings=len(vals), days=len(days))
    if vals:
        metrics.tir = round(sum(lo <= v <= hi for v in vals) / len(vals), 3)
        metrics.tar = round(sum(v > hi for v in vals) / len(vals), 3)
        metrics.tbr = round(sum(v < lo for v in vals) / len(vals), 3)
        metrics.mean_glucose = round(mean(vals), 1)
    if cgm_days:
        metrics.coverage = round(len(vals) / (len(cgm_days) * 96), 3)
        if len(cgm_days) >= 10 and metrics.coverage >= 0.7:
            metrics.gmi = round(3.31 + 0.02392 * mean(vals) * 18.016, 1)
    if fasting:
        metrics.fasting_median = round(median(fasting), 1)
        metrics.fasting_range = [min(fasting), max(fasting)]
    for s in SLOTS:
        if post[s]:
            v = [x for _, x in post[s]]
            metrics.post_meal[s] = {"median": round(median(v), 1), "n": len(v),
                                    "high_count": sum(x >= POST_MEAL_HIGH for x in v)}
    episodes = low_episodes(gl, ev["symptom"])
    metrics.low_episodes = len(episodes)
    metrics.night_low_nights = len({_night_of(e.start) for e in episodes if e.night})
    due = taken = 0
    for d in days:
        a, b = scheduled_doses(req.schedule, ev, d, now)
        due, taken = due + a, taken + b
    metrics.adherence = round(taken / due, 3) if due else None
    if ev["steps"]:
        metrics.steps_mean = round(mean(e.steps for e in ev["steps"] if e.steps is not None))
    hours = [(w.time - s.time).total_seconds() / 3600 for w in ev["wake"]
             for s in [max((s for s in ev["sleep"] if timedelta(hours=2) <= w.time - s.time <= timedelta(hours=14)),
                           key=lambda s: s.time, default=None)] if s]
    if hours:
        metrics.sleep_hours_mean = round(mean(hours), 2)
    bp = [e for e in ev["bp"] if e.systolic and e.diastolic]
    if bp:
        metrics.home_bp_mean = [round(mean(e.systolic for e in bp)), round(mean(e.diastolic for e in bp))]
    wt = [e.weight_kg for e in ev["weight"] if e.weight_kg]
    if len(wt) >= 2:
        metrics.weight_change = [wt[0], wt[-1]]

    findings: list[Finding] = []
    watching: list[Watch] = []
    _facts(findings, metrics, personal, episodes, lo, hi)
    _associations(findings, watching, ev, meals, post, gl, src, episodes, personal, rng)
    _combined(findings, background, metrics, episodes, gl, meals)
    _unknowns(findings, gl, src, meals, ev, labs)
    findings.sort(key=lambda f: (not f.urgent, LEVEL_ORDER[f.level]))

    questions: list[str] = []
    for f in findings:
        if f.question and f.question not in questions:
            questions.append(f.question)

    return CareResponse(background=background, personal=personal, metrics=metrics,
                        today=_today(ev, home, req.schedule, now) if home else None,
                        findings=findings, watching=watching, alerts=care_alerts(gl, ev["symptom"], now),
                        low_episodes=episodes, doctor_questions=questions[:5])


# ---------- 事实 ----------

def _facts(out: list[Finding], m: Metrics, personal: Personal, episodes: list[LowEpisode], lo: float, hi: float):
    pm = {s: v for s, v in m.post_meal.items() if v["n"] >= 3}
    if len(pm) >= 2:
        top = max(pm, key=lambda s: pm[s]["median"])
        others = [v["median"] for s, v in pm.items() if s != top]
        detail = "，".join(f"{SLOT_ZH[s]}后 {v['median']}（{v['n']} 次）" for s, v in pm.items())
        enough = all(v["n"] >= 5 for v in pm.values())
        if enough and pm[top]["median"] - max(others) >= 1.0:
            out.append(Finding(id="post_meal_highest", level="fact", title="三餐后血糖比较",
                               headline=f"{SLOT_ZH[top]}后的血糖最高",
                               detail=f"餐后 2 小时血糖中位数：{detail} mmol/L。",
                               evidence={"slot": top, **{s: v for s, v in pm.items()}}))
        else:
            short = "、".join(f"{SLOT_ZH[s]} {v['median']}" for s, v in pm.items())
            out.append(Finding(id="post_meal_by_slot", level="fact", title="三餐后血糖比较",
                               headline="三餐后的血糖差不多" if enough else f"目前餐后血糖：{short}",
                               detail=f"餐后 2 小时血糖中位数：{detail} mmol/L。" + ("" if enough else "每餐至少记录 5 次后再比较哪一餐最高。"),
                               evidence=dict(pm)))
    night = [e for e in episodes if e.night]
    if night:
        nights = sorted({_night_of(e.start) for e in night})
        conf = [e.confirm_value for e in night if e.confirmed and e.confirm_value is not None]
        sym = sorted({s for e in night for s in e.symptoms})
        parts = [f"{len(nights)} 晚夜间读数低于 {LOW}"]
        if conf:
            parts.append("指血复核 " + "、".join(f"{v:g}" for v in conf))
        if sym:
            parts.append("伴" + "、".join(sym))
        unconfirmed = [e for e in night if e.confirmed is None]
        out.append(Finding(
            id="night_low", level="fact", title="夜间低值", urgent=True,
            headline=f"有 {len(nights)} 晚出现夜间低血糖",
            detail="；".join(parts) + "。" + ("其中有的没有指血复核，下次出现时请用指血复核。" if unconfirmed else ""),
            evidence={"nights": [d.isoformat() for d in nights], "confirm": conf, "symptoms": sym},
            question="我有夜间低血糖，这和我目前的用药、进餐有关吗？", boundary="请尽快带记录回诊；不要自行调整用药。"))
    if m.tir is not None and m.readings >= 20:
        src = "连续血糖监测" if m.source == "cgm" else "指血记录"
        out.append(Finding(id="time_in_range", level="fact", title="血糖在目标范围的比例",
                           headline=f"约 {round(m.tir * 100)}% 的读数在目标范围内",
                           detail=f"{src}：低于 {lo:g} 占 {round(m.tbr * 100)}%，{lo:g}–{hi:g} 占 {round(m.tir * 100)}%，"
                                  f"高于 {hi:g} 占 {round(m.tar * 100)}%。" + ("指血多在餐后测，比例只作参考。" if m.source == "finger" else ""),
                           evidence={"tir": m.tir, "tar": m.tar, "tbr": m.tbr, "source": m.source}))
    if m.fasting_median is not None and m.fasting_range:
        out.append(Finding(id="fasting", level="fact", title="空腹血糖",
                           headline=f"空腹血糖大多在 {personal.usual_fasting[0]:g}–{personal.usual_fasting[1]:g}"
                           if personal.usual_fasting else f"空腹血糖中位数 {m.fasting_median}",
                           detail=f"空腹中位数 {m.fasting_median}（{m.fasting_range[0]:g}–{m.fasting_range[1]:g}）mmol/L。",
                           evidence={"median": m.fasting_median, "range": m.fasting_range}))


# ---------- 关联（推测＋证据累积） ----------

def _associations(out, watching, ev, meals, post, gl, src, episodes, personal: Personal, rng):
    # 1. 高碳水 × 餐后血糖（各餐次分别比较）
    for s in SLOTS:
        pairs = post[s]
        usual = personal.usual_carbs.get(s)
        hi_v = [v for m, v in pairs if _is_high_carb(m, usual)]
        lo_v = [v for m, v in pairs if not _is_high_carb(m, usual)]
        if not hi_v and not any(m.carbs_g is not None or m.sweet_drink for m, _ in pairs):
            continue
        r = _compare(hi_v, lo_v, rng)
        if r and r[0] > 0:
            d, p, conf = r
            out.append(Finding(
                id=f"high_carb_{s}", level="association", title=f"{SLOT_ZH[s]}内容与餐后血糖", confidence=conf,
                headline=f"主食多或有甜饮料的{SLOT_ZH[s]}，饭后血糖比较高",
                detail=f"这类{SLOT_ZH[s]} {len(hi_v)} 次中有 {sum(v >= POST_MEAL_HIGH for v in hi_v)} 次餐后 ≥{POST_MEAL_HIGH:g}；"
                       f"其他 {len(lo_v)} 次中有 {sum(v >= POST_MEAL_HIGH for v in lo_v)} 次。餐后中位数相差 {d} mmol/L。"
                       "这是重复出现的关联，不是唯一原因。",
                evidence={"high": len(hi_v), "other": len(lo_v), "diff": d, "p": p},
                question=f"我的{SLOT_ZH[s]}主食和碳水怎么分配比较好？可以请营养师帮我看看吗？",
                boundary="不能看到餐后偏高就自行加药。"))
        elif 0 < len(hi_v) < MIN_N:
            watching.append(Watch(id=f"high_carb_{s}", title=f"{SLOT_ZH[s]}内容与餐后血糖",
                                  progress=f"主食多或有甜饮料的{SLOT_ZH[s]}已记录 {len(hi_v)} 次（含餐后血糖），至少需要 {MIN_N} 次才能比较",
                                  support=len(hi_v), against=0, needed=MIN_N))

    # 2. 晚吃但照常用药 × 夜间低值
    dinners = [m for m in meals if m.meal_slot == "dinner"]
    if len(dinners) >= 5:
        usual = median(_mins(m.time) for m in dinners)
        night_lows = {_night_of(e.start) for e in episodes if e.night}
        night_data = {_night_of(g.time) for g in gl if _is_deep_night(g.time)}
        meds = ev["medication"] + ev["insulin"]
        exposed, other = [], []
        for m in dinners:
            late = _mins(m.time) - usual
            evening_meds = [x for x in meds if x.taken and x.time.date() == m.time.date() and x.time.hour >= 15 and x.time <= m.time]
            usual_time = bool(evening_meds) and all((m.time - x.time) >= timedelta(minutes=LATE_MIN) for x in evening_meds)
            night = m.time.date()
            if late >= LATE_MIN and usual_time and (night in night_data or night in night_lows):
                exposed.append((night, night in night_lows, late))  # 那晚还没有夜间资料时先不计入
            elif night in night_data:
                other.append((night, night in night_lows))
        hit = sum(x[1] for x in exposed)
        other_rate = sum(x[1] for x in other) / len(other) if other else None
        if hit >= 2 and hit / len(exposed) >= 0.5 and (other_rate is None or other_rate <= 0.2):
            lates = [x[2] for x in exposed if x[1]]
            out.append(Finding(
                id="late_dinner_night_low", level="association", title="晚餐延迟与夜间低值", confidence="初步",
                headline="晚餐比平常晚、药照平常时间吃的那几晚，夜里出现低血糖",
                detail=f"晚吃（比平常 {_hhmm(usual)} 晚约 {round(min(lates))}–{round(max(lates))} 分钟）但用药时间没变的 {len(exposed)} 晚中，"
                       f"{hit} 晚出现夜间低值" + (f"；其他 {len(other)} 晚中 {sum(x[1] for x in other)} 晚。" if other else
                                           "；其他夜里没有夜间血糖记录，无法比较。"),
                evidence={"exposed": len(exposed), "with_low": hit, "other": len(other),
                          "other_with_low": sum(x[1] for x in other), "nights": [x[0].isoformat() for x in exposed]},
                question="晚餐延迟时，用药和进餐时间应该怎么配合？",
                boundary="不能根据这几次记录自行提前、延后服药或改变剂量。"))
        elif exposed:
            watching.append(Watch(id="late_dinner_night_low", title="晚餐延迟与夜间低值",
                                  progress=f"晚吃但照常用药的夜里已记录 {len(exposed)} 次，其中 {hit} 次出现低值；"
                                           f"至少需要 2 次出现才能判断",
                                  support=hit, against=len(exposed) - hit, needed=2))

    # 3. 饭后活动 × 餐后血糖（各餐次分别比较；提示饮食是否不同）
    for s in SLOTS:
        walked, sat, wc, sc = [], [], [], []
        for m, v in post[s]:
            moved = any(timedelta(0) <= x.time - m.time <= timedelta(minutes=60) and (x.minutes or 0) >= 10
                        for x in ev["exercise"])
            (walked if moved else sat).append(v)
            if m.carbs_g is not None:
                (wc if moved else sc).append(m.carbs_g)
        r = _compare(walked, sat, rng)
        if r and r[0] < 0:
            d, p, conf = r
            confound = bool(wc and sc and abs(mean(wc) - mean(sc)) >= 15)
            out.append(Finding(
                id=f"walk_{s}", level="association", title=f"{SLOT_ZH[s]}后活动", confidence=conf,
                headline=f"{SLOT_ZH[s]}后走一走的那几天，饭后血糖比较低",
                detail=f"{SLOT_ZH[s]}后 1 小时内有活动的 {len(walked)} 次，餐后中位数 {round(median(walked), 1)}；"
                       f"没有活动的 {len(sat)} 次为 {round(median(sat), 1)}。"
                       + ("这几天吃的也不太一样，不能证明是活动造成全部差异。" if confound else "只代表相关，不能证明因果。"),
                evidence={"walked": len(walked), "sat": len(sat), "diff": d, "p": p, "diet_differs": confound},
                question="饭后散步适合我吗？多长时间、什么强度比较合适？",
                boundary="请在医生确认没有运动禁忌后再规律进行。"))
        elif 0 < len(walked) < MIN_N:
            watching.append(Watch(id=f"walk_{s}", title=f"{SLOT_ZH[s]}后活动",
                                  progress=f"{SLOT_ZH[s]}后散步已记录 {len(walked)} 次，至少需要 {MIN_N} 次才能比较",
                                  support=len(walked), against=0, needed=MIN_N))

    # 4. 沿用原有的生活规律（打针时机、睡眠、晚间运动、漏药）；饭后活动已改为分餐次比较
    seen = {f.id for f in out}
    for i in analyze_patterns(ev, rng):
        if i.id == "post_meal_walk" or (i.id == "evening_exercise_night_low" and "late_dinner_night_low" in seen):
            continue
        out.append(Finding(id=i.id, level="association", title=i.title, headline=i.headline, detail=i.finding,
                           confidence=i.confidence, question=i.doctor_question,
                           evidence={"groups": [g.model_dump() for g in i.groups], "diff": i.difference, "p": i.p_value}))


# ---------- 医院检验 × 居家资料 ----------

def _combined(out, bg: Background, m: Metrics, episodes, gl, meals):
    lab = bg.lab or {}
    a1c = lab.get("hba1c")
    if a1c is not None and a1c >= HBA1C_ABOVE and any(e.confirmed is not False for e in episodes):
        out.append(Finding(
            id="hba1c_high_with_lows", level="ask_doctor", title="平均偏高，但也有低血糖", urgent=True,
            headline="糖化血红蛋白偏高，同时居家出现低血糖：请尽快带记录回诊",
            detail=f"糖化血红蛋白 {a1c:g}% 代表近期平均偏高，但居家记录有 {len(episodes)} 次低值。"
                   "高值和低值并存时，需要医生一起看用药、进餐和监测记录。",
            evidence={"hba1c": a1c, "low_episodes": len(episodes)},
            question="我平均血糖偏高，但又有低血糖，治疗方案需要怎么调整？",
            boundary="不能看到平均偏高就自行加药或加量。"))
    if a1c is not None and m.gmi is not None and abs(a1c - m.gmi) >= 0.5:
        out.append(Finding(id="hba1c_gmi_gap", level="ask_doctor", title="医院检验与居家监测的差异",
                           headline="医院的糖化血红蛋白和居家监测估算值不太一致",
                           detail=f"糖化血红蛋白 {a1c:g}%，居家监测估算（GMI）{m.gmi:g}%。两者可因监测时段、"
                                  "个人差异等而不同，请医生一起解读。",
                           evidence={"hba1c": a1c, "gmi": m.gmi}, question="我的糖化血红蛋白和居家监测结果不太一致，该看哪一个？"))
    sbp, dbp = lab.get("clinic_sbp"), lab.get("clinic_dbp")
    home = m.home_bp_mean
    if (sbp and dbp and (sbp >= 140 or dbp >= 90)) or (home and (home[0] >= 135 or home[1] >= 85)):
        parts = []
        if sbp and dbp:
            parts.append(f"诊间 {sbp:g}/{dbp:g}")
        if home:
            parts.append(f"家庭平均 {home[0]}/{home[1]}")
        out.append(Finding(id="blood_pressure", level="fact", title="血压",
                           headline="血压仍偏高，需要和血糖一起长期管理",
                           detail="血压 " + "，".join(parts) + " mmHg。血压纳入整体心肾风险管理，不用于解释某一次血糖。",
                           evidence={"clinic": [sbp, dbp], "home": home},
                           question="我的血压目标是多少？需要怎么一起管理？"))
    if lab and not gl:
        out.append(Finding(id="lab_only", level="unknown", title="只有医院检验",
                           headline="只有医院检验，还看不出血糖何时偏高、有没有夜间低值",
                           detail="建议记录约 14 天的血糖（空腹、三餐后 2 小时，可能的话加夜间），再一起整理。",
                           evidence={"hba1c": a1c}))


# ---------- 仍然不能判断 ----------

def _unknowns(out, gl, src, meals, ev, labs):
    if gl and not any(_is_deep_night(g.time) for g in gl):
        out.append(Finding(id="no_night_data", level="unknown", title="夜间血糖",
                           headline="没有夜间血糖记录，无法判断有没有夜间低血糖",
                           detail="如果夜里出汗、心悸或做噩梦，请测一次指血。"))
    if gl and not meals:
        out.append(Finding(id="no_meal_data", level="unknown", title="饮食",
                           headline="没有饮食记录，无法判断血糖和吃什么有关", detail="拍照记录三餐即可。"))
    if gl and meals and not labs:
        out.append(Finding(id="no_lab", level="unknown", title="医院检验",
                           headline="还没有医院检验结果，无法结合整体控制情况",
                           detail="可以输入最近一次的糖化血红蛋白和空腹血糖。"))
    if any(m.estimate == "photo" for m in meals):
        corrected = sum(1 for m in meals if m.corrected_by)
        out.append(Finding(id="photo_estimate", level="unknown", title="照片估算",
                           headline="照片估算的份量只供参考，不当作实测",
                           detail="照片估算的碳水可能有误差" + (f"；已有 {corrected} 餐由家人或本人修正，原始估算与修正记录都保留。"
                                                         if corrected else "，家人可以帮忙复秤修正。"),
                           evidence={"corrected": corrected}))


# ---------- 今天 ----------

def _today(ev, home, schedule, now) -> Today:
    d = now.date()
    todays = [e for e in home if e.time.date() == d]
    meals = [m for m in ev["meal"] if m.time.date() == d and m.meal_slot != "snack"]
    carbs = [m.carbs_g for m in meals if m.carbs_g is not None]
    due, taken = scheduled_doses(schedule, ev, d, now)
    gl = [g for g in ev["glucose"] if g.glucose is not None and g.time <= now]
    last = gl[-1] if gl else None
    steps = [e.steps for e in ev["steps"] if e.time.date() == d and e.steps is not None]
    return Today(date=d, records=len(todays), meals=[SLOT_ZH.get(m.meal_slot or "", "进餐") for m in meals],
                 carbs_g=round(sum(carbs), 1) if carbs else None, meds_due=due, meds_taken=taken,
                 last_glucose=last.glucose if last else None, last_glucose_time=last.time if last else None,
                 steps=steps[-1] if steps else None,
                 exercise_minutes=sum(x.minutes or 0 for x in ev["exercise"] if x.time.date() == d))


# ---------- 安全提示 ----------

def care_alerts(gl: list[Event], symptoms: list[Event], now: datetime) -> list[Alert]:
    """最近 3 小时内的危险读数。处理措辞沿用原有提示卡，待医学审核。"""
    recent = [g for g in gl if timedelta(0) <= now - g.time <= timedelta(hours=3)]
    if not recent:
        return []
    last = recent[-1]
    if last.glucose < LOW:
        confirm = "" if last.glucose_source == "finger" or last.confirmatory else "（监测仪读数，请同时用指血复核）"
        return [Alert(level="red", title="血糖偏低",
                      text=f"最近一次血糖 {last.glucose:g} mmol/L{confirm}，低于 3.9。请按医生教过的低血糖处理方法处理，"
                           "并在 15 分钟后复测；如出现意识不清、抽搐，请家人立即拨打 120。")]
    if last.glucose >= VERY_HIGH:
        return [Alert(level="yellow", title="血糖很高",
                      text=f"最近一次血糖 {last.glucose:g} mmol/L。如同时有口渴多尿、恶心呕吐、腹痛或呼吸深快，请尽快就医。")]
    return []
