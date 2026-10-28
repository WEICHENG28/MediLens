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


@pytest.mark.parametrize("msg,cat", [
    ("我能停藥嗎", "medication"),
    ("藥我不想吃了", "medication"),
    ("胰島素要不要減量", "medication"),
    ("我是不是腎衰竭了", "diagnosis"),
    ("嘔吐了一整晚", "emergency"),
])
def test_traditional_chinese_is_intercepted(msg, cat):
    """繁体输入（如台湾注音输入法）同样要触发安全拦截。"""
    r = chat(creq(msg))
    assert r.safety_category == cat


def test_traditional_normal_question_not_blocked():
    r = chat(creq("尿酮體是什麼", focus="KET"))
    assert r.safety_category is None and "酮体" in r.answer


def test_compat_provider_from_env(monkeypatch):
    """学校等 OpenAI 兼容聚合平台：设置地址、密钥、模型后启用；缺地址时降级 mock。"""
    from app.llm import OpenAICompatProvider
    monkeypatch.setenv("LLM_PROVIDER", "compat")
    monkeypatch.setenv("COMPAT_API_KEY", "test-key")
    monkeypatch.delenv("COMPAT_BASE_URL", raising=False)
    assert isinstance(get_provider(), MockProvider)
    monkeypatch.setenv("COMPAT_BASE_URL", "https://llm.example.edu.cn/v1")
    monkeypatch.setenv("COMPAT_MODEL", "Qwen3.8-Flash")
    p = get_provider()
    assert isinstance(p, OpenAICompatProvider) and p.model == "Qwen3.8-Flash" and p.base_url.endswith("/v1")

class _FakeIntent:
    def __init__(self, label):
        self.label = label
        self.calls = 0

    def complete(self, system, user):
        self.calls += 1
        return self.label


def test_intent_layers_keyword_first_then_llm(monkeypatch):
    """两层越界判断：关键词命中不调用大模型；未命中时由大模型语义判断。"""
    fake = _FakeIntent("medication")
    monkeypatch.setattr(chat_mod, "get_intent_provider", lambda: fake)
    res = chat_mod.analyze(ketone_case())
    assert chat_mod.classify_intent("我能停药吗", res) == ("medication", "keyword") and fake.calls == 0
    assert chat_mod.classify_intent("胰岛素晚上打几个单位", res) == ("medication", "llm") and fake.calls == 1
    fake.label = "none"
    assert chat_mod.classify_intent("酮体是什么", res) == (None, "none")


def test_intent_llm_answer_uses_safety_template(monkeypatch):
    monkeypatch.setattr(chat_mod, "get_intent_provider", lambda: _FakeIntent("diagnosis"))
    r = chat(creq("我这算几期了"))
    assert r.safety_category == "diagnosis" and r.provider == "safety-template"


def test_intent_llm_failure_falls_through(monkeypatch):
    class Down:
        def complete(self, s, u):
            raise LLMError("timeout")
    monkeypatch.setattr(chat_mod, "get_intent_provider", lambda: Down())
    r = chat(creq("这个指标是什么", focus="KET"))
    assert r.safety_category is None and "酮体" in r.answer

def test_overall_question_uses_overview():
    r = chat(creq("这份报告整体怎么样？"))
    assert not r.no_evidence and "总体判断" in r.answer and "尿糖和尿酮体同时阳性" in r.answer


def test_unrelated_question_still_no_evidence():
    assert chat(creq("今天天气怎么样")).no_evidence


def test_item_named_in_question_without_focus():
    r = chat(creq("我的白细胞正常吗"))
    assert "您的白细胞" in r.answer and r.citations
    r = chat(creq("尿糖和尿酮同时阳性要注意什么？"))
    assert "酮症" in r.answer and r.citations[0].id == "kb-ket-102"


def test_danger_signs_generalized():
    # 酮体阳性时，呼吸深快、口中水果味、言语不清、昏厥、胸闷、冷汗等按危险征象处理
    for q in ["呼吸好急促怎么办", "嘴里有股水果味", "他说话不清楚", "孩子他爸昏过去了", "胸口很闷", "心慌出冷汗"]:
        assert chat(creq(q)).safety_category == "emergency", q


def test_severity_question_uses_overview():
    # 「我这个病严重吗」（含繁体与错字）这类问整体情况的问题，用总览回答而不是「无资料」
    for q in ["我這個並嚴重嗎", "我这个病严重吗", "要紧吗", "我的情况怎么样"]:
        r = chat(creq(q))
        assert not r.no_evidence and "总体判断" in r.answer, q


def test_quick_buttons_without_focus():
    # 从总览直接进入提问页（未选定指标）时，三个快捷按钮都要有实际回答
    r = chat(creq("这个指标是什么"))
    assert not r.no_evidence and "本次需要关注的指标" in r.answer and r.citations
    r = chat(creq("哪些指标有关", quick="related"))
    assert "需要一起看的指标" in r.answer and "尿糖与尿酮体同时阳性" in r.answer
    r = chat(creq("复诊问什么", quick="doctor"))
    assert "复诊时可以问医生" in r.answer and not r.used_fallback
