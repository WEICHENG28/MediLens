"""生成组员版说明文件用的图（docs/figures/*.png）。数字取自 docs/MVP2_测试结果.md 的实测结果。

用法：backend\\.venv\\Scripts\\python tools\\make_team_figures.py   （需要 matplotlib，仅开发用，不属于后端依赖）
"""
from __future__ import annotations

from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.patches import FancyBboxPatch  # noqa: E402

import sys  # noqa: E402

sys.stdout.reconfigure(encoding="utf-8")
plt.rcParams["font.family"] = ["Microsoft YaHei"]
plt.rcParams["axes.unicode_minus"] = False

OUT = Path(__file__).resolve().parents[1] / "docs" / "figures"
OUT.mkdir(parents=True, exist_ok=True)

PHONE, RULE, LLM, GREY = "#2E7D6B", "#3F6FB5", "#C0702A", "#9AA3AB"
BASE, OURS = "#B8BEC4", "#2E7D6B"


def save(fig, name):
    fig.savefig(OUT / name, dpi=160, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print("已生成", (OUT / name).name)


def box(ax, x, y, w, h, text, color, fs=11):
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.02,rounding_size=0.08",
                                fc=color, ec="none", alpha=0.95))
    ax.text(x + w / 2, y + h / 2, text, ha="center", va="center", color="white", fontsize=fs, fontweight="bold")


def arrow(ax, x1, y1, x2, y2):
    ax.annotate("", xy=(x2, y2), xytext=(x1, y1), arrowprops=dict(arrowstyle="-|>", color="#555", lw=1.6))


def flow():
    """使用流程 + 每一步由谁负责（手机 / 规则 / 大模型）。"""
    fig, ax = plt.subplots(figsize=(12, 5.2))
    ax.set_xlim(0, 12)
    ax.set_ylim(0, 5.2)
    ax.axis("off")
    w, h = 2.1, 0.95
    top = [("① 拍照 / 选图", PHONE), ("② 手机本机\n文字识别 (OCR)", PHONE), ("③ 看不清的字段\n请用户确认", PHONE),
           ("④ 规则判读\n红 / 黄 / 绿", RULE)]
    bottom = [("⑧ 保存或不保存\n（本机加密）", PHONE), ("⑦ 提问\n大模型改写 + 安全检查", LLM), ("⑥ 详细了解\n附资料来源", RULE),
              ("⑤ 回答几个\n简单问题", RULE)]
    xs = [0.3, 3.3, 6.3, 9.3]
    for x, (t, c) in zip(xs, top):
        box(ax, x, 3.5, w, h, t, c)
    for x, (t, c) in zip(xs, bottom):
        box(ax, x, 1.6, w, h, t, c)
    for i in range(3):
        arrow(ax, xs[i] + w, 3.5 + h / 2, xs[i + 1], 3.5 + h / 2)
        arrow(ax, xs[i + 1], 1.6 + h / 2, xs[i] + w, 1.6 + h / 2)
    arrow(ax, xs[3] + w / 2, 3.5, xs[3] + w / 2, 1.6 + h)
    for i, (label, c) in enumerate([("在手机上完成（不上传照片）", PHONE), ("后端规则与知识库（结果固定、可追溯）", RULE),
                                    ("大模型（只负责把话说得通顺、判断问题是否越界）", LLM)]):
        ax.add_patch(FancyBboxPatch((0.3 + i * 3.9, 0.35), 0.35, 0.35, boxstyle="round,pad=0.01", fc=c, ec="none"))
        ax.text(0.8 + i * 3.9, 0.52, label, va="center", fontsize=9.5, color="#333")
    ax.text(6, 4.95, "MediLens 一次完整使用流程：每一步由谁负责", ha="center", fontsize=14, fontweight="bold", color="#222")
    save(fig, "01_流程与分工.png")


