"""即时回馈与整理：每记一笔就在整体脉络中回应；每日小结、改善计划、周报与复诊摘要。

所有判断由规则与统计产生（可复现、可检查）；文字由模板组成，之后可交给大模型润色并经安全校验。
不给药物或剂量建议；危险读数只用安全提示卡传达。
"""
from __future__ import annotations

from datetime import date, datetime, time, timedelta
from statistics import median
from typing import Literal

from pydantic import BaseModel, Field

from .care import (LATE_MIN, POST_MEAL_HIGH, SLOT_ZH, Alert, CareRequest, CareResponse, Finding, _glucose_source,
                   _is_high_carb, _is_night, _mins, _post_meal_value, _slot_by_time, build_profile, care_alerts)
from .lifestyle import HIGH, LOW, VERY_HIGH, Event, ScheduleItem

HYPO_SYMPTOMS = {"出汗", "心悸", "手抖", "饥饿", "头晕", "乏力", "意识模糊", "噩梦"}


# ---------- 回应格式 ----------

class Reminder(BaseModel):
    at: datetime
    title: str
    reason: str


class Feedback(BaseModel):
    """对一笔新记录的回应。"""
    time: datetime
    type: str
    tone: Literal["good", "info", "caution", "alert"]
    title: str
    text: str
    based_on: list[str] = Field(default_factory=list)   # 依据了哪些资料（可点开查看）
    reminders: list[Reminder] = Field(default_factory=list)


class Change(BaseModel):
    """这笔记录让照护档案出现的变化（新的结论、观察升级）。"""
    kind: Literal["new_finding", "promoted"]
    id: str
    text: str


class RecordRequest(CareRequest):
    new: list[Event] = Field(default_factory=list, max_length=3000)  # 刚记下的记录（含监测仪批量同步；不必重复放在 events 里）


class RecordResponse(BaseModel):
    feedback: list[Feedback]
    changes: list[Change]
    alerts: list[Alert]
    reminders: list[Reminder]
    profile: CareResponse


# ---------- 即时回馈 ----------

def on_record(req: RecordRequest) -> RecordResponse:
    """把新记录放进整体状况：先用旧记录算出「之前」，再加入新记录算出「之后」，逐笔回应并比较变化。"""
    history = [e for e in req.events if e not in req.new]  # 新记录若也放在 events 里，不重复计算
    all_events = history + list(req.new)
    now = req.now or max((e.time for e in all_events), default=datetime.now())
    base = req.model_copy(update={"events": history, "now": now})
    before = build_profile(CareRequest(**base.model_dump(exclude={"new"})))
    after = build_profile(CareRequest(**base.model_copy(update={"events": all_events}).model_dump(exclude={"new"})))

    new = sorted(req.new, key=lambda e: e.time)
    cgm = [e for e in new if e.type == "glucose" and e.glucose_source == "cgm" and not e.confirmatory]
    if len(cgm) > 3:  # 监测仪批量同步：只回应低值、很高的读数和最后一笔，其余合并成一句
        keep, prev_low = set(), None
        for e in cgm:  # 每段低值（间隔 60 分钟内算同一段）只提示第一笔
            if e.glucose < LOW:
                if prev_low is None or e.time - prev_low > timedelta(minutes=60):
                    keep.add(id(e))
                prev_low = e.time
            elif e.glucose >= VERY_HIGH:
                keep.add(id(e))
        keep.add(id(cgm[-1]))
        new = [e for e in new if not (e in cgm and id(e) not in keep)]
    feedback = [fb for e in new if (fb := _respond(e, history, all_events, before, after))]
    if len(cgm) > 3:
        lows = sum(e.glucose < LOW for e in cgm)
        feedback.insert(0, Feedback(time=cgm[-1].time, type="glucose", tone="alert" if lows else "info",
                                    title=f"已同步 {len(cgm)} 笔监测仪读数",
                                    text=f"{cgm[0].time:%m-%d %H:%M} 至 {cgm[-1].time:%m-%d %H:%M}，"
                                         f"{sum(LOW <= e.glucose <= HIGH for e in cgm)} 笔在目标范围内"
                                         + (f"，{lows} 笔低于 3.9。" if lows else "。"),
                                    based_on=["监测仪读数"]))
    changes = _changes(before, after)
    reminders = [r for fb in feedback for r in fb.reminders]
    return RecordResponse(feedback=feedback, changes=changes, alerts=care_alerts(
        [g for g in all_events if g.type == "glucose" and g.glucose is not None], [], now),
        reminders=reminders, profile=after)


