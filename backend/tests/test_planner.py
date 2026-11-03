"""受控工具调用：参数只能取自本次报告；工具结果由程序生成；安全判断仍优先。"""
import pytest

from app import chat as chat_mod
from app.analysis import analyze
from app.chat import ChatRequest, chat
from app.llm import LLMError
from app.planner import Plan, execute, parse_plan
from tests.helpers import item, normal_urinalysis, req


def ketone_req(history=None):
    return req(normal_urinalysis(GLU=item("葡萄糖", "2+", ref="阴性"), KET=item("酮体", "1+", ref="阴性")), history=history)


def test_parse_plan_only_accepts_listed_tools_and_report_codes():
    res = analyze(ketone_req())
    p = parse_plan('<think>x</think>{"tools": [{"name": "item", "args": ["glu"]}, {"name": "item", "args": ["UACR"]},'
                   '{"name": "hack", "args": []}, {"name": "rule", "args": ["R-99"]}, {"name": "relation", "args": ["GLU"]},'
                   '{"name": "item", "args": ["GLU"]}, {"name": "overall"}]}', res)
    assert p.tools == [("item", ("GLU",)), ("overall", ())]
    assert parse_plan("我觉得应该查尿糖", res) is None
    assert parse_plan('{"tools": []}', res) is None


def test_trend_tool_compares_with_history_without_interpreting():
    hist = [{"test_date": "2026-06-01", "items": [item("葡萄糖", "1+", ref="阴性")]}]
    r = ketone_req(history=hist)
    text, _ = execute(Plan([("trend", ("GLU",))]), r, analyze(r), "尿糖比上次怎么样")
    assert "2026-06-01" in text and "比上次高" in text and "需要医生判断" in text
    text, _ = execute(Plan([("trend", ("GLU",))]), ketone_req(), analyze(ketone_req()), "尿糖比上次怎么样")
    assert "没有" in text and "以往记录" in text


def test_drug_relation_and_prep_tools_use_knowledge_and_rules():
    r = ketone_req()
    res = analyze(r)
    text, cites = execute(Plan([("drug", ("GLU",))]), r, res, "尿糖和我吃的达格列净有关吗")
    assert "SGLT2" in text and cites
    text, _ = execute(Plan([("relation", ("GLU", "KET"))]), r, res, "尿糖和尿酮有什么关系")
    assert "酮" in text and "同时阳性" in text
    text, cites = execute(Plan([("prep", ())]), r, res, "复查前要注意什么")
    assert cites and ("留尿" in text or "运动" in text)


class Spy:
    """检索规划、意图分类、回答生成共用的假模型。"""
    name = "compat"

    def __init__(self, plan='{"tools": []}', intent="none", fail_plan=False):
        self.plan, self.intent, self.fail_plan, self.answers = plan, intent, fail_plan, []

    def complete(self, system, user):
        if "检索规划器" in system:
            if self.fail_plan:
                raise LLMError("down")
            return self.plan
        if "安全分类器" in system:
            return self.intent
        self.answers.append(user)
        return "尿糖阳性可能和您吃的降糖药有关，具体请问医生。" if "SGLT2" in user else "这是按规则整理的说明。"


def _use(monkeypatch, spy):
    monkeypatch.setattr(chat_mod, "get_provider", lambda: spy)
    monkeypatch.setattr(chat_mod, "get_intent_provider", lambda: spy)


def test_planner_adds_evidence_the_regex_route_missed(monkeypatch):
    spy = Spy(plan='{"tools": [{"name": "drug", "args": ["GLU"]}]}')
    _use(monkeypatch, spy)
    r = chat(ChatRequest(analysis=ketone_req(), message="尿糖和我吃的达格列净有关吗"))
    assert r.tools == ["drug(GLU)"] and any("SGLT2" in c.title for c in r.citations)
    assert "尽快就医" in r.answer  # 紧急报告的就医提示仍会补上


def test_planner_same_as_regex_route_keeps_original_answer(monkeypatch):
    _use(monkeypatch, Spy(plan='{"tools": [{"name": "item", "args": ["KET"]}]}'))
    r = chat(ChatRequest(analysis=ketone_req(), message="尿酮体是什么意思"))
    assert r.tools == [] and not r.used_fallback


@pytest.mark.parametrize("spy", [Spy(plan="看不懂的输出"), Spy(fail_plan=True)])
def test_planner_failure_falls_back_to_rule_route(monkeypatch, spy):
    _use(monkeypatch, spy)
    r = chat(ChatRequest(analysis=ketone_req(), message="尿酮体是什么意思"))
    assert r.tools == [] and r.answer and "酮" in r.answer + "".join(spy.answers)


def test_safety_intent_wins_over_plan(monkeypatch):
    _use(monkeypatch, Spy(plan='{"tools": [{"name": "drug", "args": ["GLU"]}]}', intent="medication"))
    r = chat(ChatRequest(analysis=ketone_req(), message="达格列净还要继续用下去吗医生没说"))
    assert r.safety_category == "medication" and r.tools == []


def test_planner_answers_question_regex_could_not(monkeypatch):
    _use(monkeypatch, Spy(plan='{"tools": [{"name": "overall"}]}'))
    r = chat(ChatRequest(analysis=ketone_req(), message="帮我看看哪里不太好"))
    assert not r.no_evidence and r.tools == ["overall"]


def test_drug_tool_only_uses_entries_for_that_item():
    r = ketone_req()
    text, cites = execute(Plan([("drug", ("KET",))]), r, analyze(r), "尿酮体和我吃的达格列净有关吗")
    assert not cites and "没有" in text and "酮体" in text


def test_plan_only_used_when_it_adds_new_material():
    from app.planner import adds_new_material
    res = analyze(ketone_req())
    covered = {("item", ("KET",)), ("rule", ("R-01",))}
    assert not adds_new_material(Plan([("item", ("GLU",)), ("rule", ("R-01",))]), covered, res)  # R-01 已涵盖尿糖
    assert not adds_new_material(Plan([("item", ("KET",))]), covered, res)
    assert adds_new_material(Plan([("trend", ("KET",))]), covered, res)
    assert adds_new_material(Plan([("item", ("PRO",))]), covered, res)
    assert adds_new_material(Plan([("overall", ())]), covered, res)
