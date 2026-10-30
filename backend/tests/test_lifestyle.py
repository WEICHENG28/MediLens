from datetime import date, datetime, timedelta

from fastapi.testclient import TestClient

from app.lifestyle import Event, LifestyleRequest, ScheduleItem, analyze_lifestyle, choose_slot, _by_type
from app.lifestyle_sim import NO_EFFECTS, SCHEDULE, simulate
from app.main import app


def run(events, **kw):
    return analyze_lifestyle(LifestyleRequest(events=events, schedule=kw.pop("schedule", SCHEDULE), **kw))


def test_planted_effects_are_found():
    ids = {i.id for i in run(simulate(14, seed=1)).insights}
    assert {"insulin_timing", "post_meal_walk"} <= ids


def test_no_false_patterns_without_effects():
    for seed in range(5):
        assert run(simulate(14, seed=seed, effects=NO_EFFECTS)).insights == []


def test_insight_wording_is_correlation_not_dosing_advice():
    r = run(simulate(14, seed=1))
    text = r.disclaimer + "".join(i.finding + i.doctor_question for i in r.insights)
    assert "相关" in r.disclaimer and "不是用药建议" in r.disclaimer
    for word in ("加量", "减量", "多打", "少打", "单位"):
        assert word not in text


def _day(d, insulin_taken=(True, True, True)):
    ev = []
    for (hh, mm), taken in zip(((7, 30), (11, 45), (17, 45)), insulin_taken):
        ev.append(Event(type="insulin", time=datetime(2026, 10, d, hh, mm), insulin_kind="rapid", taken=taken))
    ev.append(Event(type="glucose", time=datetime(2026, 10, d, 21, 0), glucose=7.0))
    return ev


def test_pet_gets_sick_after_missed_doses_and_recovers():
    ev = _day(1) + _day(2, (False, False, True)) + _day(3, (False, True, True))
    p = run(ev, today=date(2026, 10, 3)).pet
    assert p.health_state == "生病了" and p.mood == "担心" and "生病" in p.message
    assert p.health >= 20  # 不会「死亡」
    assert p.safety_note and "不要自己补打双倍" in p.safety_note
    recovered = run(ev + _day(4) + _day(5) + _day(6), today=date(2026, 10, 6)).pet
    assert recovered.health > p.health and recovered.health_state != "生病了"


def test_negative_feedback_can_be_turned_off():
    ev = _day(1, (False, False, False))
    p = run(ev, today=date(2026, 10, 1), negative_feedback=False).pet
    assert p.health == 100 and p.mood != "担心"


def test_pet_never_reflects_glucose_values():
    # 同样按时用药，血糖高低不同，宠物健康值相同
    hi = [e if e.type != "glucose" else Event(type="glucose", time=e.time, glucose=15.0) for e in _day(1) + _day(2)]
    lo = _day(1) + _day(2)
    assert run(hi, today=date(2026, 10, 2)).pet.health == run(lo, today=date(2026, 10, 2)).pet.health


def test_low_glucose_alert():
    t = datetime(2026, 10, 1, 9, 0)
    r = run([Event(type="glucose", time=t, glucose=3.2)], schedule=[])
    assert r.alerts and r.alerts[0].level == "red" and "15 分钟后复测" in r.alerts[0].text


def test_thompson_prefers_slot_that_works():
    ev = []
    t0 = datetime(2026, 10, 1, 12, 0)
    for k in range(20):
        t = t0 + timedelta(days=k)
        ev.append(Event(type="reminder", time=t, task="饭后散步", slot="饭后 15 分钟"))
        ev.append(Event(type="exercise", time=t + timedelta(minutes=20), minutes=20))
        ev.append(Event(type="reminder", time=t + timedelta(hours=5), task="饭后散步", slot="饭后马上"))
    import random
    choice = choose_slot("饭后散步", _by_type(ev), random.Random(0))
    assert choice["slot"] == "饭后 15 分钟" and choice["posterior_mean"]["饭后 15 分钟"] > 0.9


def test_api_endpoint(monkeypatch):
    monkeypatch.delenv("API_TOKEN", raising=False)
    body = LifestyleRequest(events=simulate(7, seed=2), schedule=SCHEDULE).model_dump(mode="json")
    r = TestClient(app).post("/api/v1/lifestyle", json=body)
    assert r.status_code == 200 and "pet" in r.json() and r.json()["reminders"]


def test_demo_endpoint(monkeypatch):
    monkeypatch.delenv("API_TOKEN", raising=False)
    r = TestClient(app).post("/api/v1/lifestyle/demo", json={"days": 14, "today": "2026-10-29"})
    d = r.json()
    assert r.status_code == 200 and d["synthetic"] and d["schedule"]
    assert max(e["time"] for e in d["events"]).startswith("2026-10-30") or max(e["time"] for e in d["events"]).startswith("2026-10-29")


def test_report_followup_tasks_link_to_pet_and_reminders():
    from app.lifestyle import Task
    ev = _day(1) + _day(2)
    tasks = [Task(id="R-04|2026-10-01", title="3–6 个月内复查 UACR（具体以医生安排为准）", due=date(2026, 10, 2))]
    r = run(ev, today=date(2026, 10, 2), tasks=tasks)
    assert "复查事项到期" in r.pet.message and any(x.task == "复查事项" and "UACR" in x.reason for x in r.reminders)
    done = run(ev, today=date(2026, 10, 2), tasks=[tasks[0].model_copy(update={"done": True})])
    assert "到期" not in done.pet.message and not any(x.task == "复查事项" for x in done.reminders)
    # 未到期的任务只出现在提醒里，不影响宠物
    later = run(ev, today=date(2026, 10, 2), tasks=[tasks[0].model_copy(update={"due": date(2026, 12, 30)})])
    assert "到期" not in later.pet.message and any(x.task == "复查事项" for x in later.reminders)


def test_rules_carry_followup_tasks_but_urgent_rule_has_none():
    import yaml
    from app.rules_engine import RULES_PATH

    rules = {r["id"]: r for r in yaml.safe_load(RULES_PATH.read_text(encoding="utf-8"))["rules"]}
    assert rules["R-01"].get("urgent") and "followup_task" not in rules["R-01"]  # 紧急事项不进宠物任务
    assert rules["R-04"]["followup_task"]["days"] == 90 and "UACR" in rules["R-04"]["followup_task"]["title"]
    assert all(r["followup_task"]["title"] for r in rules.values() if "followup_task" in r)
