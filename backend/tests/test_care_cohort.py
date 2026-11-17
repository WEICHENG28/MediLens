"""评测用合成病人群：可复现、分层只保留对应资料、放入的情境确实存在；监测仪假低值不当作低血糖。"""
from datetime import datetime

from app.care import CareRequest, build_profile
from app.care_cohort import LAYERS, cohort, layer, make_patient
from app.lifestyle import Event


def test_reproducible_and_marked():
    a, b = make_patient(11, ("late_med_low",), True), make_patient(11, ("late_med_low",), True)
    assert [e.model_dump() for e in a.events] == [e.model_dump() for e in b.events]
    assert a.truth["low_nights"] and set(a.truth["low_nights"]) <= set(a.truth["late_nights"])


def test_layers_keep_only_their_data():
    p = make_patient(3, ("dinner_high", "walk_helps"), False)
    assert {e.type for e in layer(p.events, "A")} == {"lab"}
    assert {e.type for e in layer(p.events, "B")} <= {"lab", "glucose", "symptom"}
    assert "meal" in {e.type for e in layer(p.events, "C")} and "exercise" not in {e.type for e in layer(p.events, "C")}
    assert len(layer(p.events, "D")) == len(p.events)
    assert set(LAYERS) == {"A", "B", "C", "D"}


def test_cohort_mix():
    c = cohort(18, seed=5)
    assert sum(not p.scenarios for p in c) == 4 and sum(p.cgm for p in c) == 9
    assert len({p.pid for p in c}) == 18


def test_planted_patterns_found_without_noise():
    p = make_patient(21, ("dinner_high", "late_med_low", "walk_helps"), False, noise=0)
    ids = {f.id for f in build_profile(CareRequest(events=p.events, schedule=p.schedule)).findings}
    assert {"late_dinner_night_low", "night_low"} <= ids
    a = {f.id for f in build_profile(CareRequest(events=layer(p.events, "A"), schedule=p.schedule)).findings}
    assert "lab_only" in a and "night_low" not in a


def test_cgm_low_refuted_by_finger_is_not_a_hypo():
    t = datetime(2026, 9, 2, 2, 30)
    ev = [Event(type="glucose", time=t, glucose=3.5, glucose_source="cgm"),
          Event(type="glucose", time=t.replace(minute=40), glucose=5.7, glucose_source="finger", confirmatory=True)]
    ev += [Event(type="glucose", time=t.replace(hour=h, minute=0), glucose=7.0, glucose_source="cgm") for h in range(3, 24)]
    r = build_profile(CareRequest(events=ev))
    ids = {f.id for f in r.findings}
    assert "night_low" not in ids and "cgm_low_not_confirmed" in ids
    assert r.metrics.low_episodes == 0 and r.metrics.night_low_nights == 0
    assert r.low_episodes[0].confirmed is False  # 原始事件仍保留，供查看
