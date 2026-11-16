"""把珍珠鸟 GIF 拆成 PNG 帧（app/assets/pet/frames/），供 APP 逐帧播放。
原因见 app/lib/widgets/pearl_bird.dart：直接播放 GIF 会让安卓模拟器随机崩溃。
更换 GIF 后执行：backend\.venv\Scripts\python tools\split_pet_gif.py，并按输出更新 pearl_bird.dart 的 birdFrames。
"""
from pathlib import Path

from PIL import Image, ImageSequence

PET = Path(__file__).resolve().parents[1] / "app" / "assets" / "pet"
OUT = PET / "frames"
OUT.mkdir(exist_ok=True)
for old in OUT.glob("bird_*.png"):
    old.unlink()
for mood in ("normal", "happy", "low", "recover"):
    durations = []
    for i, frame in enumerate(ImageSequence.Iterator(Image.open(PET / f"bird_{mood}.gif"))):
        frame.convert("RGBA").save(OUT / f"bird_{mood}_{i}.png", optimize=True)
        durations.append(frame.info.get("duration") or 100)
    print(f"BirdMood.{mood}: ({len(durations)}, {round(sum(durations) / len(durations))}),")
