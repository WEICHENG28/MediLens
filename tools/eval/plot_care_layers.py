"""实验 G 图：每一层资料下，各情境的辨识率（合成病人 400 位，14 天，一般干扰）。

读取 tests/eval/care_layers/results_n400_noise1.json，输出 docs/figures/07_实验G_分层对照.png。
用法：python tools/eval/plot_care_layers.py（需要 matplotlib）
"""
import json
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
S = json.loads((ROOT / "tests/eval/care_layers/results_n400_noise1.json").read_text(encoding="utf-8"))["summary"]["layers"]

plt.rcParams["font.family"] = ["Microsoft YaHei", "sans-serif"]
SURFACE, TEXT, MUTED, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e1e0d9"
series = [  # (名称, 取值, 颜色) 依类别色板固定顺序
    ("夜间低值提示", lambda L: L["night_low_recall"], "#2a78d6"),
    ("晚吃照常用药→夜间低值", lambda L: L["scenario"]["late_med_low"]["recall"], "#eb6834"),
    ("高碳水晚餐→餐后偏高", lambda L: L["scenario"]["dinner_high"]["recall"], "#1baf7a"),
    ("饭后散步→餐后较低", lambda L: L["scenario"]["walk_helps"]["recall"], "#eda100"),
]
layers = [("A", "只有医院检验"), ("B", "＋居家血糖"), ("C", "＋饮食与用药时间"), ("D", "＋活动、睡眠等")]

fig, ax = plt.subplots(figsize=(10, 5.2), dpi=200)
fig.patch.set_facecolor(SURFACE)
ax.set_facecolor(SURFACE)
w = 0.19
for i, (name, get, color) in enumerate(series):
    xs = [k + (i - 1.5) * (w + 0.012) for k in range(len(layers))]
    vals = [get(S[code]) * 100 for code, _ in layers]
    ax.bar(xs, vals, w, color=color, label=name, edgecolor=SURFACE, linewidth=1.5, zorder=3)
    for x, v in zip(xs, vals):
        ax.text(x, v + 1.5, f"{v:.0f}%", ha="center", va="bottom", fontsize=9, color=TEXT if v else MUTED, zorder=4)
ax.set_xticks(range(len(layers)))
ax.set_xticklabels([f"{c}\n{d}" for c, d in layers], fontsize=11, color=TEXT)
ax.set_ylim(0, 112)
ax.set_yticks([0, 25, 50, 75, 100])
ax.set_yticklabels([f"{t}%" for t in [0, 25, 50, 75, 100]], fontsize=9, color=MUTED)
ax.grid(axis="y", color=GRID, linewidth=0.8, zorder=0)
for side in ("top", "right", "left"):
    ax.spines[side].set_visible(False)
ax.spines["bottom"].set_color(GRID)
ax.tick_params(length=0)
ax.legend(loc="upper left", ncol=4, frameon=False, fontsize=10, bbox_to_anchor=(0, 1.12), handlelength=1.2)
fp = [S[c]["controls_any_association"] * 100 for c, _ in layers]
ax.set_title("逐层加入居家资料：每类情境的辨识率", loc="left", fontsize=14, color=TEXT, pad=34, fontweight="bold")
fig.text(0.01, 0.01, f"合成病人 400 位、记录 14 天、含漏记与估算误差；无规律对照出现任何关联：A–D 依次 {'/'.join(f'{v:.0f}%' for v in fp)}；"
         "越界用语 0。记录 28 天时高碳水晚餐 90%、散步 72%。", fontsize=8.5, color=MUTED)
fig.tight_layout(rect=(0, 0.04, 1, 1))
out = ROOT / "docs/figures/07_实验G_分层对照.png"
fig.savefig(out, facecolor=SURFACE)
print(out)