def _finding(p: CareResponse, fid: str) -> Finding | None:
    return next((f for f in p.findings if f.id == fid), None)


def _changes(before: CareResponse, after: CareResponse) -> list[Change]:
    old = {f.id for f in before.findings}
    watched = {w.id for w in before.watching}
    out = []
    for f in after.findings:
        if f.id in old or f.level == "unknown":
            continue
        if f.id in watched:
            out.append(Change(kind="promoted", id=f.id, text=f"「{f.title}」证据够了，升级为{_LEVEL_ZH[f.level]}：{f.headline}"))
        else:
            out.append(Change(kind="new_finding", id=f.id, text=f"新发现（{_LEVEL_ZH[f.level]}）：{f.headline}"))
    return out


_LEVEL_ZH = {"fact": "事实", "association": "多次出现的关联", "ask_doctor": "待问医生", "unknown": "仍然不能判断"}


def _context(g: Event, history: list[Event]) -> tuple[str, str | None, Event | None]:
    """判断一笔血糖是什么时候测的：fasting / post_meal / night / other，以及对应的餐次。"""
    meals = [m for m in history if m.type == "meal" and m.meal_slot != "snack"]
    meal = max((m for m in meals if timedelta(minutes=90) <= g.time - m.time <= timedelta(minutes=150)),
               key=lambda m: m.time, default=None)
    if meal:
        return "post_meal", meal.meal_slot or _slot_by_time(meal.time), meal
    wake = max((w for w in history if w.type == "wake" and timedelta(minutes=-30) <= g.time - w.time <= timedelta(hours=2)),
               key=lambda w: w.time, default=None)
    if wake and not any(wake.time <= m.time <= g.time for m in meals):
        return "fasting", None, None
    if _is_night(g.time):
        return "night", None, None
    return "other", None, None


