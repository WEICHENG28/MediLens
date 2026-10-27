"""越界提问拦截：关键词单层 vs 关键词+大模型两层（两轮各 60 句测试题；提示词未针对测试题调整）。
用法：backend\\.venv\\Scripts\\python tools\\eval\\eval_boundary_llm.py
输出：tests/eval/boundary_results_llm.json
"""
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backend"))
from app import config  # noqa: E402,F401
from app import chat as chat_mod  # noqa: E402
from app.analysis import analyze  # noqa: E402
from app.schemas import AnalyzeRequest  # noqa: E402

CANDIDATES = [m for m in os.environ.get("EVAL_INTENT_MODELS", "DeepSeek-V4.1-Flash").split(",") if m]  # 初次比较曾含 Qwen3.8-Flash（第二轮 75.0%）
SETS = {"第一轮": "tests/eval/boundary_questions.yaml", "第二轮（新题）": "tests/eval/boundary_questions_v2.yaml"}


def main() -> None:
    sys.stdout.reconfigure(encoding="utf-8")
    ctx = analyze(AnalyzeRequest.model_validate({"report": {"items": [
        {"original_label": "葡萄糖", "raw_value": "2+", "reference_text": "阴性"},
        {"original_label": "酮体", "raw_value": "1+", "reference_text": "阴性"}]}}))
    data = {name: yaml.safe_load((ROOT / p).read_text(encoding="utf-8"))["questions"] for name, p in SETS.items()}
    results = {}
    for model in ["仅关键词"] + CANDIDATES:
        res_model = {}
        for set_name, qs in data.items():
            def run(q):
                text = chat_mod.to_simplified(q["q"])
                t = time.perf_counter()
                if model == "仅关键词":
                    cat, src = chat_mod.classify(text, ctx), "keyword"
                else:
                    cat, src = chat_mod.classify_intent(text, ctx)
                return q, cat, src, time.perf_counter() - t

            if model != "仅关键词":
                os.environ["LLM_INTENT_MODEL"] = model
            with ThreadPoolExecutor(3) as ex:  # 并发 3，接近实际使用
                out = list(ex.map(run, qs))
            boundary = [(q, c, s, t) for q, c, s, t in out if q["expect"] != "none"]
            normal = [(q, c, s, t) for q, c, s, t in out if q["expect"] == "none"]
            llm_times = [t for q, c, s, t in out if s != "keyword"]
            res_model[set_name] = {
                "越界问题拦截率": round(sum(c is not None for q, c, s, t in boundary) / len(boundary), 4),
                "其中由大模型补拦": sum(s == "llm" and q["expect"] != "none" for q, c, s, t in out),
                "正常问题误拦截": f"{sum(c is not None for q, c, s, t in normal)}/{len(normal)}",
                "被误拦的正常问题": [q["q"] for q, c, s, t in normal if c is not None],
                "仍未拦截": [q["q"] for q, c, s, t in boundary if c is None],
                "大模型判断平均耗时(秒)": round(sum(llm_times) / len(llm_times), 2) if llm_times else 0,
            }
            print(model, set_name, {k: v for k, v in res_model[set_name].items() if k not in ("被误拦的正常问题", "仍未拦截")})
        results[model] = res_model
    out_path = ROOT / "tests/eval/boundary_results_llm.json"  # 结果含「仍未拦截」清单供复核
    out_path.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
