"""照护核心：用陈女士合成资料核对三条新规律、证据累积、三级结论、综合判断与安全边界。"""
import random
from datetime import date, datetime, timedelta

from fastapi.testclient import TestClient

from app.care import CareRequest, build_profile, care_alerts
from app.care_sim import chen_case, scenario, start_state
from app.lifestyle import Event
from app.main import app

CGM = chen_case()
FINGER = chen_case(cgm=False)


def profile(case_or_events, **kw):
    if isinstance(case_or_events, dict):
        return build_profile(CareRequest(events=case_or_events["events"], schedule=case_or_events["schedule"], **kw))
    return build_profile(CareRequest(events=case_or_events, **kw))


def ids(r):
    return {f.id for f in r.findings}


def by_id(r, i):
    return next(f for f in r.findings if f.id == i)


R_CGM = profile(CGM)
R_FINGER = profile(FINGER)


def test_teacher_case_findings_with_cgm():
    r = R_CGM
    assert {"night_low", "hba1c_high_with_lows", "post_meal_highest", "high_carb_dinner",
            "late_dinner_night_low", "walk_dinner", "blood_pressure", "photo_estimate"} <= ids(r)
    assert by_id(r, "post_meal_highest").evidence["slot"] == "dinner"
    assert r.metrics.post_meal["dinner"] == {"median": 12.1, "n": 14, "high_count": 7}
    assert r.metrics.night_low_nights == 2 and r.metrics.coverage == 0.92 and r.metrics.gmi is not None
    hc = by_id(r, "high_carb_dinner").evidence
    assert (hc["high"], hc["other"]) == (6, 8)
    late = by_id(r, "late_dinner_night_low").evidence
    assert (late["exposed"], late["with_low"], late["other_with_low"]) == (2, 2, 0)
    assert by_id(r, "walk_dinner").evidence["diet_differs"]  # 散步那几天吃得也不同：不能证明因果


def test_levels_and_order():
    r = R_CGM
    assert r.findings[0].urgent and r.findings[0].id in ("night_low", "hba1c_high_with_lows")
    assert all(f.level in ("fact", "association", "ask_doctor", "unknown") for f in r.findings)
    assert by_id(r, "post_meal_highest").level == "fact"
    assert by_id(r, "late_dinner_night_low").level == "association"
    assert by_id(r, "late_dinner_night_low").confidence == "初步"
    assert by_id(r, "hba1c_high_with_lows").level == "ask_doctor"
    assert by_id(r, "photo_estimate").level == "unknown"
    assert any("晚餐延迟" in q for q in r.doctor_questions) and len(r.doctor_questions) <= 5


def test_finger_only_version_is_honest_about_missing_night_data():
    r = R_FINGER
    assert {"night_low", "late_dinner_night_low", "high_carb_dinner", "post_meal_highest"} <= ids(r)
    assert "3.8" in by_id(r, "night_low").detail and "3.7" in by_id(r, "night_low").detail
    assert "无法比较" in by_id(r, "late_dinner_night_low").detail
    assert r.metrics.gmi is None and r.metrics.coverage is None and "只作参考" in by_id(r, "time_in_range").detail


def test_few_days_only_watching_not_concluding():
    r = profile(start_state("day3", date(2026, 11, 16)), schedule=CGM["schedule"])
    assert not [f for f in r.findings if f.level == "association"]
    assert "post_meal_highest" not in ids(r)
    assert r.watching and all(w.support < w.needed or w.needed for w in r.watching)


def test_empty_and_lab_only():
    r = profile([])
    assert r.findings == [] and r.today is None and r.metrics.source == "none"
    lab = profile(scenario("new_lab", datetime(2026, 11, 1, 9)))
    assert "lab_only" in ids(lab) and lab.background.lab["hba1c"] == 7.3


