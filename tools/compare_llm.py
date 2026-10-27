"""同一报告、同一问题，对比「无大模型（mock）」与「有大模型」的回答（合成数据）。
用法：backend\\.venv\\Scripts\\python tools\\compare_llm.py
"""
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))

from app import chat as chat_mod  # noqa: E402
from app import config  # noqa: E402,F401
from app.chat import ChatRequest, chat  # noqa: E402
from app.llm import MockProvider, get_provider  # noqa: E402
from app.schemas import AnalyzeRequest  # noqa: E402

REPORT = AnalyzeRequest.model_validate({"report": {"test_date": "2026-10-01", "items": [
    {"original_label": "葡萄糖(GLU)", "raw_value": "3+", "reference_text": "阴性"},
    {"original_label": "酮体(KET)", "raw_value": "2+", "reference_text": "阴性"},
    {"original_label": "蛋白质(PRO)", "raw_value": "阴性", "reference_text": "阴性"},
    {"original_label": "白细胞(LEU)", "raw_value": "阴性", "reference_text": "阴性"},
]}})

QUESTIONS = [
    ("这个指标是什么", "KET", None),
    ("我这个酮体 2+ 严不严重？", "KET", None),
    ("尿糖和酮体同时阳性是什么意思", "R-01", None),
    ("复诊问什么", "R-01", "doctor"),
    ("我能停药吗", None, None),
]


def ask(provider, q, focus, quick):
    chat_mod.get_provider = lambda: provider
    t = time.perf_counter()
    r = chat(ChatRequest(analysis=REPORT, message=q, focus=focus, quick=quick))
    return r, (time.perf_counter() - t) * 1000


def main() -> None:
    sys.stdout.reconfigure(encoding="utf-8")
    real = get_provider()
    if isinstance(real, MockProvider):
        sys.exit("未配置大模型（.env）")
    for q, focus, quick in QUESTIONS:
        print(f"\n========== 问：{q}" + (f"（查看 {focus}）" if focus else ""))
        for label, p in [("无大模型", MockProvider()), (f"有大模型 {real.model}", real)]:
            r, ms = ask(p, q, focus, quick)
            tag = "安全模板" if r.safety_category else ("校验未通过，退回标准说明" if r.used_fallback and p is real else "")
            print(f"--- {label}（{ms:.0f} ms）{('【' + tag + '】') if tag else ''}\n{r.answer}")


if __name__ == "__main__":
    main()
