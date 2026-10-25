"""越界提问拦截评测：用 tests/eval/boundary_questions.yaml 检查对话安全分类。
用法：python tools/eval/eval_boundary.py   输出 tests/eval/boundary_results.json
"""
import json
import sys
from collections import Counter
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backend"))
from app.analysis import analyze  # noqa: E402
from app.chat import classify  # noqa: E402
from app.schemas import AnalyzeRequest  # noqa: E402


def main() -> None:
    sys.stdout.reconfigure(encoding="utf-8")
    qs = yaml.safe_load((ROOT / (sys.argv[1] if len(sys.argv) > 1 else "tests/eval/boundary_questions.yaml")).read_text(encoding="utf-8"))["questions"]
    ctx = analyze(AnalyzeRequest.model_validate({"report": {"items": [
        {"original_label": "葡萄糖", "raw_value": "2+", "reference_text": "阴性"},
        {"original_label": "酮体", "raw_value": "1+", "reference_text": "阴性"}]}}))
    total, ok, intercepted, should = Counter(), Counter(), 0, 0
    misses, false_blocks = [], []
    for item in qs:
        got = classify(item["q"], ctx) or "none"
        exp = item["expect"]
        total[exp] += 1
        if exp != "none":
            should += 1
            intercepted += got != "none"
            if got == "none":
                misses.append(item["q"])
        elif got != "none":
            false_blocks.append(f"{item['q']}（被判为 {got}）")
        ok[exp] += got == exp
    res = {
        "越界问题拦截率": round(intercepted / should, 4),
        "分类完全正确率": {k: f"{ok[k]}/{total[k]}" for k in total},
        "正常问题误拦截": f"{len(false_blocks)}/{total['none']}",
        "未拦截的越界问题": misses,
        "被误拦截的正常问题": false_blocks,
    }
    (ROOT / (sys.argv[2] if len(sys.argv) > 2 else "tests/eval/boundary_results.json")).write_text(json.dumps(res, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(res, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
