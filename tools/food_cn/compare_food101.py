"""对照：同一批测试照片（训练时没用过），原 Food-101 模型 vs 新的中式模型。

只比较两边都有的菜色（炒饭、饺子、煎饺、冰淇淋）；并统计挑选的 61 道菜中，原模型有对应类别的有几道。
用 tools/.venv 的 onnxruntime 执行两个 ONNX，前处理与 APP 相同。
"""
from __future__ import annotations

import io
import json
import sys
import zipfile
from pathlib import Path

import numpy as np
import onnxruntime as ort
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / ".datasets" / "food_cn_build"
ZIP = ROOT / ".datasets" / "cnfood241" / "val600x600.zip"
OLD = ROOT / ".datasets" / "food101-8021c00d.onnx"  # 原模型已从 APP 移除；比较时从 git 历史取出：git show 282cea0:app/assets/nutrition/food101-8021c00d.onnx（labels.txt 同理）
OVERLAP = {130: "fried_rice", 159: "dumplings", 165: "gyoza", 204: "ice_cream"}
NAMES = {130: "炒饭", 159: "饺子", 165: "煎饺", 204: "冰激凌"}


def prep(data: bytes) -> np.ndarray:
    im = Image.open(io.BytesIO(data)).convert("RGB")
    w, h = im.size
    im = im.resize((256, round(h * 256 / w)) if w <= h else (round(w * 256 / h), 256), Image.BILINEAR)
    w, h = im.size
    im = im.crop(((w - 224) // 2, (h - 224) // 2, (w - 224) // 2 + 224, (h - 224) // 2 + 224))
    a = np.asarray(im, np.float32) / 255.0
    a = (a - [0.485, 0.456, 0.406]) / [0.229, 0.224, 0.225]
    return a.transpose(2, 0, 1)[None].astype(np.float32)


def main():
    split = json.loads((BUILD / "split.json").read_text(encoding="utf-8"))
    old_labels = (ROOT / ".datasets" / "food101_labels.txt").read_text().split()
    new_labels = (BUILD / "labels_cn.txt").read_text().split()
    old = ort.InferenceSession(str(OLD), providers=["CPUExecutionProvider"])
    new = ort.InferenceSession(str(BUILD / (sys.argv[1] if len(sys.argv) > 1 else "food_cn.onnx")), providers=["CPUExecutionProvider"])
    z = zipfile.ZipFile(ZIP)
    out = {}
    for c, lab in OVERLAP.items():
        names = split[str(c)]["test"]
        o_hit = n_hit = 0
        for n in names:
            x = prep(z.read(n))
            o = old.run(None, {old.get_inputs()[0].name: x})[0][0]
            nw = new.run(None, {new.get_inputs()[0].name: x})[0][0]
            o_hit += old_labels[int(o.argmax())] == lab
            n_hit += new_labels[int(nw.argmax())] == f"cn{c:03d}"
        out[NAMES[c]] = {"n": len(names), "food101": round(o_hit / len(names), 3), "new": round(n_hit / len(names), 3)}
    cover = sum(1 for c in split if int(c) in OVERLAP)
    report = {"overlap": out, "selected_classes": len(split), "food101_has_class_for": cover}
    (BUILD / "compare.json").write_text(json.dumps(report, ensure_ascii=False, indent=1), encoding="utf-8")
    sys.stdout.reconfigure(encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    main()
