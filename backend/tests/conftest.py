"""测试一律使用 mock 大模型：不读取真实密钥、不联网，结果可重复。"""
import pytest


@pytest.fixture(autouse=True)
def _offline_llm(monkeypatch):
    monkeypatch.setenv("LLM_PROVIDER", "mock")