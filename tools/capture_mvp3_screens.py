"""自动操作模拟器截取 MVP3 画面（示范模式陈女士，合成资料）：生活页各区块、复诊摘要、拍餐识别。

依 Flutter 的无障碍标签找按钮位置（uiautomator dump），不依赖固定座标。
用法：tools/.venv/Scripts/python.exe tools/capture_mvp3_screens.py <步骤>
  life   ：进入生活打卡 → 示范模式完整 14 天 → 逐段截图
  visit  ：复诊摘要
  meal   ：拍餐 → 从相册选一张展示照片 → 识别候选
输出：docs/screenshots/mvp3/
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADB = str(ROOT / ".toolchain" / "android-sdk" / "platform-tools" / "adb.exe")
OUT = ROOT / "docs" / "screenshots" / "mvp3"
ENV = {**os.environ, "MSYS_NO_PATHCONV": "1"}


def adb(*args, binary=False):
    r = subprocess.run([ADB, *args], capture_output=True, env=ENV)
    return r.stdout if binary else r.stdout.decode("utf-8", "replace")


def nodes():
    adb("shell", "uiautomator", "dump", "/sdcard/ui.xml")
    xml = adb("shell", "cat", "/sdcard/ui.xml")
    out = []
    for m in re.finditer(r'<node [^>]*?(?:text="([^"]*)")[^>]*?content-desc="([^"]*)"[^>]*?bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', xml):
        text, desc, x1, y1, x2, y2 = m.groups()
        out.append(((text + " " + desc).replace("&#10;", " ").strip(), (int(x1) + int(x2)) // 2, (int(y1) + int(y2)) // 2))
    return out


def tap(label: str, wait: float = 1.5, required: bool = True) -> bool:
    for name, x, y in nodes():
        if label in name:
            adb("shell", "input", "tap", str(x), str(y))
            time.sleep(wait)
            return True
    if required:
        raise SystemExit(f"找不到：{label}")
    return False


def swipe(dy: int = 1300):
    adb("shell", "input", "swipe", "540", "1900", "540", str(1900 - dy), "600")
    time.sleep(1.2)


def shot(name: str):
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / f"{name}.png").write_bytes(adb("exec-out", "screencap", "-p", binary=True))
    print("截图", name)


def life():
    tap("生活打卡 · 珍珠鸟陪伴", 3)
    if not tap("显示菜单", 1, required=False):
        tap("Show menu", 1)
    tap("示范模式：陈女士", 1.5)
    tap("完整 14 天", 10)
    shot("01_示范模式_今天")
    for i in range(2, 8):
        swipe()
        shot(f"0{i}_生活页_{i}")


def visit():
    for _ in range(12):
        if tap("复诊摘要", 6, required=False):
            break
        swipe()
    shot("10_复诊摘要")
    swipe()
    shot("11_复诊摘要_下")
    adb("shell", "input", "keyevent", "4")
    time.sleep(1.5)


def meal(photo: str = "宫保鸡丁_1"):
    adb("shell", "input", "keyevent", "4")
    time.sleep(1)
    tap("生活打卡 · 珍珠鸟陪伴", 3)
    for _ in range(4):
        if tap("拍餐饮", 3, required=False):
            break
        swipe(800)
    tap("从相册选图", 3)
    shot("20_相册")
    print([n for n, _, _ in nodes()][:40])


if __name__ == "__main__":
    {"life": life, "visit": visit, "meal": meal}[sys.argv[1]]()