def _respond(e: Event, history: list[Event], all_events: list[Event], before: CareResponse,
             after: CareResponse) -> Feedback | None:
    p = after.personal
    if e.type == "glucose" and e.glucose is not None:
        return _on_glucose(e, history, before, after)
    if e.type == "meal":
        return _on_meal(e, all_events, before, after)
    if e.type in ("medication", "insulin"):
        if not e.taken:
            return Feedback(time=e.time, type=e.type, tone="caution", title="记下了：这次漏了",
                            text="没关系，记下来就好。下次按医嘱时间用药；漏用后怎么处理（要不要补）请按医生交代的方法，"
                                 "不要自己补双倍。不确定时先测血糖并咨询医生。",
                            based_on=["用药记录"])
        name = e.med_name or ("胰岛素" if e.type == "insulin" else "药")
        return Feedback(time=e.time, type=e.type, tone="good", title=f"{name}已打卡",
                        text="按时用药，珍珠鸟也很开心！", based_on=["用药记录"])
    if e.type == "exercise":
        meal = max((m for m in history if m.type == "meal" and timedelta(0) <= e.time - m.time <= timedelta(minutes=60)),
                   key=lambda m: m.time, default=None)
        if meal:
            slot = SLOT_ZH.get(meal.meal_slot or _slot_by_time(meal.time), "饭")
            f = _finding(after, f"walk_{meal.meal_slot}")
            extra = f"之前的记录里，{f.headline}。" if f else "会和没有散步的日子比较，之后告诉你有没有帮助。"
            return Feedback(time=e.time, type=e.type, tone="good", title=f"{slot}后活动了 {e.minutes or ''} 分钟".replace("  ", " "),
                            text=extra, based_on=["活动记录", f"{slot}记录"])
        return Feedback(time=e.time, type=e.type, tone="good", title="活动已记录", text="动一动对身体有好处。",
                        based_on=["活动记录"])
    if e.type == "symptom":
        sym = set(e.symptoms or [])
        if sym & HYPO_SYMPTOMS:
            recent = [g for g in history if g.type == "glucose" and g.glucose is not None
                      and timedelta(0) <= e.time - g.time <= timedelta(minutes=30)]
            if recent:
                last = max(recent, key=lambda g: g.time)
                if last.glucose < LOW:
                    return Feedback(time=e.time, type=e.type, tone="alert", title="症状和刚才的低血糖一致",
                                    text=f"刚才血糖 {last.glucose:g}（{last.time:%H:%M}）偏低，" + "、".join(sorted(sym))
                                    + "可能就是低血糖的表现。请先处理，15 分钟后复测" + (
                                        "，并用指血复核。" if last.glucose_source == "cgm" else "。"),
                                    based_on=["症状记录", "刚才的血糖"],
                                    reminders=[Reminder(at=e.time + timedelta(minutes=15), title="复测血糖", reason="低血糖症状")])
                return Feedback(time=e.time, type=e.type, tone="caution", title="症状已记录",
                                text=f"刚才血糖 {last.glucose:g}（{last.time:%H:%M}），不偏低，" + "、".join(sorted(sym))
                                + "可能有其他原因。已记下，复诊时告诉医生；如果持续或加重，请就医。",
                                based_on=["症状记录", "刚才的血糖"])
            else:
                return Feedback(time=e.time, type=e.type, tone="alert", title="现在测一次血糖",
                                text="、".join(sorted(sym)) + "可能是低血糖的表现。请现在用指血测一次；如果低于 3.9，"
                                "按医生教过的方法处理，15 分钟后复测。",
                                based_on=["症状记录"],
                                reminders=[Reminder(at=e.time + timedelta(minutes=15), title="复测血糖", reason="出现低血糖症状")])
        return Feedback(time=e.time, type=e.type, tone="info", title="症状已记录",
                        text="已记下，复诊时可以一起告诉医生。", based_on=["症状记录"])
    if e.type == "bp" and e.systolic and e.diastolic:
        if e.systolic >= 180 or e.diastolic >= 110:
            return Feedback(time=e.time, type=e.type, tone="alert", title="血压很高",
                            text=f"血压 {e.systolic}/{e.diastolic} mmHg。请休息几分钟后再量一次；如果仍然很高，"
                                 "或有胸痛、头痛剧烈、说话不清、一侧无力，请立即就医。", based_on=["血压记录"])
        m = after.metrics.home_bp_mean
        cmp = f"你最近的家庭平均是 {m[0]}/{m[1]}。" if m else ""
        return Feedback(time=e.time, type=e.type, tone="info", title=f"血压 {e.systolic}/{e.diastolic}",
                        text=cmp + "血压会和血糖一起长期追踪。", based_on=["血压记录"])
    if e.type == "weight" and e.weight_kg:
        w = after.metrics.weight_change
        text = f"和第一次记录的 {w[0]:g} kg 相比 {'减少' if e.weight_kg < w[0] else '增加'} {abs(e.weight_kg - w[0]):.1f} kg。" \
            if w and abs(e.weight_kg - w[0]) >= 0.1 else "体重会长期追踪。"
        return Feedback(time=e.time, type=e.type, tone="info", title=f"体重 {e.weight_kg:g} kg", text=text,
                        based_on=["体重记录"])
    if e.type == "lab":
        n_before = len(before.findings)
        return Feedback(time=e.time, type=e.type, tone="info", title="医院检验已加入",
                        text=f"已结合医院检验重新整理所有记录（结论 {n_before} → {len(after.findings)} 条）。",
                        based_on=["医院检验", "居家记录"])
    if e.type == "wake":
        return Feedback(time=e.time, type=e.type, tone="info", title="早安！", text="起床后、吃早餐前记得测空腹血糖。",
                        reminders=[Reminder(at=e.time + timedelta(minutes=15), title="测空腹血糖", reason="起床后、早餐前")])
    return None


