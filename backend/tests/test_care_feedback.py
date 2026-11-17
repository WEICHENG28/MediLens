"""即时回馈、每日小结、改善计划、周报与复诊摘要：用陈女士合成资料逐笔重播核对。"""
from datetime import date, datetime, timedelta

from fastapi.testclient import TestClient

from app.care import CareRequest, build_profile
from app.care_feedback import (GOALS, RecordRequest, daily_summary, goal_progress, on_record, suggest_goal,
                               visit_summary, weekly_report)
from app.care_sim import chen_case, scenario
from app.lifestyle import Event
from app.main import app

C = chen_case()
EV = C["events"]
SCHED = C["schedule"]
LATE1, LATE2 = date(2026, 11, 7), date(2026, 11, 12)  # 晚吃但照常用药的两天


def replay(pred):
    """逐笔重播：只用这笔之前的记录作为历史。"""
    out = []
    for k, e in enumerate(EV):
        if pred(e):
            out.append((e, on_record(RecordRequest(events=EV[:k], new=[e], schedule=SCHED))))
    return out


def one(pred):
    res = replay(pred)
    assert len(res) == 1, len(res)
    return res[0][1]


def text_of(r):
    return "".join(f.title + f.text for f in r.feedback)


def test_late_dinner_with_usual_med_time_asks_bedtime_check():
    r = one(lambda e: e.time.date() == LATE2 and e.type == "meal" and e.meal_slot == "dinner")
    fb = r.feedback[0]
    assert fb.tone == "caution" and "晚约 60 分钟" in fb.text and "药是照平常时间吃的" in fb.text
    assert "之前也有 1 晚这样，其中 1 晚夜里出现低血糖" in fb.text
    assert {x.title for x in r.reminders} >= {"测晚餐后 2 小时血糖", "睡前测一次血糖"}
    for w in ("提前吃药", "延后吃药", "少吃药", "减量", "加量"):
        assert w not in fb.text


def test_first_late_dinner_does_not_claim_question_already_listed():
    fb = one(lambda e: e.time.date() == LATE1 and e.type == "meal" and e.meal_slot == "dinner").feedback[0]
    assert "可以在复诊时问医生" in fb.text and "已列入复诊问题" not in fb.text


def test_second_night_low_links_pattern_and_promotes_it():
    r = one(lambda e: e.confirmatory and e.time.date() == LATE2 + timedelta(days=1))
    fb = r.feedback[0]
    assert fb.tone == "alert" and "指血复核 3.7，确认偏低" in fb.text and "第 2 晚" in fb.text
    assert any(x.title == "复测血糖" and x.at == fb.time + timedelta(minutes=15) for x in fb.reminders)
    # 第一笔监测仪低值时，「晚吃 × 夜间低值」从观察中升级为关联
    first_low = one(lambda e: e.glucose_source == "cgm" and e.time == datetime(2026, 11, 13, 0, 0))
    assert any(c.kind == "promoted" and c.id == "late_dinner_night_low" for c in first_low.changes)
    assert "指血复核" in text_of(first_low)


def test_symptoms_are_read_against_recent_glucose():
    low = one(lambda e: e.type == "symptom" and e.time.date() == LATE2 + timedelta(days=1) and "心悸" in e.symptoms)
    assert low.feedback[0].tone == "alert" and "一致" in low.feedback[0].title
    dizzy = one(lambda e: e.type == "symptom" and e.symptoms == ["头晕"] and e.time.date() == date(2026, 11, 13))
    assert dizzy.feedback[0].tone == "caution" and "不偏低" in dizzy.feedback[0].text
    # 没有近期血糖：请现在测
    alone = on_record(RecordRequest(events=[], new=[Event(type="symptom", time=datetime(2026, 11, 20, 3), symptoms=["出汗"])]))
    assert alone.feedback[0].tone == "alert" and "现在测一次" in alone.feedback[0].title


def test_post_meal_reading_compared_with_personal_and_meal():
    r = one(lambda e: e.glucose_source == "cgm" and e.time == datetime(2026, 11, 13, 20, 15))
    t = r.feedback[0].text
    assert "晚餐后 2 小时" in t and "你平常晚餐后约" in t and "和你过去类似晚餐的反应一致" in t


def test_fasting_reading_uses_personal_range():
    r = one(lambda e: e.glucose_source == "cgm" and e.time == datetime(2026, 11, 13, 5, 45))
    assert r.feedback[0].title == "空腹血糖" and "常见范围" in r.feedback[0].text


