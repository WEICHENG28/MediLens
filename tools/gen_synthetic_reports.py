"""生成合成尿常规/UACR 报告图片与标注（全部为虚构数据，图上带「合成测试样本」水印）。

用法：python tools/gen_synthetic_reports.py
输出：tests/fixtures/*.synthetic.png 与同名 .json（期望识别结果与结果单元格归一化坐标）
字体：使用开发机 Windows 自带中文字体生成图片（仅开发工具，APP 不使用）。
"""
from __future__ import annotations

import json
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "tests" / "fixtures"
FONT = "C:/Windows/Fonts/msyh.ttc"
W, H = 1240, 1754  # A4 @150dpi

COLS = [("项目", 70), ("结果", 520), ("单位", 720), ("参考范围", 880), ("提示", 1110)]

URINE_NORMAL = [
    ("葡萄糖(GLU)", "阴性", "", "阴性", ""),
    ("酮体(KET)", "阴性", "", "阴性", ""),
    ("蛋白质(PRO)", "阴性", "", "阴性", ""),
    ("白细胞(LEU)", "阴性", "", "阴性", ""),
    ("亚硝酸盐(NIT)", "阴性", "", "阴性", ""),
    ("隐血(BLD)", "阴性", "", "阴性", ""),
    ("比重(SG)", "1.020", "", "1.003-1.030", ""),
    ("酸碱度(pH)", "6.0", "", "4.5-8.0", ""),
]


def _replace(rows, **kw):
    out = []
    for r in rows:
        code = r[0].split("(")[1].rstrip(")").upper()
        out.append(kw.get(code, r))
    return out


CASES = {
    "01_normal_urinalysis": {
        "title": "尿常规", "rows": URINE_NORMAL,
        "desc": "全部阴性；预期命中 R-06（绿色，测试规则）",
    },
    "02_glucose_ketone": {
        "title": "尿常规",
        "rows": _replace(URINE_NORMAL, GLU=("葡萄糖(GLU)", "3+", "", "阴性", "↑"), KET=("酮体(KET)", "2+", "", "阴性", "↑")),
        "desc": "尿糖 3+、酮体 2+；预期命中 R-01（红色+紧急提示，测试规则）",
    },
    "03_protein_ambiguous": {
        "title": "尿常规",
        "rows": _replace(URINE_NORMAL, PRO=("蛋白质(PRO)", "2+", "", "阴性", "↑")),
        "smudge": "PRO", "desc": "尿蛋白结果被污渍遮挡（1+/2+ 易混淆），预期触发局部确认",
    },
    "04_uacr_infection": {
        "title": "尿常规+尿微量白蛋白/肌酐",
        "rows": _replace(URINE_NORMAL, LEU=("白细胞(LEU)", "2+", "", "阴性", "↑"), NIT=("亚硝酸盐(NIT)", "阳性", "", "阴性", "↑"))
        + [("尿微量白蛋白/肌酐", "86.5", "mg/g", "<30", "↑")],
        "desc": "UACR 86.5 mg/g + 白细胞/亚硝酸盐阳性；预期命中 R-03、问答后 R-04",
    },
    "05_uacr_mgmmol": {
        "title": "尿微量白蛋白/肌酐比",
        "rows": [("尿微量白蛋白", "42.0", "mg/L", "", ""), ("尿肌酐", "8.1", "mmol/L", "", ""),
                 ("尿微量白蛋白/肌酐", "5.2", "mg/mmol", "<3.4", "↑")],
        "desc": "UACR 以 mg/mmol 报告，换算约 46 mg/g；尿微量白蛋白、尿肌酐为非首期项目",
    },
    "06_missing_reference": {
        "title": "尿常规",
        "rows": [(r[0], r[1], r[2], "", "") for r in _replace(URINE_NORMAL, GLU=("葡萄糖(GLU)", "1+", "", "", ""))],
        "desc": "报告缺参考范围；定性项按字典通用参考比对并标注",
    },
    "07_non_target_liver": {
        "title": "肝功能",
        "rows": [("谷丙转氨酶(ALT)", "35", "U/L", "9-50", ""), ("谷草转氨酶(AST)", "28", "U/L", "15-40", ""),
                 ("总胆红素(TBIL)", "12.3", "μmol/L", "0-21", "")],
        "desc": "非尿检报告；预期提示「当前不支持」",
    },
    "08_rotated_glucose_ketone": {
        "title": "尿常规",
        "rows": _replace(URINE_NORMAL, GLU=("葡萄糖(GLU)", "3+", "", "阴性", "↑"), KET=("酮体(KET)", "2+", "", "阴性", "↑")),
        "rotate": 90, "desc": "同 02 但图像旋转 90°，用于坐标系测试",
    },
    "09_blurry": {
        "title": "尿常规", "rows": URINE_NORMAL, "blur": 3.2,
        "desc": "整体模糊；预期质量检查提示重拍",
    },
}


