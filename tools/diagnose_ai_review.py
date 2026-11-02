"""Run with the server venv. Uses one fixed synthetic value; prints no secrets."""
import argparse
import json
import sys
from pathlib import Path
from time import monotonic


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", type=Path, default=Path.home() / "medilens")
    args = parser.parse_args()
    sys.path.insert(0, str(args.project.resolve() / "backend"))
    try:
        from app import config  # loads server-local settings without printing them
        from app.llm import OpenAICompatProvider, get_provider
        from app.ocr_review import OcrReviewRequest, review
        provider = get_provider()
        print(json.dumps({"configured": provider.name != "mock",
            "disable_thinking": provider.disable_thinking if isinstance(provider, OpenAICompatProvider) else None}, ensure_ascii=False), flush=True)
        started = monotonic()
        result = review(OcrReviewRequest(consent=True, code="PRO", value="+", candidates=["1+", "阴性"]))
        print(json.dumps({"status": result.status,
            "reason_code": getattr(result, "reason_code", None),
            "seconds": round(monotonic() - started, 2)}, ensure_ascii=False), flush=True)
    except Exception:
        # Never print exceptions, provider output, settings or traceback.
        print("诊断未完成，请先确认更新已安装并使用服务器项目的Python环境。")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
