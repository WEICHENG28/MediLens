"""大模型 provider adapter。

业务代码只依赖 `LLMProvider.complete()`；厂商可通过环境变量切换，密钥只在后端 .env。
仅接入中国大陆可直接访问的服务（均为 OpenAI 兼容协议，用 httpx 直连，不使用 openai SDK、不访问 OpenAI）：
- DeepSeek：https://api.deepseek.com/chat/completions（官方文档 api-docs.deepseek.com，2026-10 查阅）
- 通义千问（阿里云百炼）：https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/compatible-mode/v1（help.aliyun.com，2026-10 查阅）
- 智谱：https://open.bigmodel.cn/api/paas/v4（docs.bigmodel.cn，2026-10 查阅）
未配置密钥时使用 mock，保证全流程可跑通。
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Protocol

import httpx

PROVIDERS = {
    "deepseek": {"base_url": "https://api.deepseek.com", "model": "deepseek-flash", "key_env": "DEEPSEEK_API_KEY"},
    "qwen": {"base_url": "", "model": "qwen-plus", "key_env": "DASHSCOPE_API_KEY"},  # base_url 必须按工作空间配置
    "zhipu": {"base_url": "https://open.bigmodel.cn/api/paas/v4", "model": "glm-5.3-flash", "key_env": "ZHIPU_API_KEY"},
    # 通用 OpenAI 兼容平台（如学校提供的多模型聚合平台）：接口地址、密钥、模型名均在 .env 配置
    "compat": {"base_url": "", "model": "DeepSeek-V4.1-Flash", "key_env": "COMPAT_API_KEY"},
}


class LLMError(Exception):
    pass


class LLMProvider(Protocol):
    name: str

    def complete(self, system: str, user: str) -> str: ...


class MockProvider:
    """离线 mock：直接返回调用方预先组装好的、基于规则与知识的草稿文本。"""

    name = "mock"

    def complete(self, system: str, user: str) -> str:
        marker = "【草稿】"
        if marker in user:
            return user.split(marker, 1)[1].strip()
        return "目前无法生成解释，请查看上方已确认的指标说明，或在复诊时咨询医生。"


@dataclass
class OpenAICompatProvider:
    name: str
    base_url: str
    model: str
    api_key: str
    timeout: float = 20.0

    def complete(self, system: str, user: str) -> str:
        url = self.base_url.rstrip("/") + "/chat/completions"
        payload = {
            "model": self.model,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
            "temperature": 0.2,
        }
        try:
            r = httpx.post(url, json=payload, headers={"Authorization": f"Bearer {self.api_key}"}, timeout=self.timeout)
            r.raise_for_status()
            return r.json()["choices"][0]["message"]["content"]
        except (httpx.HTTPError, KeyError, IndexError, ValueError) as e:
            # 日志脱敏：不记录请求内容与密钥
            raise LLMError(f"{self.name} 调用失败：{type(e).__name__}") from e


def get_provider() -> LLMProvider:
    name = os.environ.get("LLM_PROVIDER", "mock").lower()
    if name == "mock" or name not in PROVIDERS:
        return MockProvider()
    cfg = PROVIDERS[name]
    key = os.environ.get(cfg["key_env"], "")
    base = os.environ.get(f"{name.upper()}_BASE_URL", cfg["base_url"])
    model = os.environ.get(f"{name.upper()}_MODEL", cfg["model"])
    if not key or not base or not base.lower().startswith(("http://", "https://")):
        return MockProvider()  # 缺密钥/地址或地址格式错误时降级为 mock，并在响应中标明 provider
    return OpenAICompatProvider(name=name, base_url=base, model=model, api_key=key)