def bars(name, title, labels, base, ours, base_label, ours_label, note, higher_better):
    fig, ax = plt.subplots(figsize=(9, 0.75 * len(labels) + 1.6))
    y = range(len(labels))
    hgt = 0.36
    ax.barh([i + hgt / 2 for i in y], base, height=hgt, color=BASE, label=base_label)
    ax.barh([i - hgt / 2 for i in y], ours, height=hgt, color=OURS, label=ours_label)
    for i, (b, o) in enumerate(zip(base, ours)):
        ax.text(b + 1, i + hgt / 2, f"{b:g}%", va="center", fontsize=10, color="#555")
        ax.text(o + 1, i - hgt / 2, f"{o:g}%", va="center", fontsize=10, color=OURS, fontweight="bold")
    ax.set_yticks(list(y))
    ax.set_yticklabels([f"{lab}\n（{'越高越好' if hb else '越低越好'}）" for lab, hb in zip(labels, higher_better)], fontsize=10)
    ax.invert_yaxis()
    ax.set_xlim(0, 115)
    ax.set_xticks([])
    for s in ("top", "right", "bottom"):
        ax.spines[s].set_visible(False)
    ax.legend(loc="lower right", frameon=False, fontsize=10)
    ax.set_title(title, fontsize=13, fontweight="bold", loc="left")
    fig.text(0.01, -0.02, note, fontsize=8.5, color="#666")
    save(fig, name)


def kb_flow():
    """知识库如何被使用：检索打分 → 大模型改写 → 检查 → 附出处。"""
    fig, ax = plt.subplots(figsize=(12, 3.6))
    ax.set_xlim(0, 12)
    ax.set_ylim(0.4, 3.6)
    ax.axis("off")
    steps = [("用户提问\n或点「详细了解」", PHONE), ("在知识库打分找资料\n（程序，不是大模型）", RULE),
             ("大模型只根据资料\n改写成口语", LLM), ("安全检查\n不通过就用原稿", RULE), ("显示回答\n+ 出处与审核状态", PHONE)]
    w, h, gap = 2.0, 1.1, 0.4
    for i, (t, c) in enumerate(steps):
        x = 0.2 + i * (w + gap)
        box(ax, x, 1.5, w, h, t, c, fs=10.5)
        if i:
            arrow(ax, x - gap, 1.5 + h / 2, x, 1.5 + h / 2)
    ax.text(0.2 + w + gap + w / 2, 1.25, "指标相同 +2｜关键词 +1\n标题字词重合 +0.5", ha="center", va="top", fontsize=9, color="#333")
    ax.text(0.2 + 2 * (w + gap) + w / 2, 1.25, "没有训练、没有微调", ha="center", va="top", fontsize=9, color="#333")
    ax.text(6, 3.2, "知识库怎么被使用（像开书考试，不用训练）", ha="center", fontsize=14, fontweight="bold", color="#222")
    save(fig, "06_知识库流程.png")


def main():
    flow()
    kb_flow()
    bars("02_实验D_对比直接问大模型.png", "实验 D：同一个大模型，直接问 vs 经过 MediLens",
         ["提醒「感染会让 UACR 偏高」", "错误安慰（看不清却说「总体良好」）", "直接下诊断", "回答附资料来源"],
         [60, 13.3, 18.3, 0], [100, 0, 0, 75], "直接问大模型", "MediLens",
         "60 份合成报告；两边都用 DeepSeek-V4.1-Flash；由另一家模型（Qwen）按固定标准评分。「直接下诊断」评分偏严，可能高估。",
         [True, False, False, True])
    bars("03_实验A_对比逐项解读.png", "实验 A：组合规则 vs 一般「逐项比对参考范围」",
         ["酮症紧急提示", "感染干扰提示", "用药影响解释", "错误安慰（有看不清的项目却显示全部正常）"],
         [0, 0, 0, 8.5], [100, 100, 100, 0], "逐项比对", "MediLens",
         "1000 份随机合成报告。逐项比对本来就没有组合判断功能，所以前三项为 0；差别重点在最后一项。",
         [True, True, True, False])
    bars("04_越界提问拦截.png", "超出范围的提问（问停药、要诊断、危险症状）拦截率",
         ["拦下越界问题", "正常问题被误拦"], [59.1, 0], [90.9, 0], "只用关键词", "关键词 + 大模型判断",
         "第二轮新题：44 句越界问题、16 句正常问题。没拦到的 4 句都是学校平台超过 15 秒没回应。",
         [True, False])
    bars("05_识别错误拦截.png", "拍照识别：错误有没有被拦下来",
         ["识别错误被「请你确认」拦下", "错误悄悄进入判读"], [90.0, 0.39], [100, 0], "改进前（测试集）",
         "加入 UACR 强制核对后（新测试集）", "合成报告；「悄悄进入」以全部字段为分母。代价：需要确认的字段从 11.5% 增加到 20.4%。",
         [True, False])


if __name__ == "__main__":
    main()
