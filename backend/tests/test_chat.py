"""对话、详细了解、输出校验与待实现接口测试（合成数据）。"""
import pytest
from fastapi.testclient import TestClient

from app import chat as chat_mod
from app import guard
from app.chat import ChatRequest, ExplainRequest, chat, explain
from app.llm import LLMError, MockProvider, get_provider
from app.main import app

from .helpers import item, normal_urinalysis, req

client = TestClient(app)


@pytest.fixture(autouse=True)
def _mock_llm(monkeypatch):
    monkeypatch.setenv("LLM_PROVIDER", "mock")


def ketone_case():
    return req(normal_urinalysis(GLU=item("葡萄糖", "2+", ref="阴性"), KET=item("酮体", "1+", ref="阴性")))


def creq(message, analysis=None, **kw):
    return ChatRequest(analysis=analysis or ketone_case(), message=message, **kw)


def test_provider_defaults_to_mock_without_key(monkeypatch):
    monkeypatch.setenv("LLM_PROVIDER", "deepseek")
    monkeypatch.delenv("DEEPSEEK_API_KEY", raising=False)
    assert isinstance(get_provider(), MockProvider)


@pytest.mark.parametrize("msg", ["我能停药吗", "这个药可以减量吗", "要不要换药", "格列净还要不要吃，能不能停"])
def test_medication_questions_use_safety_template(msg):
    r = chat(creq(msg))
    assert r.safety_category == "medication" and "医生决定" in r.answer and r.provider == "safety-template"


@pytest.mark.parametrize("msg", ["我是不是肾衰竭了", "这能确诊糖尿病肾病吗"])
def test_diagnosis_questions(msg):
    r = chat(creq(msg))
    assert r.safety_category == "diagnosis" and "不能判断" in r.answer


def test_emergency_symptom_message():
    r = chat(creq("我现在一直吐，呼吸很快"))
    assert r.safety_category == "emergency" and "120" in r.answer


def test_focus_item_what_is_with_citation():
    r = chat(creq("这个指标是什么", focus="KET"))
    assert "酮体" in r.answer and r.citations and r.citations[0].id == "kb-test-ket-001"
    assert "非指南原文" in r.citations[0].source


def test_quick_doctor_questions():
    r = chat(creq("复诊问什么", focus="R-01", quick="doctor"))
    assert "复诊时可以问医生" in r.answer and "血酮" in r.answer


def test_no_evidence_says_so():
    r = chat(creq("今天天气怎么样"))
    assert r.no_evidence and "无法据此回答" in r.answer


class _BadProvider:
    name = "bad"

    def __init__(self, text):
        self.text = text

    def complete(self, system, user):
        return self.text


class _FailProvider:
    name = "down"

    def complete(self, system, user):
        raise LLMError("timeout")


@pytest.mark.parametrize("bad", [
    "您可以先停药观察。", "您已经确诊糖尿病肾病。", "您的酮体是 3+，数值 88 很高。",
])
def test_guard_rejects_and_falls_back(monkeypatch, bad):
    monkeypatch.setattr(chat_mod, "get_provider", lambda: _BadProvider(bad))
    r = chat(creq("这个指标是什么", focus="KET"))
    assert r.used_fallback and r.answer != bad


def test_guard_blocks_unsupported_urgent_claim(monkeypatch):
    monkeypatch.setattr(chat_mod, "get_provider", lambda: _BadProvider("尿蛋白阴性，请立即就医。"))
    r = chat(creq("尿蛋白是什么", analysis=req(normal_urinalysis()), focus="PRO"))
    assert r.used_fallback


def test_llm_failure_falls_back(monkeypatch):
    monkeypatch.setattr(chat_mod, "get_provider", lambda: _FailProvider())
    r = chat(creq("这个指标是什么", focus="KET"))
    assert r.used_fallback and "酮体" in r.answer


def test_guard_allows_consistent_text():
    assert guard.check("您的尿酮体为 1+，需要医生评估。", '{"raw":"1+"}', urgent_allowed=False).ok


def test_explain_rule_and_item():
    e = explain(ExplainRequest(analysis=ketone_case(), target="R-01"))
    assert e.title.startswith("尿糖") and e.sections and e.citations and e.doctor_questions
    e2 = explain(ExplainRequest(analysis=ketone_case(), target="PRO"))
    assert "尿蛋白" in e2.short and e2.sections[0].heading == "这个指标是什么"


def test_explain_unit_conversion_section():
    a = req([item("UACR", "5.0", unit="mg/mmol", ref="<3.4")])
    e = explain(ExplainRequest(analysis=a, target="UACR"))
    assert any(s.heading == "单位换算" for s in e.sections)


def test_chat_api_and_pending_endpoints():
    body = {"analysis": {"report": {"items": normal_urinalysis()}}, "message": "尿蛋白是什么", "focus": "PRO"}
    r = client.post("/api/v1/chat", json=body)
    assert r.status_code == 200 and r.json()["provider"] == "mock"
    for path in ["/api/v1/voice/session", "/api/v1/medication/recognize", "/api/v1/ocr/cloud",
                 "/api/v1/auth/register", "/api/v1/backup/upload"]:
        resp = client.post(path)
        assert resp.status_code == 501 and "待实现" in resp.json()["message"]
    assert "interrupted" in client.get("/api/v1/voice/states").json()["states"]
