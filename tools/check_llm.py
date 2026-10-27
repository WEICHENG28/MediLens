"""检查 .env 中配置的大模型能否连通（不会打印密钥）。

用法（在仓库根目录）：backend\\.venv\\Scripts\\python tools\\check_llm.py
"""
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))

from app import config  # noqa: E402,F401  加载 .env
from app.llm import LLMError, MockProvider, OpenAICompatProvider, get_provider  # noqa: E402


def main() -> int:
    sys.stdout.reconfigure(encoding="utf-8")
    p = get_provider()
    if isinstance(p, MockProvider):
        print("当前为 mock 模式：.env 中未设置 LLM_PROVIDER，或缺少对应的密钥 / 接口地址。")
        return 1
    assert isinstance(p, OpenAICompatProvider)
    print(f"服务：{p.name}  地址：{p.base_url}  模型：{p.model}  密钥：{'已设置（' + str(len(p.api_key)) + ' 个字符）' if p.api_key else '未设置'}")
    t = time.perf_counter()
    try:
        text = p.complete("你是测试助手，只用中文回答，不超过 20 字。", "请回复：连接成功")
    except LLMError as e:
        cause = e.__cause__
        detail = ""
        if cause is not None and getattr(cause, "response", None) is not None:
            detail = f"（HTTP {cause.response.status_code}：{cause.response.text[:200]}）"
        print(f"✗ 调用失败：{e}{detail}")
        print("请检查：接口地址是否以 /v1 结尾、模型名称是否与平台列表完全一致、密钥是否有效、网络能否访问该地址。")
        return 1
    print(f"✓ 调用成功（{(time.perf_counter() - t) * 1000:.0f} ms）：{text.strip()[:60]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
