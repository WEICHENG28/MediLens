"""Provider errors remain structured and never expose headers or response bodies."""
import httpx
import pytest
from app.llm import LLMError, OpenAICompatProvider


def provider():
    return OpenAICompatProvider('compat', 'https://synthetic.test', 'synthetic-model', 'synthetic-secret')


def test_timeout_has_private_safe_reason(monkeypatch):
    def fail(*args, **kwargs):
        raise httpx.ReadTimeout('synthetic-secret private-request')
    monkeypatch.setattr(httpx, 'post', fail)
    with pytest.raises(LLMError) as e:
        provider().complete('synthetic', 'synthetic')
    assert e.value.reason == 'timeout'
    assert 'synthetic-secret' not in str(e.value)


@pytest.mark.parametrize('data', [[], {'choices': None}, {'choices': [{'message': {'content': None}}]}, {'choices': [{'message': {'content': '   '}}]}])
def test_invalid_provider_payload_is_controlled(monkeypatch, data):
    monkeypatch.setattr(httpx, 'post', lambda *a, **kw: httpx.Response(200, json=data, request=httpx.Request('POST', 'https://synthetic.test')))
    with pytest.raises(LLMError) as e:
        provider().complete('synthetic', 'synthetic')
    assert e.value.reason == 'upstream_error'


def test_http_error_is_private_safe(monkeypatch):
    monkeypatch.setattr(httpx, 'post', lambda *a, **kw: httpx.Response(429, text='synthetic-secret', request=httpx.Request('POST', 'https://synthetic.test')))
    with pytest.raises(LLMError) as e:
        provider().complete('synthetic', 'synthetic')
    assert e.value.reason == 'upstream_error'
    assert 'synthetic-secret' not in str(e.value)
