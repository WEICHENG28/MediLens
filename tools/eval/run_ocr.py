"""对评测集逐份运行 PP-OCRv5（与 APP 相同的 ONNX 模型；Python 参考实现），输出 OCR 文本行 JSON。

APP 端 Dart 实现与此参考实现的一致性已在模拟器上用 5 份样本验证（docs/开发进展.md 迭代 3）。
用法：tools/.venv/Scripts/python -I tools/eval/run_ocr.py [dev|test]
"""
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import ocr_reference as ref  # noqa: E402

import numpy as np  # noqa: E402
import onnxruntime as ort  # noqa: E402
from PIL import Image  # noqa: E402


def main() -> None:
    sys.stdout.reconfigure(encoding="utf-8")
    assets = ROOT / "app" / "assets" / "ocr"
    chars = ["<blank>"] + (assets / "ppocrv5_dict.txt").read_text(encoding="utf-8").splitlines() + [" "]
    d = ort.InferenceSession(str(assets / "det.onnx"))
    r = ort.InferenceSession(str(assets / "rec.onnx"))
    eval_set = sys.argv[1] if len(sys.argv) > 1 else "dev"
    out_dir = ROOT / "tests" / "eval" / eval_set / "ocr"
    out_dir.mkdir(parents=True, exist_ok=True)
    images = sorted((ROOT / "tests" / "eval" / eval_set / "images").glob("*.png"))
    for p in images:
        img = np.asarray(Image.open(p).convert("RGB"))
        h, w = img.shape[:2]
        t = time.perf_counter()
        lines = []
        for x0, y0, x1, y1, s in ref.det(d, img):
            txt, c = ref.rec(r, img[int(y0):int(y1), int(x0):int(x1)], chars)
            if txt.strip():
                lines.append({"text": txt, "confidence": round(c, 4),
                              "box": {"x": round(x0 / w, 4), "y": round(y0 / h, 4), "w": round((x1 - x0) / w, 4), "h": round((y1 - y0) / h, 4)}})
        ms = (time.perf_counter() - t) * 1000
        (out_dir / f"{p.stem}.json").write_text(json.dumps({"source": p.name, "ocr_ms": round(ms), "lines": lines}, ensure_ascii=False), encoding="utf-8")
    print(f"完成 {len(images)} 份 OCR → {out_dir}")


if __name__ == "__main__":
    main()
