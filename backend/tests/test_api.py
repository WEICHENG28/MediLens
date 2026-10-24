from fastapi.testclient import TestClient

from app.main import app

from .helpers import item, normal_urinalysis

client = TestClient(app)


def test_health():
    assert client.get("/api/v1/health").json()["status"] == "ok"


def test_analyze_endpoint():
    body = {"report": {"test_date": "2026-10-01", "items": normal_urinalysis(PRO=item("尿蛋白", "1+", ref="阴性"))}}
    r = client.post("/api/v1/analyze", json=body)
    assert r.status_code == 200
    data = r.json()
    assert data["is_test_rules"] is True and data["badge"] == "测试规则，未经医学审核"
    assert "不能替代医生" in data["disclaimer"]


def test_invalid_answers_rejected():
    body = {"report": {"items": normal_urinalysis()}, "answers": {"q_ketone_symptoms": ["none", "nausea_vomit"]}}
    assert client.post("/api/v1/analyze", json=body).status_code == 422
    body["answers"] = {"q_sglt2": ["yes_known", "no"]}
    assert client.post("/api/v1/analyze", json=body).status_code == 422
    body["answers"] = {"q_unknown": "x"}
    assert client.post("/api/v1/analyze", json=body).status_code == 422


def test_answer_validate_endpoint():
    assert client.post("/api/v1/followup/validate", json={"question_id": "q_sglt2", "answer": "__decline__"}).json()["ok"]
