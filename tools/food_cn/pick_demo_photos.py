"""展示用照片：从测试照片（训练时没看过）里每道菜随机抽 2 张，并用 APP 同样的前处理跑一次新模型，如实记录结果。

照片属于 CNFOOD-241（CC BY-NC 3.0，非商业），只放本机 D:/MediLens/.datasets/demo_photos/，不上传。
用法：tools/.venv/Scripts/python.exe tools/food_cn/pick_demo_photos.py
"""
import json
import random
import sys
import zipfile
from pathlib import Path

import numpy as np
import onnxruntime as ort

sys.path.insert(0, str(Path(__file__).parent))
from compare_food101 import prep  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / ".datasets" / "food_cn_build"
OUT = ROOT / ".datasets" / "demo_photos"
MODEL = ROOT / "app" / "assets" / "nutrition" / "food_cn-c9a5f4f7.onnx"
DISHES = {172: "米饭", 130: "炒饭", 149: "炸酱面", 152: "西红柿鸡蛋面", 159: "饺子", 145: "包子", 144: "馒头",
          171: "大米粥", 167: "小米粥", 77: "红烧肉", 71: "宫保鸡丁", 0: "麻婆豆腐"}


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    split = json.loads((BUILD / "split.json").read_text(encoding="utf-8"))
    names = json.loads((BUILD / "names_cn.json").read_text(encoding="utf-8"))
    labels = (ROOT / "app" / "assets" / "nutrition" / "labels_cn.txt").read_text().split()
    sess = ort.InferenceSession(str(MODEL), providers=["CPUExecutionProvider"])
    z = zipfile.ZipFile(ROOT / ".datasets" / "cnfood241" / "val600x600.zip")
    OUT.mkdir(parents=True, exist_ok=True)
    rng = random.Random(7)
    rows = []
    for cls, dish in DISHES.items():
        for k, n in enumerate(rng.sample(split[str(cls)]["test"], 2), 1):
            data = z.read(n)
            fname = f"{dish}_{k}.jpg"
            (OUT / fname).write_bytes(data)
            s = sess.run(None, {"input": prep(data)})[0][0]
            p = np.exp(s - s.max())
            p /= p.sum()
            top = np.argsort(-p)[:3]
            cands = [f"{names[labels[i]]} {p[i]:.0%}" for i in top]
            ok = labels[top[0]] == f"cn{cls:03d}"
            in3 = f"cn{cls:03d}" in [labels[i] for i in top]
            rows.append({"file": fname, "dish": dish, "top1_correct": bool(ok), "in_top3": bool(in3), "candidates": cands,
                         "shown": bool(p[top[0]] >= 0.20)})
            print(f"{fname:<16} {'✓' if ok else ('△' if in3 else '✗')}  {' / '.join(cands)}{'' if p[top[0]] >= 0.20 else '（机率低，APP 不给候选）'}")
    (OUT / "results.json").write_text(json.dumps(rows, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"第一名正确 {sum(r['top1_correct'] for r in rows)}/{len(rows)}，前三名含正确 {sum(r['in_top3'] for r in rows)}/{len(rows)}")


if __name__ == "__main__":
    main()