def draw_report(case: dict, seed: int) -> tuple[Image.Image, list[dict]]:
    random.seed(seed)
    img = Image.new("RGB", (W, H), "white")
    d = ImageDraw.Draw(img)
    f_title = ImageFont.truetype(FONT, 44)
    f = ImageFont.truetype(FONT, 30)
    f_small = ImageFont.truetype(FONT, 24)

    d.text((W // 2, 80), "合成市第一人民医院 检验报告单", font=f_title, fill="black", anchor="mm")
    d.text((W // 2, 140), f"（{case['title']}）", font=f, fill="black", anchor="mm")
    d.text((70, 200), "姓名：合成患者A    性别：—    年龄：—", font=f, fill="black")
    d.text((70, 250), "样本类型：尿液    检验日期：2026-10-01    科室：内分泌科", font=f, fill="black")
    d.line((60, 305, W - 60, 305), fill="black", width=3)
    for name, x in COLS:
        d.text((x, 325), name, font=f, fill="black")
    d.line((60, 375, W - 60, 375), fill="black", width=2)

    boxes = []
    y = 400
    for row in case["rows"]:
        for (col, x), val in zip(COLS, row):
            if val:
                d.text((x, y), val, font=f, fill="black")
        bb = d.textbbox((COLS[1][1], y), row[1], font=f)
        boxes.append({"label": row[0], "value": row[1], "unit": row[2] or None, "reference": row[3] or None,
                      "flag": row[4] or None,
                      "value_box_px": list(bb)})
        y += 62
    d.line((60, y + 10, W - 60, y + 10), fill="black", width=2)
    d.text((70, y + 40), "检验者：合成    审核者：合成    本报告仅对所检标本负责", font=f_small, fill="black")

    if case.get("smudge"):
        target = next(b for b in boxes if case["smudge"] in b["label"])
        x0, y0, x1, y1 = target["value_box_px"]
        # 在数字上叠加半透明污渍，使 1+/2+ 难以分辨
        smudge = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        sd = ImageDraw.Draw(smudge)
        sd.ellipse((x0 - 6, y0 - 4, x0 + (x1 - x0) * 0.6, y1 + 6), fill=(90, 90, 90, 175))
        img = Image.alpha_composite(img.convert("RGBA"), smudge).convert("RGB")

    # 水印
    wm = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    wd = ImageDraw.Draw(wm)
    f_wm = ImageFont.truetype(FONT, 64)
    # 大水印放在表格下方空白区，避免遮挡指标影响 OCR；顶部另有醒目标签
    for i in range(3):
        wd.text((80, 1150 + i * 200), "合成测试样本 SYNTHETIC · 非真实报告", font=f_wm, fill=(220, 0, 0, 70))
    wm = wm.rotate(12, center=(W // 2, 1350))
    img = Image.alpha_composite(img.convert("RGBA"), wm).convert("RGB")
    dd = ImageDraw.Draw(img)
    dd.rectangle((W - 330, 10, W - 20, 50), outline=(200, 0, 0), width=2)
    dd.text((W - 175, 30), "合成测试样本 非真实", font=f_small, fill=(200, 0, 0), anchor="mm")
    dd.text((W - 70, H - 50), "SYNTHETIC 合成", font=f_small, fill=(200, 0, 0), anchor="rm")

    if case.get("blur"):
        img = img.filter(ImageFilter.GaussianBlur(case["blur"]))
    return img, boxes


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for seed, (name, case) in enumerate(CASES.items()):
        img, boxes = draw_report(case, seed)
        w, h = img.size
        rot = case.get("rotate", 0)
        for b in boxes:
            x0, y0, x1, y1 = b.pop("value_box_px")
            # 归一化坐标基于「未旋转的正向报告图」；旋转样本用于测试端侧把检测框映射回正向坐标
            b["value_box"] = {"page": 1, "x": round(x0 / w, 4), "y": round(y0 / h, 4),
                              "w": round((x1 - x0) / w, 4), "h": round((y1 - y0) / h, 4)}
        if rot:
            img = img.rotate(rot, expand=True)
        path = OUT / f"{name}.synthetic.png"
        img.save(path, optimize=True)
        meta = {"synthetic": True, "notice": "合成测试样本，非真实报告", "description": case["desc"],
                "test_date": "2026-10-01", "rotation_applied": rot, "items": boxes}
        (OUT / f"{name}.synthetic.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
        print("生成", path.name)


if __name__ == "__main__":
    main()