def _on_glucose(g: Event, history: list[Event], before: CareResponse, after: CareResponse) -> Feedback:
    p = after.personal
    v = g.glucose
    ctx, slot, meal = _context(g, history)
    src = "（监测仪）" if g.glucose_source == "cgm" else ""
    if v < LOW:
        nights = after.metrics.night_low_nights
        lines = [f"指血复核 {v:g}，确认偏低。" if g.confirmatory else f"血糖 {v:g}{src} 低于 3.9。",
                 "请先按医生教过的方法处理（例如吃 15 g 糖），15 分钟后复测。"]
        if g.glucose_source == "cgm" and not g.confirmatory:
            lines.append("这是监测仪读数，请同时用指血复核。")
        if ctx == "night" and nights >= 2:
            lines.append(f"这是记录中第 {nights} 晚出现夜间低值。")
            f = _finding(after, "late_dinner_night_low")
            if f:
                lines.append(f"之前的记录显示：{f.headline}。已放进复诊要问医生的问题。")
        lines.append("如出现意识不清、抽搐，请家人立即拨打 120。")
        return Feedback(time=g.time, type="glucose", tone="alert", title="血糖偏低", text="".join(lines),
                        based_on=["这笔血糖", "过去的低值记录"],
                        reminders=[Reminder(at=g.time + timedelta(minutes=15), title="复测血糖", reason="血糖低于 3.9")])
    if v >= VERY_HIGH:
        return Feedback(time=g.time, type="glucose", tone="alert", title="血糖很高",
                        text=f"血糖 {v:g}{src}。如同时有口渴多尿、恶心呕吐、腹痛或呼吸深快，请尽快就医；"
                             "没有这些症状，请多喝水，按医嘱用药，稍后复测。不要自行加药。",
                        based_on=["这笔血糖"],
                        reminders=[Reminder(at=g.time + timedelta(hours=2), title="复测血糖", reason="血糖很高")])
    if ctx == "fasting":
        r = p.usual_fasting
        if r:
            inside = r[0] - 0.3 <= v <= r[1] + 0.3
            text = f"空腹 {v:g}，{'在你最近的常见范围（' if inside else '超出你最近的常见范围（'}{r[0]:g}–{r[1]:g}）{'内' if inside else ''}。"
        else:
            text = f"空腹 {v:g}。多记录几天，就能和你自己的常见范围比较。"
        return Feedback(time=g.time, type="glucose", tone="good" if LOW <= v <= 7.0 else "info", title="空腹血糖",
                        text=text + "记得早上的药。", based_on=["这笔血糖", "过去的空腹记录"])
    if ctx == "post_meal" and meal is not None:
        zh = SLOT_ZH.get(slot, "饭")
        usual = p.usual_post_meal.get(slot)
        lines = [f"{zh}后 2 小时 {v:g}{src}"]
        if usual is not None:
            diff = v - usual
            lines.append(f"，你平常{zh}后约 {usual:g}" + ("，差不多。" if abs(diff) < 1.0 else f"，这次{'高' if diff > 0 else '低'} {abs(diff):.1f}。"))
        else:
            lines.append("。")
        hc = _finding(after, f"high_carb_{slot}")
        if hc and _is_high_carb(meal, p.usual_carbs.get(slot)) and v >= (usual or HIGH):
            lines.append(f"这顿{'有甜饮料' if meal.sweet_drink else '主食偏多'}，和你过去类似{zh}的反应一致（{hc.headline}）。")
        walk = _finding(after, f"walk_{slot}")
        if walk and v > HIGH:
            lines.append(f"如果医生同意过，下次饭后可以走 15–20 分钟：{walk.headline}。")
        tone = "good" if v <= HIGH else "caution" if v < POST_MEAL_HIGH else "caution"
        return Feedback(time=g.time, type="glucose", tone=tone, title=f"{zh}后血糖", text="".join(lines),
                        based_on=["这笔血糖", f"这顿{zh}", f"过去的{zh}后记录"])
    if ctx == "night":
        return Feedback(time=g.time, type="glucose", tone="good" if v >= 5.0 else "info", title="夜间血糖",
                        text=f"夜间 {v:g}{src}，" + ("没有偏低。" if v >= 5.0 else "接近偏低，请留意身体状况，必要时再测一次。"),
                        based_on=["这笔血糖"])
    return Feedback(time=g.time, type="glucose", tone="good" if LOW <= v <= HIGH else "info", title="血糖已记录",
                    text=f"血糖 {v:g}{src}" + ("，在目标范围内。" if LOW <= v <= HIGH else "。"), based_on=["这笔血糖"])


