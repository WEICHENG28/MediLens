"""生活照护问答：安全分类、按问题挑选依据、「昨晚」、输出校验与回退（测试使用离线 mock）。"""
from datetime import date

from fastapi.testclient import TestClient

from app import care_chat as cc
from app.care_chat import CareChatRequest, care_chat
from app.care_sim import chen_case
from app.llm import LLMError
from app.main import app

C = chen_case()


def ask(q, events=None):
    return care_chat(CareChatRequest(events=C["events"] if events is None else events, schedule=C["schedule"], message=q))


def test_safety_categories():
    assert ask("我可以把晚上的药晚一点吃吗").safety_category == "medication"
    assert ask("晚吃饭的话药要不要也晚点吃").safety_category == "medication"
    assert ask("我可以停药吗").safety_category == "medication"
    assert ask("我现在心慌出冷汗").safety_category == "emergency"
    assert ask("我是不是得了肾病").safety_category == "diagnosis"
    assert ask("我可以把晚上的藥晚一點吃嗎").safety_category == "medication"  # 繁体也拦截
    med = ask("药可以晚点吃吗").answer
    assert "医生决定" in med and "晚餐延迟时，用药和进餐时间应该怎么配合" in med


def test_selects_relevant_findings():
    assert set(ask("我昨晚为什么会偏低？").based_on) >= {"night_low", "late_dinner_night_low"}
    assert "high_carb_dinner" in ask("晚餐要注意什么？").based_on
    assert ask("饭后散步有用吗").based_on == ["walk_dinner"]
    assert "blood_pressure" in ask("我的血压怎么样").based_on


def test_last_night_is_answered_from_records():
    a = ask("我昨晚为什么会偏低？").answer
    assert "昨晚（11月15日夜里）" in a and "没有偏低" in a
    a13 = ask("昨晚怎么样", [e for e in C["events"] if e.time.date() <= date(2026, 11, 13)]).answer
    assert "低于 3.9" in a13 and "出汗" in a13


def test_doctor_questions_and_today():
    a = ask("复诊要问医生什么")
    assert "1." in a.answer and "晚餐延迟" in a.answer
    t = ask("今天怎么样").answer
    assert "今天记了" in t and "用药 2/2" in t


def test_no_records_and_unrelated_question():
    assert "记录还不多" in ask("我最近怎么样", []).answer
    a = ask("天气好吗")
    assert "还没有可以依据的整理" in a.answer and a.safety_category is None


def test_llm_output_is_guarded_and_falls_back(monkeypatch):
    class Bad:
        name = "compat"

        def complete(self, system, user):
            return "你应该减量服药，这是低血糖导致的，血糖 2.1 很危险。"
    monkeypatch.setattr(cc, "get_provider", lambda: Bad())
    monkeypatch.setattr(cc, "llm_classify", lambda *a, **k: None)
    r = ask("晚餐要注意什么？")
    assert r.used_fallback and "减量" not in r.answer and "导致" not in r.answer

    class Down:
        name = "compat"

        def complete(self, system, user):
            raise LLMError("timeout", reason="timeout")
    monkeypatch.setattr(cc, "get_provider", lambda: Down())
    assert ask("晚餐要注意什么？").used_fallback


def test_llm_intent_can_catch_medication(monkeypatch):
    class Ok:
        name = "compat"

        def complete(self, system, user):
            return "晚餐后的血糖最高。"
    monkeypatch.setattr(cc, "get_provider", lambda: Ok())
    monkeypatch.setattr(cc, "llm_classify", lambda *a, **k: "medication")
    assert ask("晚上那一颗我想换个时间").safety_category == "medication"


def test_endpoint():
    r = TestClient(app).post("/api/v1/care/chat", json={
        "events": [e.model_dump(mode="json") for e in C["events"]], "schedule": [s.model_dump() for s in C["schedule"]],
        "message": "晚餐要注意什么？"})
    assert r.status_code == 200 and "high_carb_dinner" in r.json()["based_on"]
