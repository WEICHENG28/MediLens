"""生成 OCR 评测用合成报告集（虚构数据，固定随机种子，可复现）。

- 120 份尿常规/UACR 报告：3 种版式 × 随机数值 × 8 种干扰（无、模糊、噪点、JPEG 压缩、轻微倾斜、污渍、阴影、低分辨率）
- 10 份非目标报告（肝功能、血常规），用于测试「不支持」识别
输出：tests/eval/images/*.png（不入库，可随时重新生成）与 tests/eval/truth/*.json（标准答案）

用法：python tools/eval/gen_eval_set.py [dev|test]
"""
from __future__ import annotations

import io
import json
import random
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[2]
# 评测集：dev（开发集，用于发现问题、调整解析规则）/ test（独立测试集，不参与任何调整，用于报告成绩）
SET = sys.argv[1] if len(sys.argv) > 1 else "dev"
IMG_DIR = ROOT / "tests" / "eval" / SET / "images"
TRUTH_DIR = ROOT / "tests" / "eval" / SET / "truth"
FONTS = ["C:/Windows/Fonts/msyh.ttc", "C:/Windows/Fonts/simsun.ttc"]
W, H = 1240, 1754
SEED = {"dev": 20261025, "test": 77031, "test2": 50917}[SET]  # test2：评估「UACR 强制确认」改动用的新测试集

# 不同医院常见的项目名写法（与字典同义词一致，用于检验映射能力）
LABELS = {
    "GLU": ["葡萄糖(GLU)", "尿糖", "GLU", "尿葡萄糖"],
    "KET": ["酮体(KET)", "尿酮体", "KET"],
    "PRO": ["蛋白质(PRO)", "尿蛋白", "PRO", "U-PRO"],
    "LEU": ["白细胞(LEU)", "白细胞酯酶", "LEU"],
    "NIT": ["亚硝酸盐(NIT)", "NIT"],
    "BLD": ["隐血(BLD)", "潜血", "BLD"],
    "SG": ["比重(SG)", "尿比重", "SG"],
    "PH": ["酸碱度(pH)", "pH", "PH"],
    "UACR": ["尿微量白蛋白/肌酐", "UACR", "尿白蛋白/肌酐比"],
}
QUAL = ["阴性", "阴性", "阴性", "±", "1+", "2+", "3+", "阳性"]
QUAL_REF = ["阴性", "阴性", "-"]

LAYOUTS = {
    # 列起点（项目/结果/单位/参考/提示）、表头文字、字号、行距、是否画线
    "A": dict(cols=[70, 520, 720, 880, 1110], head=["项目", "结果", "单位", "参考范围", "提示"], size=30, gap=62, lines=True),
    "B": dict(cols=[60, 470, 650, 830, 1100], head=["检验项目", "结果", "单位", "参考值", "标志"], size=28, gap=56, lines=False),
    "C": dict(cols=[80, 560, 760, 930, 1130], head=["项目名称", "检验结果", "单位", "参考区间", "提示"], size=26, gap=50, lines=True),
}
PERTURB = ["none", "blur", "noise", "jpeg", "skew", "smudge", "shadow", "lowres"]


def rand_report(rng: random.Random) -> list[dict]:
    items = []
    kind = rng.choice(["urine", "urine", "urine+uacr", "uacr"])
    if kind != "uacr":
        for code in ["GLU", "KET", "PRO", "LEU", "NIT", "BLD"]:
            v = rng.choice(QUAL)
            if code == "NIT" and v not in ("阴性", "阳性"):
                v = rng.choice(["阴性", "阳性"])
            items.append(dict(code=code, value=v, unit=None, reference=rng.choice(QUAL_REF), flag="↑" if v not in ("阴性", "-") else None))
        sg = f"{rng.uniform(1.003, 1.035):.3f}"
        items.append(dict(code="SG", value=sg, unit=None, reference="1.003-1.030", flag="↑" if float(sg) > 1.030 else None))
        ph = f"{rng.uniform(4.6, 8.4):.1f}"
        items.append(dict(code="PH", value=ph, unit=None, reference="4.5-8.0", flag="↑" if float(ph) > 8.0 else None))
    if kind != "urine":
        unit = rng.choice(["mg/g", "mg/g", "mg/mmol"])
        v = rng.choice([rng.uniform(3, 29), rng.uniform(30, 300), rng.uniform(301, 900)])
        if unit == "mg/mmol":
            v /= 8.84
            val, ref, hi = f"{v:.1f}", "<3.4", 3.4
        else:
            val, ref, hi = f"{v:.1f}", "<30", 30
        items.append(dict(code="UACR", value=val, unit=unit, reference=ref, flag="↑" if float(val) >= hi else None))
    if rng.random() < 0.15:  # 部分报告缺参考范围
        for it in items:
            it["reference"] = None
    return items


NON_TARGET = [
    [("谷丙转氨酶(ALT)", "35", "U/L", "9-50"), ("谷草转氨酶(AST)", "28", "U/L", "15-40"), ("总胆红素(TBIL)", "12.3", "μmol/L", "0-21")],
    [("白细胞计数(WBC#)", "6.2", "10^9/L", "3.5-9.5"), ("红细胞计数(RBC)", "4.6", "10^12/L", "4.3-5.8"), ("血红蛋白(HGB)", "138", "g/L", "130-175")],
]