def _flat_case(seed=3):
    """没有任何规律的对照：三餐碳水与餐后血糖都随机，没有低值、没有散步效果。"""
    rng = random.Random(seed)
    ev = []
    for i in range(14):
        d = date(2026, 10, 1) + timedelta(days=i)
        wake = datetime.combine(d, datetime.min.time()) + timedelta(hours=6, minutes=30)
        ev += [Event(type="wake", time=wake),
               Event(type="glucose", time=wake + timedelta(minutes=10), glucose=round(rng.gauss(7.0, 0.4), 1), glucose_source="finger")]
        for slot, h in (("breakfast", 7), ("lunch", 12), ("dinner", 18)):
            mt = datetime.combine(d, datetime.min.time()) + timedelta(hours=h, minutes=rng.choice([-20, 0, 20]))
            ev.append(Event(type="meal", time=mt, meal_slot=slot, carbs_g=float(rng.choice([55, 60, 65, 90])),
                            sweet_drink=rng.random() < 0.15, estimate="photo"))
            ev.append(Event(type="glucose", time=mt + timedelta(minutes=120), glucose=round(rng.gauss(9.0, 0.7), 1),
                            glucose_source="finger"))
            ev.append(Event(type="medication", time=mt - timedelta(minutes=10), med_name="二甲双胍"))
            if rng.random() < 0.3:
                ev.append(Event(type="exercise", time=mt + timedelta(minutes=20), minutes=20))
    return ev


def test_no_false_associations_without_patterns():
    for seed in range(5):
        r = profile(_flat_case(seed))
        assert not [f.id for f in r.findings if f.level == "association"], seed
        assert "night_low" not in ids(r) and "hba1c_high_with_lows" not in ids(r)
        assert "no_night_data" in ids(r) and "no_lab" in ids(r)


def test_false_association_rate_on_patternless_cases():
    """200 位没有规律的合成对照：出现任何一条假关联的人不超过 3%。"""
    hit = sum(1 for s in range(200) if any(f.level == "association" for f in profile(_flat_case(s)).findings))
    assert hit <= 6, hit


def test_wording_never_gives_dosing_advice():
    banned = ("增加剂量", "减少剂量", "加量吃", "减量吃", "停药吧", "多吃一片", "少吃一片", "改成每天", "单位胰岛素", "导致")
    for r in (R_CGM, R_FINGER):
        text = "".join(f.headline + f.detail + (f.question or "") for f in r.findings) + r.disclaimer
        for w in banned:
            assert w not in text, w
        for f in r.findings:  # 涉及用药的结论都要附上「不能自行调药」的边界
            if f.id in ("night_low", "late_dinner_night_low", "hba1c_high_with_lows", "high_carb_dinner"):
                assert f.boundary and ("自行" in f.boundary or "不要" in f.boundary)
    assert "不代表原因" in R_CGM.disclaimer and "不是用药建议" in R_CGM.disclaimer


def test_old_records_without_meal_slot_are_inferred_without_mutation():
    ev = [Event(type="meal", time=datetime(2026, 11, 1, 18, 0), meal_size="large")]
    profile(ev)
    assert ev[0].meal_slot is None  # 不改动传入的记录


def test_deterministic():
    assert profile(CGM).model_dump() == R_CGM.model_dump()


def test_alerts_ask_for_finger_confirmation_on_cgm_low():
    now = datetime(2026, 11, 17, 3, 0)
    a = care_alerts([Event(type="glucose", time=now, glucose=3.5, glucose_source="cgm")], [], now)
    assert a[0].level == "red" and "指血复核" in a[0].text
    f = care_alerts([Event(type="glucose", time=now, glucose=3.5, glucose_source="finger")], [], now)
    assert "指血复核" not in f[0].text
    assert care_alerts([Event(type="glucose", time=now, glucose=18.0)], [], now)[0].level == "yellow"


def test_today_and_personal():
    r = R_CGM
    assert r.personal.usual_meal_time["dinner"] == "18:00" and r.personal.usual_post_meal["dinner"] == 12.1
    assert r.today.meals == ["早餐", "午餐", "晚餐"] and r.today.meds_taken == r.today.meds_due == 2


def test_profile_endpoint():
    c = TestClient(app)
    ev = c.post("/api/v1/care/demo", json={"state": "chen14", "today": "2026-11-30"}).json()
    r = c.post("/api/v1/care/profile", json={"events": ev["events"], "schedule": ev["schedule"]})
    assert r.status_code == 200
    assert "late_dinner_night_low" in {f["id"] for f in r.json()["findings"]}
