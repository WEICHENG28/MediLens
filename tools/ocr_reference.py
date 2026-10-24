"""PP-OCRv5 ONNX 参考实现（Python，仅开发工具）：用于验证模型与给端侧 Dart 实现做对照。

用法：tools/.venv/Scripts/python -I tools/ocr_reference.py tests/fixtures/02_glucose_ketone.synthetic.png
"""
import sys
import json
import time
from pathlib import Path

import numpy as np
import onnxruntime as ort
from PIL import Image
from scipy import ndimage

ASSETS = "client_assets_tmp"
MEAN = np.array([0.485, 0.456, 0.406], np.float32)
STD = np.array([0.229, 0.224, 0.225], np.float32)


def det(sess, img: np.ndarray, limit=960):
    h, w = img.shape[:2]
    scale = limit / max(h, w)
    nh, nw = max(32, int(round(h * scale / 32)) * 32), max(32, int(round(w * scale / 32)) * 32)
    im = np.asarray(Image.fromarray(img).resize((nw, nh), Image.BILINEAR), np.float32) / 255.0
    im = (im[:, :, ::-1] - MEAN) / STD  # RGB→BGR，与 PaddleOCR 预处理一致
    x = im.transpose(2, 0, 1)[None].astype(np.float32)
    prob = sess.run(None, {"x": x})[0][0, 0]
    mask = prob > 0.3
    lab, n = ndimage.label(mask)
    boxes = []
    for i, sl in enumerate(ndimage.find_objects(lab), start=1):
        ys, xs = sl
        score = prob[sl][lab[sl] == i].mean()
        if score < 0.6 or (xs.stop - xs.start) < 3 or (ys.stop - ys.start) < 3:
            continue
        bh = ys.stop - ys.start
        pad = bh * 0.5  # 近似 unclip
        x0 = max(0, (xs.start - pad) * w / nw); x1 = min(w, (xs.stop + pad) * w / nw)
        y0 = max(0, (ys.start - pad) * h / nh); y1 = min(h, (ys.stop + pad) * h / nh)
        boxes.append((x0, y0, x1, y1, float(score)))
    return boxes


def rec(sess, crop: np.ndarray, chars):
    h, w = crop.shape[:2]
    nw = max(8, int(np.ceil(48 * w / h)))
    im = np.asarray(Image.fromarray(crop).resize((nw, 48), Image.BILINEAR), np.float32) / 255.0
    im = (im[:, :, ::-1] - 0.5) / 0.5
    out = sess.run(None, {"x": im.transpose(2, 0, 1)[None].astype(np.float32)})[0][0]
    idx = out.argmax(1); prob = out.max(1)
    text, confs, last = [], [], 0
    for i, p in zip(idx, prob):
        if i != 0 and i != last:
            text.append(chars[i]); confs.append(p)
        last = i
    return "".join(text), float(np.mean(confs)) if confs else 0.0


def run(path):
    chars = ["<blank>"] + open(f"{ASSETS}/ppocrv5_dict.txt", encoding="utf-8").read().splitlines() + [" "]
    d = ort.InferenceSession(f"{ASSETS}/det.onnx"); r = ort.InferenceSession(f"{ASSETS}/rec.onnx")
    img = np.asarray(Image.open(path).convert("RGB"))
    h, w = img.shape[:2]
    lines = []
    for x0, y0, x1, y1, s in det(d, img):
        txt, c = rec(r, img[int(y0):int(y1), int(x0):int(x1)], chars)
        if txt.strip():
            lines.append({"text": txt, "confidence": round(c, 4),
                          "box": {"x": round(x0 / w, 4), "y": round(y0 / h, 4), "w": round((x1 - x0) / w, 4), "h": round((y1 - y0) / h, 4)}})
    return {"source": Path(path).name, "synthetic": True, "image_size": [w, h], "lines": lines}


def main(path):
    chars = ["<blank>"] + open(f"{ASSETS}/ppocrv5_dict.txt", encoding="utf-8").read().splitlines() + [" "]
    d = ort.InferenceSession(f"{ASSETS}/det.onnx"); r = ort.InferenceSession(f"{ASSETS}/rec.onnx")
    img = np.asarray(Image.open(path).convert("RGB"))
    t = time.time()
    boxes = det(d, img)
    res = []
    for x0, y0, x1, y1, s in boxes:
        txt, c = rec(r, img[int(y0):int(y1), int(x0):int(x1)], chars)
        res.append((y0, x0, txt, c))
    for y0, x0, txt, c in sorted(res):
        print(f"y={y0:6.0f} x={x0:6.0f} conf={c:.3f} {txt}")
    print(f"共 {len(res)} 个文本框，用时 {time.time()-t:.1f}s")


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    if sys.argv[1] == "--export":
        # 导出全部正向合成样本的 OCR 结果，供 Dart 解析单测使用
        out = Path("app/test/fixtures/ocr"); out.mkdir(parents=True, exist_ok=True)
        for p in sorted(Path("tests/fixtures").glob("*.synthetic.png")):
            if "rotated" in p.name:
                continue
            (out / p.name.replace(".png", ".ocr.json")).write_text(json.dumps(run(p), ensure_ascii=False, indent=1), encoding="utf-8")
            print("导出", p.name)
    else:
        main(sys.argv[1])
