"""规则与选择题测试（合成数据；规则为未经医学审核的测试规则）。"""
from app.analysis import analyze
from app.schemas import Level

from .helpers import item, normal_urinalysis, req


def hit_ids(resp):
    return [h.rule_id for h in resp.hits]


def test_normal_report_no_uacr_history_hits_r06_green():
    r = analyze(req(normal_urinalysis()))
    assert r.supported and hit_ids(r) == ["R-06"]
    assert r.overall.level == Level.green
    assert not r.urgent_alert.show
    assert r.is_test_rules and "未经医学审核" in r.badge


def test_r01_red_urgent_and_top():
    items = normal_urinalysis(GLU=item("葡萄糖", "2+", ref="阴性"), KET=item("酮体", "1+", ref="阴性"))
    r = analyze(req(items))
    assert r.hits[0].rule_id == "R-01" and r.hits[0].level == Level.red
    assert r.urgent_alert.show and "120" in r.urgent_alert.message
    assert r.overall.level == Level.red


def test_r01_not_evaluable_when_ket_unknown():
    items = normal_urinalysis(GLU=item("葡萄糖", "2+", ref="阴性"), KET=item("酮体", "1+", ref="阴性", status="unknown"))
    r = analyze(req(items))
    assert "R-01" not in hit_ids(r)
    ne = {n.rule_id: n for n in r.not_evaluable}
    assert "R-01" in ne and "不代表正常" in ne["R-01"].note
    # 未知不自动变绿
    assert r.overall.level != Level.green


def test_r02_requires_answer_and_unknown_is_not_no():
    items = normal_urinalysis(GLU=item("葡萄糖", "3+", ref="阴性"))
    r = analyze(req(items))
    assert r.next_question.question_id == "q_sglt2"
    assert "R-02" in {n.rule_id for n in r.not_evaluable}
    r2 = analyze(req(items, answers={"q_sglt2": "__unknown__"}))
    assert "R-02" not in hit_ids(r2) and "R-02" in {n.rule_id for n in r2.not_evaluable}
    r3 = analyze(req(items, answers={"q_sglt2": "yes_known"}))
    assert "R-02" in hit_ids(r3)
    r4 = analyze(req(items, answers={"q_sglt2": "no"}))
    assert "R-02" not in hit_ids(r4) and "R-02" not in {n.rule_id for n in r4.not_evaluable}


def test_glucose_positive_without_rule_is_not_green():
    items = normal_urinalysis(GLU=item("葡萄糖", "3+", ref="阴性"))
    r = analyze(req(items, answers={"q_sglt2": "no"}))
    # 尿糖异常但无规则覆盖 → 无法据此判断，不是绿色
    assert "尿葡萄糖" in r.uncovered_abnormal
    assert r.overall.level == Level.unknown


def test_r03_uacr_with_infection():
    items = normal_urinalysis(LEU=item("白细胞", "2+", ref="阴性"))
    items.append(item("尿微量白蛋白/肌酐", "85", unit="mg/g", ref="<30"))
    r = analyze(req(items, answers={"q_uacr_before": "first"}))
    assert "R-03" in hit_ids(r) and "R-04" in hit_ids(r)
    assert r.overall.level == Level.yellow


def test_r04_first_elevation_from_history():
    cur = [item("UACR", "60", unit="mg/g", ref="<30")]
    hist_low = [{"test_date": "2026-03-01", "items": [item("UACR", "12", unit="mg/g", ref="<30")]}]
    hist_high = [{"test_date": "2026-03-01", "items": [item("UACR", "45", unit="mg/g", ref="<30")]}]
    assert "R-04" in hit_ids(analyze(req(cur, history=hist_low)))
    assert "R-04" not in hit_ids(analyze(req(cur, history=hist_high)))
    # 有历史时不再询问 q_uacr_before
    nq = analyze(req(cur, history=hist_low)).next_question
    assert nq is None or nq.question_id != "q_uacr_before"


def test_r04_upper_bound():
    r = analyze(req([item("UACR", "350", unit="mg/g", ref="<30")], answers={"q_uacr_before": "first"}))
    assert "R-04" not in hit_ids(r)
    assert "尿白蛋白/肌酐比" in r.uncovered_abnormal and r.overall.level == Level.unknown


def test_r05_grade_rise_needs_history_and_silent_without():
    items = normal_urinalysis(PRO=item("尿蛋白", "2+", ref="阴性"))
    r = analyze(req(items))
    assert "R-05" not in hit_ids(r) and "R-05" not in {n.rule_id for n in r.not_evaluable}
    hist = [{"test_date": "2026-01-01", "items": [item("尿蛋白", "±", ref="阴性")]}]
    assert "R-05" in hit_ids(analyze(req(items, history=hist)))


def test_r06_suppressed_by_recent_uacr_history():
    hist = [{"test_date": "2026-05-01", "items": [item("UACR", "10", unit="mg/g", ref="<30")]}]
    assert "R-06" not in hit_ids(analyze(req(normal_urinalysis(), history=hist)))
    old = [{"test_date": "2024-05-01", "items": [item("UACR", "10", unit="mg/g", ref="<30")]}]
    assert "R-06" in hit_ids(analyze(req(normal_urinalysis(), history=old)))


def test_unsupported_report():
    r = analyze(req([item("谷丙转氨酶", "35", unit="U/L", ref="0-40"), item("肌酐", "80", unit="μmol/L")]))
    assert not r.supported and "不支持" in r.unsupported_message or "只支持" in r.unsupported_message
    assert r.hits == []


def test_followup_sequence_skip_and_back():
    items = normal_urinalysis(GLU=item("葡萄糖", "2+", ref="阴性"), KET=item("酮体", "1+", ref="阴性"))
    seen = []
    answers = {}
    for _ in range(10):
        q = analyze(req(items, answers=answers)).next_question
        if q is None:
            break
        seen.append(q.question_id)
        answers[q.question_id] = "__skip__"
    assert seen[:3] == ["q_sglt2", "q_ketone_symptoms", "q_ketone_diet"]
    assert "q_doctor_order" in seen
    # 回退：删除一个答案后该题重新出现
    del answers["q_ketone_diet"]
    assert analyze(req(items, answers=answers)).next_question.question_id == "q_ketone_diet"


def test_urgent_symptom_answer_escalates_to_red():
    items = normal_urinalysis(KET=item("酮体", "1+", ref="阴性"))
    r = analyze(req(items, answers={"q_ketone_symptoms": ["nausea_vomit"]}))
    assert r.urgent_alert.show and r.overall.level == Level.red
    assert any("恶心" in x for x in r.urgent_alert.reasons)


def test_uacr_rules_not_listed_when_report_has_no_uacr():
    r = analyze(req(normal_urinalysis(PRO=item("尿蛋白", "2+", ref="阴性"))))
    ids = {n.rule_id for n in r.not_evaluable}
    assert "R-03" not in ids and "R-04" not in ids


def test_uacr_rules_listed_when_uacr_present_but_unconfirmed():
    r = analyze(req([item("UACR", "86", unit="mg/g", ref="<30", status="unknown")]))
    assert {"R-03", "R-04"} <= {n.rule_id for n in r.not_evaluable}