def test_cgm_bulk_sync_is_summarised_not_spammed():
    d = LATE2 + timedelta(days=1)
    day = [e for e in EV if e.time.date() == d and e.glucose_source == "cgm"]
    r = on_record(RecordRequest(events=[e for e in EV if e.time.date() < d], new=day, schedule=SCHED))
    assert r.feedback[0].title.startswith(f"已同步 {len(day)} 笔") and r.feedback[0].tone == "alert"
    assert sum(f.title == "血糖偏低" for f in r.feedback) == 1   # 一段低值只提示一次
    assert len(r.feedback) <= 4


def test_missed_med_and_photo_correction():
    miss = on_record(RecordRequest(events=EV, new=scenario("missed_med", datetime(2026, 11, 17, 7, 0)), schedule=SCHED))
    assert all("不要自己补双倍" in f.text for f in miss.feedback)
    corr = one(lambda e: e.corrected_by is not None)
    assert "200 g → 280 g" in corr.feedback[0].text and "原始估算也会保留" in corr.feedback[0].text


def test_new_events_also_in_history_are_not_double_counted():
    e = EV[-1]
    a = on_record(RecordRequest(events=EV[:-1], new=[e], schedule=SCHED))
    b = on_record(RecordRequest(events=EV, new=[e], schedule=SCHED))
    assert a.model_dump() == b.model_dump()


def test_daily_summary():
    req = CareRequest(events=EV, schedule=SCHED)
    s = daily_summary(req, LATE2)
    assert any("晚餐比平常晚" in t for t in s.tonight) and not s.missing
    assert any("2/2" in line for line in s.lines)
    after_low = daily_summary(req, LATE2 + timedelta(days=1))
    assert any("偏低" in line for line in after_low.lines)
    assert any("夜间低血糖" in t or "晚餐比平常晚" in t for t in after_low.new_findings)
    empty = daily_summary(CareRequest(events=[]), date(2026, 11, 20))
    assert "血糖" in empty.missing and "晚餐" in empty.missing


def test_goal_suggestion_is_lifestyle_only_and_progress_honest():
    g = suggest_goal(build_profile(CareRequest(events=EV, schedule=SCHED)))
    assert g.id == "dinner_carbs" and "不要因为这个目标而改变用药" in g.boundary
    for goal in GOALS.values():
        assert "医生" in goal.boundary
    req = CareRequest(events=EV, schedule=SCHED)
    short = goal_progress(req, "dinner_walk", date(2026, 11, 15))
    assert short.verdict == "资料还不够"
    mid = goal_progress(req, "dinner_walk", date(2026, 11, 10))
    assert mid.n_before >= 4 and mid.n_after >= 4 and mid.verdict in ("看起来有帮助", "暂时看不出差别", "反而偏高")


def test_weekly_and_visit_summary():
    req = CareRequest(events=EV, schedule=SCHED)
    w = weekly_report(req)
    assert w.end == date(2026, 11, 16) and isinstance(w.compare[0].this_week, int)
    v = visit_summary(req)
    assert v.lab["hba1c"] == 7.3 and v.post_meal == {"breakfast": 9.0, "lunch": 9.7, "dinner": 12.1}
    assert any("夜间低血糖" in f for f in v.facts) and any("晚餐延迟" in q for q in v.questions)
    assert v.cannot_judge and "不构成诊断或用药建议" in v.note


def test_endpoints():
    c = TestClient(app)
    demo = c.post("/api/v1/care/demo", json={"state": "chen14", "today": "2026-11-16"}).json()
    body = {"events": demo["events"], "schedule": demo["schedule"]}
    new = c.post("/api/v1/care/scenario", json={"name": "late_high_carb_dinner", "at": "2026-11-17T19:15:00"}).json()["events"]
    r = c.post("/api/v1/care/record", json={**body, "new": new})
    assert r.status_code == 200 and any("睡前" in x["title"] for x in r.json()["reminders"])
    assert c.post("/api/v1/care/daily", json={**body, "day": "2026-11-12"}).status_code == 200
    g = c.post("/api/v1/care/goal", json={**body, "goal_id": "dinner_walk", "started": "2026-11-10"}).json()
    assert g["suggested"]["id"] == "dinner_carbs" and g["progress"]["n_after"] >= 4
    assert c.post("/api/v1/care/weekly", json=body).status_code == 200
    v = c.post("/api/v1/care/visit", json={**body, "days": 14}).json()
    assert v["questions"]