def _on_meal(m: Event, all_events: list[Event], before: CareResponse, after: CareResponse) -> Feedback:
    p = before.personal  # 和「这一餐之前」的常态比较
    slot = m.meal_slot or _slot_by_time(m.time)
    zh = SLOT_ZH.get(slot, "餐")
    if slot == "snack":
        return Feedback(time=m.time, type="meal", tone="info", title="加餐已记录",
                        text=f"{m.food or '加餐'}" + (f"，碳水约 {m.carbs_g:g} g。" if m.carbs_g else "。"), based_on=["这次进餐"])
    lines, based, tone = [], ["这次进餐"], "info"
    if m.carbs_g is not None:
        usual = p.usual_carbs.get(slot)
        lines.append(f"碳水约 {m.carbs_g:g} g" + ("（照片估算，可修正份量）" if m.estimate == "photo" and not m.corrected_by else "")
                     + (f"，比你平常{zh}（约 {usual:g} g）多。" if usual and m.carbs_g >= usual * 1.3
                        else f"，和你平常{zh}差不多。" if usual else "。"))
        if usual:
            based.append(f"过去的{zh}")
    if m.corrected_by:
        lines.append(f"份量已由{m.corrected_by}修正（原估算 {m.original_grams:g} g → {m.grams:g} g），原始估算也会保留。"
                     if m.original_grams and m.grams else f"份量已由{m.corrected_by}修正，原始估算也会保留。")
    usual_t = p.usual_meal_time.get(slot)
    late = None
    if usual_t:
        hh, mm = map(int, usual_t.split(":"))
        late = _mins(m.time) - (hh * 60 + mm)
    reminders = [Reminder(at=m.time + timedelta(minutes=120), title=f"测{zh}后 2 小时血糖",
                          reason="和这一餐对照，才能知道你对这类饮食的反应")]
    hc = _finding(before, f"high_carb_{slot}")
    if hc and _is_high_carb(m, p.usual_carbs.get(slot)):
        lines.append(f"之前的记录：{hc.headline}。")
        tone = "caution"
    if slot == "dinner" and late is not None and late >= LATE_MIN:
        meds = [x for x in all_events if x.type in ("medication", "insulin") and x.taken and x.time.date() == m.time.date()
                and x.time.hour >= 15 and timedelta(minutes=LATE_MIN) <= m.time - x.time <= timedelta(hours=5)]
        lines.append(f"今天{zh}比平常（{usual_t}）晚约 {late} 分钟。")
        tone = "caution"
        if meds:
            lines.append("药是照平常时间吃的。")
            f = _finding(before, "late_dinner_night_low")
            w = next((w for w in before.watching if w.id == "late_dinner_night_low"), None)
            if f:
                lines.append(f"之前这样的 {f.evidence.get('exposed')} 晚里，{f.evidence.get('with_low', 0)} 晚夜里出现低血糖。")
            elif w and w.support:
                lines.append(f"之前也有 {w.support + w.against} 晚这样，其中 {w.support} 晚夜里出现低血糖。")
            lines.append("今晚睡前请测一次血糖，身边备好糖果；用药和晚餐时间怎么配合，"
                         + ("已列入复诊问题。" if f else "可以在复诊时问医生。"))
            reminders.append(Reminder(at=datetime.combine(m.time.date(), time(22, 30)), title="睡前测一次血糖",
                                      reason="今天晚吃但药照平常时间吃，夜里可能偏低"))
            based += ["今天的用药记录", "过去晚吃的夜里"]
        else:
            lines.append("如果今晚的药还没吃，用药时间怎么配合请按医生交代；不确定时请先问医生，不要自行调整。")
    if not lines:
        lines.append(f"{zh}已记录。")
    return Feedback(time=m.time, type="meal", tone=tone, title=f"{zh}已记录" + (f"：{m.food}" if m.food else ""),
                    text="".join(lines) + f"2 小时后提醒你测血糖。", based_on=based, reminders=reminders)


# ---------- 每日小结 ----------

class DailySummary(BaseModel):
    date: date
    lines: list[str]            # 今天的整理（白话）
    tonight: list[str]          # 今晚注意事项
    missing: list[str]          # 漏记的项目
    watching: list[str]         # 观察中的推测进度
    new_findings: list[str]     # 今天出现的新结论
    encouragement: str          # 珍珠鸟的一句话


