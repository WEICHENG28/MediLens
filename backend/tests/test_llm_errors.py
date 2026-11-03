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


def _reply(monkeypatch, content):
    monkeypatch.setattr(httpx, 'post', lambda *a, **kw: httpx.Response(
        200, json={'choices': [{'message': {'content': content}}]}, request=httpx.Request('POST', 'https://synthetic.test')))


@pytest.mark.parametrize('content, expected', [
    ('<think>用户问的是 medication 吗？不是，应为 none。数值 9.9</think>\nnone', 'none'),
    ('<THINK>多行\n思考</THINK>尿酮体反映脂肪分解。', '尿酮体反映脂肪分解。'),
    ('前面的推理过程 emergency</think>none', 'none'),
    ('普通回答，没有思考标签。', '普通回答，没有思考标签。'),
])
def test_thinking_is_removed_from_answer(monkeypatch, content, expected):
    _reply(monkeypatch, content)
    assert provider().complete('synthetic', 'synthetic') == expected


@pytest.mark.parametrize('content', ['<think>只有思考，输出被截断', '<think>想完了</think>   '])
def test_thinking_without_answer_counts_as_failure(monkeypatch, content):
    _reply(monkeypatch, content)
    with pytest.raises(LLMError):
        provider().complete('synthetic', 'synthetic')
