"""中式菜色 → USDA FNDDS 条目（每 100 g 总碳水与总糖），供 APP 拍餐估算使用。

来源：USDA FoodData Central，FNDDS 2021–2023（survey food CSV，2024-10-31 发布，公有领域）。
本机资料放 D:/MediLens/.datasets/usda/（不上传）。FNDDS 以美国食物为主，许多中式菜没有完全对应的条目，
这时用最接近的条目并标记 approx=true，APP 显示「近似」；碳水只是参考，由用户确认份量。

用法：python tools/food_cn/build_food_reference.py
输出：tools/food_cn/cn_food_reference.json（入库，可检查每道菜对应了哪个 USDA 条目）
"""
from __future__ import annotations

import csv
import io
import json
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ZIP = ROOT / ".datasets" / "usda" / "fndds_survey_csv_2024-10-31.zip"
DIR = "FoodData_Central_survey_food_csv_2024-10-31/"
OUT = Path(__file__).with_name("cn_food_reference.json")

# CNFOOD-241 编号 → (中文名, FDC ID, 是否近似)
MAP = {
    172: ("米饭", 2708408, False), 130: ("炒饭", 2708951, False), 171: ("大米粥", 2708418, False),
    167: ("小米粥", 2708418, True), 168: ("红薯粥", 2708983, True), 215: ("南瓜粥", 2708983, True),
    170: ("皮蛋瘦肉粥", 2708981, False), 144: ("馒头", 2708725, True), 145: ("包子", 2708724, False),
    159: ("饺子", 2708708, False), 165: ("煎饺", 2708705, False), 164: ("馄饨（带汤）", 2709160, False),
    132: ("小笼汤包", 2708708, True), 133: ("烧麦", 2708708, True), 148: ("油条", 2708024, True),
    139: ("葱花手抓饼", 2707715, True), 140: ("芝麻烧饼", 2707616, True), 141: ("肉夹馍", 2706977, True),
    142: ("韭菜盒子", 2708735, True), 149: ("炸酱面", 2708798, True), 152: ("西红柿鸡蛋面（带汤）", 2709145, True),
    158: ("炒面", 2708798, True), 161: ("红烧牛肉面（带汤）", 2709154, True), 162: ("河粉", 2708356, True),
    155: ("凉皮", 2708356, True), 150: ("酸辣粉", 2708355, True), 166: ("汤圆", 2708345, True),
    160: ("玉米棒", 2709910, False), 173: ("紫菜包饭", 2708966, True), 240: ("煲仔饭", 2708954, True),
    131: ("蛋包饭", 2708951, True), 195: ("蛋糕", 2707886, True), 197: ("面包", 2707598, False),
    199: ("吐司", 2707599, False), 200: ("饼干", 2707899, True), 204: ("冰激凌", 2705630, False),
    207: ("水果沙拉", 2709287, False), 0: ("麻婆豆腐", 2706770, True), 71: ("宫保鸡丁", 2706796, False),
    77: ("红烧肉", 2706778, True), 50: ("西红柿炒鸡蛋", 2707200, True), 58: ("糖醋排骨", 2706401, True),
    87: ("糖醋里脊", 2706401, True), 97: ("鱼香肉丝", 2706740, True), 96: ("青椒肉丝", 2706778, True),
    84: ("回锅肉", 2706778, True), 19: ("炒青菜", 2710036, False), 5: ("酸辣土豆丝", 2709474, True),
    11: ("鱼香茄子", 2709930, True), 113: ("清蒸鲈鱼", 2706299, False), 68: ("黄焖鸡", 2705939, True),
    65: ("白斩鸡", 2705939, True), 106: ("酸菜鱼", 2706228, True), 85: ("猪肉炖粉条", 2707450, True),
    101: ("蚂蚁上树", 2707450, True), 180: ("西红柿鸡蛋汤", 2707282, True), 53: ("鸡蛋羹", 2707154, True),
    26: ("蚝油西兰花", 2709644, False), 60: ("可乐鸡翅", 2706063, True),
}


def main():
    z = zipfile.ZipFile(ZIP)
    desc = {r["fdc_id"]: r["description"] for r in csv.DictReader(io.TextIOWrapper(z.open(DIR + "food.csv"), encoding="utf-8"))}
    nut: dict[str, dict[str, float]] = {}
    # 这份 CSV 的 nutrient_id 是营养素编号：205 = 总碳水（差减法），269 = 总糖
    for r in csv.DictReader(io.TextIOWrapper(z.open(DIR + "food_nutrient.csv"), encoding="utf-8")):
        if r["nutrient_id"] in ("205", "269"):
            nut.setdefault(r["fdc_id"], {})[r["nutrient_id"]] = float(r["amount"])
    out = []
    for cls, (name, fdc, approx) in sorted(MAP.items()):
        n = nut[str(fdc)]
        out.append({"fdc_id": fdc, "name": name, "source_name": desc[str(fdc)], "carbs_per_100g": round(n["205"], 2),
                    "sugars_per_100g": round(n["269"], 2) if "269" in n else None, "labels": [f"cn{cls:03d}"], "approx": approx})
    OUT.write_text(json.dumps(out, ensure_ascii=False, indent=1), encoding="utf-8")
    sys.stdout.reconfigure(encoding="utf-8")
    for o in out:
        print(f"{o['labels'][0]} {o['name']:<10} {o['carbs_per_100g']:>6} g  {'近似 ' if o['approx'] else '     '}{o['source_name']}")
    print(len(out), "道；近似", sum(o["approx"] for o in out))


if __name__ == "__main__":
    main()