def daily_summary(req: CareRequest, day: date | None = None) -> DailySummary:
    ev = req.events
    day = day or (req.now.date() if req.now else max((e.time for e in ev), default=datetime.now()).date())
    end = datetime.combine(day, time(23, 59))
    upto = [e for e in ev if e.time <= end]
    prev = [e for e in ev if e.time < datetime.combine(day, time(0))]
    after = build_profile(req.model_copy(update={"events": upto, "now": end}))
    before = build_profile(req.model_copy(update={"events": prev, "now": end - timedelta(days=1)})) if prev else None
    todays = [e for e in upto if e.time.date() == day]
    gl = [g for g in todays if g.type == "glucose" and g.glucose is not None]
    src = _glucose_source(gl) if gl else []
    lines, tonight, missing = [], [], []
    if src:
        inr = sum(LOW <= g.glucose <= HIGH for g in src)
        hi = max(src, key=lambda g: g.glucose)
        lo = min(src, key=lambda g: g.glucose)
        if src[0].glucose_source == "cgm":
            lines.append(f"监测仪今天 {round(100 * inr / len(src))}% 的时间在目标范围内，最高 {hi.glucose:g}（{hi.time:%H:%M}），"
                         f"最低 {lo.glucose:g}（{lo.time:%H:%M}）。")
        else:
            lines.append(f"今天测了 {len(src)} 次血糖，{inr} 次在目标范围内" + (f"；最高 {hi.glucose:g}（{hi.time:%H:%M}）。" if hi.glucose > HIGH else "。"))
        if lo.glucose < LOW:
            lines.append(f"今天有偏低的读数（{lo.glucose:g}，{lo.time:%H:%M}）。")
    else:
        missing.append("血糖")
    meals = [m for m in todays if m.type == "meal" and m.meal_slot != "snack"]
    slots = {m.meal_slot or _slot_by_time(m.time) for m in meals}
    for s in ("breakfast", "lunch", "dinner"):
        if s not in slots:
            missing.append(SLOT_ZH[s])
    carbs = [m.carbs_g for m in meals if m.carbs_g is not None]
    if meals:
        lines.append(f"记了 {len(meals)} 餐" + (f"，碳水共约 {round(sum(carbs))} g。" if carbs else "。"))
    t = after.today
    if t and t.meds_due:
        lines.append(f"用药 {t.meds_taken}/{t.meds_due} 次按时" + ("，很棒！" if t.meds_taken == t.meds_due else "。"))
        if t.meds_taken < t.meds_due:
            missing.append("用药打卡")
    if t and t.exercise_minutes:
        lines.append(f"活动 {t.exercise_minutes} 分钟。")
    # 今晚注意：晚吃但照常用药、晚间运动
    dinner = next((m for m in meals if (m.meal_slot or _slot_by_time(m.time)) == "dinner"), None)
    usual_t = before.personal.usual_meal_time.get("dinner") if before else None
    if dinner and usual_t:
        hh, mm = map(int, usual_t.split(":"))
        if _mins(dinner.time) - (hh * 60 + mm) >= LATE_MIN:
            tonight.append("今天晚餐比平常晚，睡前请测一次血糖，身边备好糖果。")
    if any(e.type == "exercise" and e.time.hour >= 18 and (e.minutes or 0) >= 20 for e in todays):
        tonight.append("晚上运动过，夜里血糖可能偏低，睡前可以测一次。")
    old = {f.id for f in before.findings} if before else set()
    new = [f.headline for f in after.findings if f.id not in old and f.level in ("fact", "association", "ask_doctor")]
    watching = [w.progress for w in after.watching]
    good = (t and t.meds_due and t.meds_taken == t.meds_due) or (src and all(LOW <= g.glucose <= HIGH for g in src))
    enc = "今天也认真照顾自己，珍珠鸟为你开心！" if good else "记录本身就很了不起，明天继续一起加油！"
    return DailySummary(date=day, lines=lines, tonight=tonight, missing=missing, watching=watching,
                        new_findings=new, encouragement=enc)


# ---------- 改善计划：一次一个小目标，用自己的资料比较前后 ----------

class Goal(BaseModel):
    id: str
    title: str
    why: str
    how: list[str]
    check: str                  # 怎么判断有没有帮助
    boundary: str


class GoalProgress(BaseModel):
    goal: Goal
    started: date
    days: int
    done_days: int
    before: float | None
    after: float | None
    n_before: int
    n_after: int
    verdict: Literal["资料还不够", "看起来有帮助", "暂时看不出差别", "反而偏高"]
    text: str


GOALS = {
    "dinner_carbs": Goal(id="dinner_carbs", title="晚餐主食少一点、不喝甜饮料",
                         why="主食多或有甜饮料的晚餐，饭后血糖比较高。",
                         how=["晚餐主食减少约四分之一（例如米饭少几口）", "甜饮料换成白开水或无糖茶"],
                         check="比较开始前后的晚餐后 2 小时血糖",
                         boundary="请先和医生或营养师确认适合你的份量；不要因为这个目标而改变用药。"),
    "dinner_walk": Goal(id="dinner_walk", title="晚饭后散步 15–20 分钟",
                        why="晚饭后走一走的那几天，饭后血糖比较低。",
                        how=["晚饭后 15–30 分钟内出门走一走", "身体不适或天气不好时可以在室内慢走"],
                        check="比较开始前后的晚餐后 2 小时血糖",
                        boundary="请在医生确认没有运动禁忌后进行；运动后注意夜间低血糖。"),
    "dinner_on_time": Goal(id="dinner_on_time", title="晚餐尽量准时",
                           why="晚餐比平常晚、药照平常时间吃的那几晚，夜里出现低血糖。",
                           how=["尽量在平常的时间吃晚餐", "如果知道会晚吃，先问医生用药时间怎么配合"],
                           check="记录晚餐时间与夜间血糖",
                           boundary="用药时间怎么配合请问医生；不要自行提前、延后服药或改变剂量。"),
}


