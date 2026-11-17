"""陈女士 14 天合成资料：核对生成结果与老师建议文件的数值相符，以及新记录格式的相容性。"""
from datetime import date, datetime, timedelta
from statistics import median

from fastapi.testclient import TestClient

from app.care_sim import (CONFIRM, DAYS, HIGH_CARB, LATE, SCENARIOS, WALK, chen_case, day_slice, describe, dump,
                          scenario, start_state)
from app.lifestyle import Event, LifestyleRequest, analyze_lifestyle
from app.main import app

CGM = chen_case()
FINGER = chen_case(cgm=False)


def _dinner_2h(case):
    by_t = {e.time: e.glucose for e in case["events"] if e.type == "glucose" and e.glucose_source == "cgm"}
    return {m.time.date(): by_t[m.time + timedelta(minutes=120)]
            for m in case["events"] if m.type == "meal" and m.meal_slot == "dinner"}


def test_matches_teacher_case_numbers():
    s = describe(CGM["events"])
    assert s["post_meal_median"] == {"breakfast": 9.0, "lunch": 9.7, "dinner": 12.1}
    assert s["coverage"] == 0.92
    assert abs(s["tir"] - 0.58) <= 0.03 and abs(s["tar"] - 0.39) <= 0.03 and 0.015 <= s["tbr"] <= 0.035
    assert s["meals"] == 42 and s["steps_mean"] == 3800 and s["home_bp_mean"] == [138, 78]
    assert abs(s["sleep_hours_mean"] - 5.83) <= 0.1 and s["weight_first_last"] == [66.8, 66.5]
    assert 3.0 <= min(e.glucose for e in CGM["events"] if e.type == "glucose") and \
        max(e.glucose for e in CGM["events"] if e.type == "glucose") <= 16.5  # 曲线在合理范围


def test_dinner_groups_match_document():
    d2h = list(_dinner_2h(CGM).values())
    start = date.fromisoformat(CGM["truth"]["start"])
    by_day = {(k - start).days: v for k, v in _dinner_2h(CGM).items()}
    high = [by_day[i] for i in HIGH_CARB]
    other = [by_day[i] for i in range(DAYS) if i not in HIGH_CARB]
    assert sum(v >= 12.0 for v in high) == 5 and len(high) == 6       # 6 次高碳水晚餐中 5 次 ≥12
    assert sum(v >= 12.0 for v in other) == 2 and len(other) == 8     # 其余 8 次中 2 次
    assert median([by_day[i] for i in WALK]) == 10.2                  # 饭后步行
    assert median([by_day[i] for i in range(DAYS) if i not in WALK]) == 12.4  # 久坐
    assert len(d2h) == 14


def test_night_lows_follow_late_dinners_with_usual_med_time():
    ev = CGM["events"]
    start = date.fromisoformat(CGM["truth"]["start"])
    confirms = [e for e in ev if e.confirmatory]
    assert sorted(e.glucose for e in confirms) == sorted(CONFIRM.values())
    for i, late in LATE.items():
        d = start + timedelta(days=i)
        dinner = next(e for e in ev if e.type == "meal" and e.meal_slot == "dinner" and e.time.date() == d)
        assert 60 <= (dinner.time - datetime.combine(d, datetime.min.time()).replace(hour=18)).total_seconds() / 60 <= 80
        evening_meds = [e for e in ev if e.type == "medication" and e.time.date() == d and e.time.hour >= 17]
        assert evening_meds and all(abs(e.time.hour * 60 + e.time.minute - 18 * 60) <= 10 for e in evening_meds)
        night = [e.glucose for e in ev if e.glucose_source == "cgm" and d + timedelta(days=1) == e.time.date() and e.time.hour < 4]
        assert min(night) < 3.9
        assert any(e.type == "symptom" and "心悸" in e.symptoms and e.time.date() == d + timedelta(days=1) for e in ev)
    # 其他夜里没有低值
    low_days = {e.time.date() for e in ev if e.glucose_source == "cgm" and e.glucose < 3.9}
    assert low_days == {start + timedelta(days=i + 1) for i in LATE}