def draw(items_rows, layout: dict, title: str, rng: random.Random) -> Image.Image:
    font_path = rng.choice(FONTS)
    img = Image.new("RGB", (W, H), "white")
    d = ImageDraw.Draw(img)
    f = ImageFont.truetype(font_path, layout["size"])
    ft = ImageFont.truetype(font_path, 42)
    fs = ImageFont.truetype(font_path, 22)
    d.text((W // 2, 80), "合成市第一人民医院 检验报告单", font=ft, fill="black", anchor="mm")
    d.text((W // 2, 135), f"（{title}）", font=f, fill="black", anchor="mm")
    d.rectangle((W - 330, 10, W - 20, 50), outline=(200, 0, 0), width=2)
    d.text((W - 175, 30), "合成测试样本 非真实", font=fs, fill=(200, 0, 0), anchor="mm")
    d.text((70, 190), "姓名：合成患者    样本类型：尿液", font=f, fill="black")
    d.text((70, 240), f"检验日期：2026-{rng.randint(1, 12):02d}-{rng.randint(1, 28):02d}", font=f, fill="black")
    if layout["lines"]:
        d.line((60, 295, W - 60, 295), fill="black", width=3)
    for name, x in zip(layout["head"], layout["cols"]):
        d.text((x, 310), name, font=f, fill="black")
    if layout["lines"]:
        d.line((60, 355, W - 60, 355), fill="black", width=2)
    y = 380
    boxes = []
    for row in items_rows:
        for x, val in zip(layout["cols"], row):
            if val:
                d.text((x, y), val, font=f, fill="black")
        boxes.append(d.textbbox((layout["cols"][1], y), row[1] or " ", font=f))
        y += layout["gap"]
    if layout["lines"]:
        d.line((60, y + 10, W - 60, y + 10), fill="black", width=2)
    d.text((70, y + 40), "本报告仅对所检标本负责 · SYNTHETIC 合成", font=fs, fill="black")
    return img, boxes


def perturb(img: Image.Image, kind: str, boxes, rng: random.Random) -> Image.Image:
    if kind == "blur":
        return img.filter(ImageFilter.GaussianBlur(rng.uniform(1.2, 2.2)))
    if kind == "noise":
        px = img.load()
        for _ in range(60000):
            x, y = rng.randrange(W), rng.randrange(H)
            g = rng.randint(0, 255)
            px[x, y] = (g, g, g)
        return img
    if kind == "jpeg":
        buf = io.BytesIO()
        img.save(buf, "JPEG", quality=rng.randint(12, 25))
        return Image.open(io.BytesIO(buf.getvalue())).convert("RGB")
    if kind == "skew":
        return img.rotate(rng.uniform(-2.5, 2.5), expand=True, fillcolor="white")
    if kind == "smudge":
        x0, y0, x1, y1 = rng.choice(boxes)
        over = Image.new("RGBA", img.size, (0, 0, 0, 0))
        ImageDraw.Draw(over).ellipse((x0 - 6, y0 - 4, x0 + (x1 - x0) * 0.6, y1 + 6), fill=(90, 90, 90, 170))
        return Image.alpha_composite(img.convert("RGBA"), over).convert("RGB")
    if kind == "shadow":
        shade = Image.linear_gradient("L").resize(img.size).point(lambda v: int(v * 0.55))
        dark = Image.new("RGB", img.size, (40, 40, 40))
        return Image.composite(dark, img, shade)
    if kind == "lowres":
        s = rng.uniform(0.35, 0.45)
        return img.resize((int(W * s), int(H * s)), Image.BILINEAR)
    return img


def main() -> None:
    sys.stdout.reconfigure(encoding="utf-8")
    rng = random.Random(SEED)
    IMG_DIR.mkdir(parents=True, exist_ok=True)
    TRUTH_DIR.mkdir(parents=True, exist_ok=True)
    n = 0
    for i in range(120):
        layout_key = "ABC"[i % 3]
        kind = PERTURB[(i // 3) % len(PERTURB)]
        items = rand_report(rng)
        rows = [(rng.choice(LABELS[it["code"]]), it["value"], it["unit"] or "", it["reference"] or "",
                 (it["flag"] or "") if layout_key != "C" else "") for it in items]
        title = "尿常规" if items[0]["code"] != "UACR" else "尿微量白蛋白/肌酐"
        img, boxes = draw(rows, LAYOUTS[layout_key], title, rng)
        img = perturb(img, kind, boxes, rng)
        name = f"{SET[0]}{i:03d}_{layout_key}_{kind}"
        img.save(IMG_DIR / f"{name}.png")
        truth = {"synthetic": True, "layout": layout_key, "perturbation": kind, "supported": True,
                 "items": [dict(code=it["code"], label=r[0], value=it["value"], unit=it["unit"], reference=it["reference"])
                           for it, r in zip(items, rows)]}
        (TRUTH_DIR / f"{name}.json").write_text(json.dumps(truth, ensure_ascii=False, indent=1), encoding="utf-8")
        n += 1
    for i in range(10):
        rows = [(a, b, c, dd, "") for a, b, c, dd in NON_TARGET[i % 2]]
        img, _ = draw(rows, LAYOUTS["ABC"[i % 3]], "肝功能" if i % 2 == 0 else "血常规", rng)
        name = f"n{i:03d}_nontarget"
        img.save(IMG_DIR / f"{name}.png")
        (TRUTH_DIR / f"{name}.json").write_text(json.dumps({"synthetic": True, "supported": False, "items": []}, ensure_ascii=False), encoding="utf-8")
        n += 1
    print(f"生成 {n} 份合成评测报告 → {IMG_DIR}")


if __name__ == "__main__":
    main()