def suggest_goal(p: CareResponse) -> Goal | None:
    """依目前最主要的关联，建议一个只涉及生活习惯的小目标（不涉及用药）。"""
    ids = {f.id for f in p.findings}
    for fid, goal in (("high_carb_dinner", "dinner_carbs"), ("walk_dinner", "dinner_walk"),
                      ("late_dinner_night_low", "dinner_on_time")):
        if fid in ids:
            return GOALS[goal]
    return None


def goal_progress(req: CareRequest, goal_id: str, started: date) -> GoalProgress:
    goal = GOALS[goal_id]
    ev = req.events
    meals = [m for m in ev if m.type == "meal" and (m.meal_slot or _slot_by_time(m.time)) == "dinner"]
    gl = [g for g in ev if g.type == "glucose" and g.glucose is not None]
    usual_carbs = [m.carbs_g for m in meals if m.carbs_g is not None and m.time.date() < started]
    uc = median(usual_carbs) if usual_carbs else None
    before, after, done = [], [], set()
    for m in meals:
        v = _post_meal_value(gl, m)
        later = m.time.date() >= started
        if later:
            if goal_id == "dinner_carbs" and not _is_high_carb(m, uc) and (uc is None or (m.carbs_g or uc) <= uc):
                done.add(m.time.date())
            if goal_id == "dinner_walk" and any(e.type == "exercise" and timedelta(0) <= e.time - m.time <= timedelta(minutes=60)
                                                for e in ev):
                done.add(m.time.date())
            if goal_id == "dinner_on_time":
                usual = median(_mins(x.time) for x in meals if x.time.date() < started) if any(
                    x.time.date() < started for x in meals) else 18 * 60
                if _mins(m.time) - usual < LATE_MIN:
                    done.add(m.time.date())
        if v is not None:
            (after if later else before).append(v)
    last = max((e.time.date() for e in ev), default=started)
    days = max(0, (last - started).days + 1)
    b = round(median(before), 1) if before else None
    a = round(median(after), 1) if after else None
    if len(before) < 4 or len(after) < 4:
        verdict, text = "资料还不够", f"开始后已记录 {len(after)} 次晚餐后血糖，至少需要 4 次才能比较。"
    elif a <= b - 1.0:
        verdict, text = "看起来有帮助", f"开始后晚餐后血糖中位数 {a:g}，开始前 {b:g}，低了 {b - a:.1f}。这只代表相关，饮食和其他因素也可能不同。"
    elif a >= b + 1.0:
        verdict, text = "反而偏高", f"开始后晚餐后血糖中位数 {a:g}，开始前 {b:g}。可以把记录带去问医生或营养师。"
    else:
        verdict, text = "暂时看不出差别", f"开始前后晚餐后血糖中位数分别为 {b:g} 和 {a:g}，差别不大，可以再观察一周。"
    return GoalProgress(goal=goal, started=started, days=days, done_days=len(done), before=b, after=a,
                        n_before=len(before), n_after=len(after), verdict=verdict, text=text)


# ---------- 周报与复诊摘要 ----------

class WeekCompare(BaseModel):
    label: str
    this_week: int | float | None
    last_week: int | float | None


class WeeklyReport(BaseModel):
    start: date
    end: date
    lines: list[str]
    compare: list[WeekCompare]
    findings: list[Finding]
    goal: GoalProgress | None = None