def test_photo_estimate_correction_is_kept():
    m = next(e for e in CGM["events"] if e.corrected_by)
    assert (m.original_grams, m.grams, m.corrected_by) == (200.0, 280.0, "家属")
    assert m.original_carbs_g < m.carbs_g and m.corrected_at > m.time and m.estimate == "photo"


def test_finger_only_version():
    gl = [e for e in FINGER["events"] if e.type == "glucose"]
    assert all(e.glucose_source == "finger" for e in gl)
    assert 50 <= len(gl) <= 75                       # 每天约 4–5 笔
    assert describe(FINGER["events"])["post_meal_median"]["dinner"] == 12.1
    assert sorted(e.glucose for e in gl if e.confirmatory) == sorted(CONFIRM.values())


def test_everything_is_marked_synthetic_and_reproducible():
    assert CGM["truth"]["synthetic"] and "虚构" in CGM["profile"]["name"]
    assert dump(chen_case()["events"]) == dump(CGM["events"])


def test_old_app_records_still_work_and_new_fields_parse():
    old = [{"type": "meal", "time": "2026-11-03T18:00:00", "meal_size": "normal"},
           {"type": "glucose", "time": "2026-11-03T20:00:00", "glucose": 9.1},
           {"type": "medication", "time": "2026-11-03T18:00:00", "taken": True}]
    r = analyze_lifestyle(LifestyleRequest(events=[Event(**e) for e in old]))
    assert r.metrics.readings == 1
    # 导出再读回，资料不变
    back = [Event(**e) for e in dump(CGM["events"])]
    assert back == CGM["events"]


def test_full_case_runs_through_existing_analysis():
    for case in (CGM, FINGER):
        r = analyze_lifestyle(LifestyleRequest(events=case["events"], schedule=case["schedule"]))
        assert r.metrics.adherence == 1.0
        assert r.pet.health_state == "健康"  # 医院检验早于居家记录，不会被当成漏药的日子


def test_start_states_and_day_slices():
    end = date(2026, 11, 30)
    assert start_state("new", end) == []
    day3 = start_state("day3", end)
    full = start_state("chen14", end)
    assert max(e.time for e in full).date() <= end + timedelta(days=1)
    first = end - timedelta(days=DAYS - 1)
    assert {e.time.date() for e in day3 if e.type != "lab"} == {first + timedelta(days=i) for i in range(3)}
    assert day_slice(full, first + timedelta(days=4)) and all(
        e.time.date() == first + timedelta(days=4) for e in day_slice(full, first + timedelta(days=4)))


def test_scenarios():
    at = datetime(2026, 11, 17, 19, 10)
    for name in SCENARIOS:
        ev = scenario(name, at)
        assert ev and all(isinstance(e, Event) for e in ev)
    late = scenario("late_high_carb_dinner", at)
    meal = next(e for e in late if e.type == "meal")
    med = next(e for e in late if e.type == "medication")
    assert meal.sweet_drink and (meal.time - med.time) == timedelta(minutes=70)
    low = scenario("night_low", at)
    assert any(e.confirmatory for e in low) and any(e.type == "symptom" for e in low)


def test_demo_endpoints():
    c = TestClient(app)
    r = c.post("/api/v1/care/demo", json={"state": "chen14", "today": "2026-11-30"})
    assert r.status_code == 200 and r.json()["synthetic"] and len(r.json()["events"]) > 1000
    assert c.post("/api/v1/care/demo", json={"state": "day3", "cgm": False}).status_code == 200
    assert c.post("/api/v1/care/demo", json={"state": "x"}).status_code == 422
    assert "night_low" in c.get("/api/v1/care/scenarios").json()
    r = c.post("/api/v1/care/scenario", json={"name": "night_low", "at": "2026-11-17T03:00:00"})
    assert r.status_code == 200 and len(r.json()["events"]) == 3
    assert c.post("/api/v1/care/scenario", json={"name": "x", "at": "2026-11-17T03:00:00"}).status_code == 422
    # 示范资料可直接送回分析
    ev = c.post("/api/v1/care/demo", json={"state": "chen14"}).json()["events"]
    assert c.post("/api/v1/lifestyle", json={"events": ev}).status_code == 200