def weekly_report(req: CareRequest, end: date | None = None, goal_id: str | None = None,
                  goal_started: date | None = None) -> WeeklyReport:
    end = end or max((e.time for e in req.events), default=datetime.now()).date()
    start = end - timedelta(days=6)

    def window(a: date, b: date) -> CareResponse:
        evs = [e for e in req.events if a <= e.time.date() <= b or e.type == "lab"]
        return build_profile(req.model_copy(update={"events": evs, "now": datetime.combine(b, time(23, 59))}))
    this = window(start, end)
    last = window(start - timedelta(days=7), start - timedelta(days=1))

    def pm(p: CareResponse, s: str):
        return p.metrics.post_meal.get(s, {}).get("median")
    compare = [WeekCompare(label="目标范围内（%）", this_week=int(round(this.metrics.tir * 100)) if this.metrics.tir is not None else None,
                           last_week=int(round(last.metrics.tir * 100)) if last.metrics.tir is not None else None),
               WeekCompare(label="晚餐后 2 小时中位数", this_week=pm(this, "dinner"), last_week=pm(last, "dinner")),
               WeekCompare(label="空腹中位数", this_week=this.metrics.fasting_median, last_week=last.metrics.fasting_median),
               WeekCompare(label="低血糖次数", this_week=this.metrics.low_episodes, last_week=last.metrics.low_episodes)]
    lines = []
    t, l = compare[0].this_week, compare[0].last_week
    if t is not None and l is not None:
        lines.append(f"本周血糖在目标范围内约 {t}%，" + ("比上周多。" if t > l + 2 else "比上周少。" if t < l - 2 else "和上周差不多。"))
    if this.metrics.low_episodes:
        lines.append(f"本周有 {this.metrics.low_episodes} 次低血糖，请留意并带去复诊。")
    full = build_profile(req.model_copy(update={"events": [e for e in req.events if e.time.date() <= end]}))
    goal = goal_progress(req, goal_id, goal_started) if goal_id and goal_started else None
    return WeeklyReport(start=start, end=end, lines=lines, compare=compare,
                        findings=[f for f in full.findings if f.level != "unknown"], goal=goal)


class VisitSummary(BaseModel):
    start: date
    end: date
    lab: dict[str, float] | None
    lab_date: date | None
    overview: list[str]          # 血糖概况（数字）
    post_meal: dict[str, float]
    facts: list[str]
    associations: list[str]
    questions: list[str]
    cannot_judge: list[str]
    note: str = "照片估算的份量仅供参考；本摘要不构成诊断或用药建议，请由医生解读。"


def visit_summary(req: CareRequest, days: int = 14) -> VisitSummary:
    end = max((e.time for e in req.events if e.type != "lab"), default=datetime.now()).date()
    start = end - timedelta(days=days - 1)
    evs = [e for e in req.events if start <= e.time.date() <= end or e.type == "lab"]
    p = build_profile(req.model_copy(update={"events": evs}))
    m = p.metrics
    overview = []
    if m.tir is not None:
        overview.append(("监测仪" if m.source == "cgm" else "指血") + f"：范围内 {round(m.tir * 100)}%、偏高 {round(m.tar * 100)}%、"
                        f"偏低 {round(m.tbr * 100)}%" + (f"（覆盖率 {round(m.coverage * 100)}%）" if m.coverage else ""))
    if m.gmi is not None:
        overview.append(f"监测估算 GMI {m.gmi:g}%")
    if m.fasting_median is not None:
        overview.append(f"空腹中位数 {m.fasting_median:g}")
    if m.home_bp_mean:
        overview.append(f"家庭血压平均 {m.home_bp_mean[0]}/{m.home_bp_mean[1]}")
    if m.weight_change:
        overview.append(f"体重 {m.weight_change[0]:g} → {m.weight_change[1]:g} kg")

    def txt(f: Finding) -> str:
        return f"{f.headline}：{f.detail}" if f.detail else f.headline
    return VisitSummary(start=start, end=end, lab=p.background.lab, lab_date=p.background.lab_date, overview=overview,
                        post_meal={s: v["median"] for s, v in m.post_meal.items()},
                        facts=[txt(f) for f in p.findings if f.level == "fact"],
                        associations=[txt(f) for f in p.findings if f.level == "association"],
                        questions=p.doctor_questions,
                        cannot_judge=[f.headline for f in p.findings if f.level == "unknown"]
                        + [b for f in p.findings if f.level == "association" and "不能证明" in f.detail
                           for b in [f"{f.title}：不能证明是唯一原因"]])


# ---------- API 请求 ----------

class DailyRequest(CareRequest):
    day: date | None = None


class GoalRequest(CareRequest):
    goal_id: Literal["dinner_carbs", "dinner_walk", "dinner_on_time"] | None = None
    started: date | None = None


class GoalResponse(BaseModel):
    suggested: Goal | None
    progress: GoalProgress | None


class WeeklyRequest(GoalRequest):
    end: date | None = None


class VisitRequest(CareRequest):
    days: int = Field(default=14, ge=3, le=90)


def goal(req: GoalRequest) -> GoalResponse:
    base = CareRequest(**req.model_dump(include=set(CareRequest.model_fields)))
    prog = goal_progress(base, req.goal_id, req.started) if req.goal_id and req.started else None
    return GoalResponse(suggested=suggest_goal(build_profile(base)), progress=prog)
