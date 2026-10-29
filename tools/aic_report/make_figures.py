"""AIC·AI+医学竞赛技术报告配图（输出到 tools/aic_report/figures/）。数字取自 docs/MVP2_测试结果.md。
用法：backend\\.venv\\Scripts\\python tools\\aic_report\\make_figures.py
"""
from __future__ import annotations

import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.patches import FancyBboxPatch  # noqa: E402
from PIL import Image  # noqa: E402

sys.stdout.reconfigure(encoding="utf-8")
plt.rcParams["font.family"] = ["Microsoft YaHei"]
plt.rcParams["axes.unicode_minus"] = False

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).parent / "figures"
OUT.mkdir(exist_ok=True)

C_DEV, C_SRV, C_LLM, C_KB, C_GREY = "#2E7D6B", "#3F6FB5", "#C0702A", "#7A5BA6", "#8C959D"


def save(fig, name):
    fig.savefig(OUT / name, dpi=200, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print("已生成", name)


def box(ax, x, y, w, h, text, color, fs=9.5, txt="white", alpha=1.0, ec="none"):
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.015,rounding_size=0.06",
                                fc=color, ec=ec, alpha=alpha, lw=1.2))
    ax.text(x + w / 2, y + h / 2, text, ha="center", va="center", color=txt, fontsize=fs, linespacing=1.35)


def arrow(ax, x1, y1, x2, y2, color="#555", style="-|>", ls="-"):
    ax.annotate("", xy=(x2, y2), xytext=(x1, y1),
                arrowprops=dict(arrowstyle=style, color=color, lw=1.4, linestyle=ls, shrinkA=0, shrinkB=0))


def fig_architecture():
    fig, ax = plt.subplots(figsize=(11, 6.4))
    ax.set_xlim(0, 11)
    ax.set_ylim(0, 6.4)
    ax.axis("off")
    # 分区底色
    for (x, y, w, h, c, label) in [(0.1, 3.55, 10.8, 2.6, C_DEV, "移动端（Flutter，原图不出手机）"),
                                    (0.1, 0.25, 7.2, 3.05, C_SRV, "服务端（FastAPI，部署于边缘计算工作站）"),
                                    (7.5, 0.25, 3.4, 3.05, C_KB, "知识层与外部服务")]:
        ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.01,rounding_size=0.08", fc=c, alpha=0.08, ec=c, lw=1))
        ax.text(x + 0.12, y + h - 0.2, label, fontsize=10, color=c, fontweight="bold", va="top")
    dev = [("拍照/相册/PDF\n质量评估", 0.3), ("PP-OCRv5\n文本检测(DB)", 2.4), ("PP-OCRv5\n文本识别(CTC)", 4.5),
           ("版面解析\n字段结构化", 6.6), ("置信度评估\n原图局部确认", 8.7)]
    for t, x in dev:
        box(ax, x, 4.45, 1.85, 1.0, t, C_DEV)
    for i in range(len(dev) - 1):
        arrow(ax, dev[i][1] + 1.85, 4.95, dev[i + 1][1], 4.95)
    box(ax, 0.3, 3.7, 3.4, 0.55, "加密本地存储 · 老年模式 · 朗读", C_DEV, fs=8.5, alpha=0.85)
    box(ax, 3.9, 3.7, 3.4, 0.55, "仅上传：脱敏结构化指标 + 用户回答", C_GREY, fs=8.5)
    srv = [("指标标准化\n同义词·等级·单位", 0.3, 1.75), ("三值逻辑\n组合规则引擎", 2.65, 1.75), ("动态追问\n（无状态）", 5.0, 1.75),
           ("两层意图识别\n关键词+语义", 0.3, 0.4), ("知识检索\n打分排序", 2.65, 0.4), ("受约束改写\n+输出校验", 5.0, 0.4)]
    for t, x, y in srv:
        box(ax, x, y, 2.05, 0.95, t, C_SRV)
    arrow(ax, 5.6, 3.7, 6.0, 2.72)  # 上传 → 服务端
    arrow(ax, 2.35, 2.22, 2.65, 2.22)
    arrow(ax, 4.7, 2.22, 5.0, 2.22)
    arrow(ax, 3.67, 1.75, 3.67, 1.35)
    arrow(ax, 4.7, 0.87, 5.0, 0.87)
    arrow(ax, 2.35, 0.87, 2.65, 0.87)
    kb = [("指标字典 · 规则库(YAML)\n追问库 · 知识库(附文献)", 1.95, C_KB), ("大模型服务（OpenAI 兼容）\n改写 / 意图分类", 1.12, C_LLM),
          ("访问口令 · 超时回退\n无模型时可完整运行", 0.35, C_GREY)]
    for t, y, c in kb:
        box(ax, 7.7, y, 3.0, 0.68, t, c, fs=8.8)
    arrow(ax, 7.7, 2.25, 7.05, 2.25, color=C_KB, ls="--")
    arrow(ax, 7.7, 1.45, 7.05, 0.95, color=C_LLM, ls="--")
    save(fig, "fig1_architecture.png")


def fig_ocr_flow():
    fig, ax = plt.subplots(figsize=(11, 3.9))
    ax.set_xlim(0, 11)
    ax.set_ylim(0, 3.9)
    ax.axis("off")
    steps = [("图像质量评估\nLaplacian 方差<120 → 模糊\n亮度<60 · 饱和像素>5%", 0.1),
             ("DB 文本检测\n概率图 P>0.3 二值化\n连通域成框 · 框均分≥0.6\n外扩 0.5h", 2.3),
             ("方向判定\n>60% 框竖长 → 旋转\n90°/270° 取置信度高者", 4.5),
             ("CTC 识别\n贪心解码 · 字段置信度\n= 各步最大概率均值", 6.7),
             ("版面解析\n按行中心聚类\n表头定列 · 拆合并单元格", 8.9)]
    for t, x in steps:
        box(ax, x, 2.25, 2.0, 1.45, t, C_DEV, fs=8.6)
    for i in range(len(steps) - 1):
        arrow(ax, steps[i][1] + 2.0, 2.97, steps[i + 1][1], 2.97)
    box(ax, 0.1, 0.25, 4.6, 1.55, "触发局部确认（任一成立）\n置信度<0.85 · 写法不合法 · 单独「+」\n单位缺失 · 超出合理范围 · 阴性却带↑\nUACR 关键定量值一律核对", "#B54848", fs=8.8)
    box(ax, 5.0, 0.25, 3.0, 1.55, "候选生成\n「±」混淆集 {+, ±, 1+, 2+}\n形近字 0/O · 1/I/L · 5/S · 8/B\nUACR 小数点位置候选", C_GREY, fs=8.6)
    box(ax, 8.3, 0.25, 2.6, 1.55, "原图高亮框 + 局部放大\n用户一键选择 / 其他 /\n无法确认（→ 未知）", C_DEV, fs=8.6)
    arrow(ax, 9.9, 2.25, 4.0, 1.8, color="#B54848")
    arrow(ax, 4.7, 1.02, 5.0, 1.02)
    arrow(ax, 8.0, 1.02, 8.3, 1.02)
    save(fig, "fig2_ocr_confirm.png")


def fig_safety():
    fig, ax = plt.subplots(figsize=(11, 3.6))
    ax.set_xlim(0, 11)
    ax.set_ylim(0, 3.75)
    ax.axis("off")
    box(ax, 0.1, 1.35, 1.6, 0.9, "用户提问\n（繁→简统一）", C_GREY, fs=9)
    box(ax, 2.0, 2.25, 2.3, 1.0, "第一层：关键词组合\n对象词×意图词\n报告上下文（酮体阳性）", C_SRV, fs=8.6)
    box(ax, 2.0, 0.3, 2.3, 1.0, "回答草稿\n规则结论 + 检索知识\n（确定性组装）", C_SRV, fs=8.6)
    box(ax, 4.7, 2.25, 2.3, 1.0, "第二层：大模型语义分类\n用药/诊断/紧急/无\n（与改写并行）", C_LLM, fs=8.6)
    box(ax, 4.7, 0.3, 2.3, 1.0, "大模型改写\n只改写草稿\n不得新增结论", C_LLM, fs=8.6)
    box(ax, 7.4, 0.3, 2.0, 1.0, "输出校验\n数值须出自事实 · 禁用表述\n紧急结论须有规则支持", "#B54848", fs=8.4)
    box(ax, 7.4, 2.25, 2.0, 1.0, "安全模板\n就医 / 遵医嘱 / 复诊", "#B54848", fs=8.8)
    box(ax, 9.7, 1.35, 1.2, 0.9, "回答\n+出处", C_DEV, fs=9)
    arrow(ax, 1.7, 1.95, 2.0, 2.7)
    arrow(ax, 1.7, 1.65, 2.0, 0.85)
    arrow(ax, 4.3, 2.75, 4.7, 2.75)
    ax.plot([3.15, 3.15, 8.4], [3.25, 3.45, 3.45], color="#B54848", lw=1.4)
    arrow(ax, 8.4, 3.45, 8.4, 3.25, color="#B54848")
    ax.text(5.8, 3.5, "第一层命中：直接回安全模板", fontsize=8, color="#B54848", ha="center")
    arrow(ax, 7.0, 2.75, 7.4, 2.75, color="#B54848")
    arrow(ax, 4.3, 0.8, 4.7, 0.8)
    arrow(ax, 7.0, 0.8, 7.4, 0.8)
    arrow(ax, 9.4, 0.8, 9.7, 1.5)
    arrow(ax, 9.4, 2.75, 9.7, 2.05)
    ax.text(8.4, 0.08, "不通过 / 超时 15 s → 回退草稿", fontsize=8, color="#B54848", ha="center")
    save(fig, "fig3_safety.png")


def fig_pet():
    fig, ax = plt.subplots(figsize=(11, 3.9))
    ax.set_xlim(0, 11)
    ax.set_ylim(0, 3.9)
    ax.axis("off")
    box(ax, 0.1, 2.35, 2.2, 1.25, "生活打卡\n用药/打针 · 吃饭 · 运动\n睡眠 · 血糖", C_SRV, fs=8.6)
    box(ax, 2.6, 2.35, 2.7, 1.25, "个人规律分析（n-of-1）\n两组中位数差 + 置换检验\n5 条规律 → 复诊问题", C_KB, fs=8.6)
    box(ax, 5.6, 2.35, 2.7, 1.25, "宠物健康 H：只随用药依从\n漏用 −25 · 按时一天 +20\n下限 20（生病可恢复、不死亡）", "#B54848", fs=8.6)
    box(ax, 8.6, 2.35, 2.3, 1.25, "活力 E（指数平滑 λ=0.8）\n运动 · 睡眠 · 记录\n状态切换 ±5 滞回", C_DEV, fs=8.6)
    arrow(ax, 2.3, 2.97, 2.6, 2.97)
    ax.plot([1.2, 1.2, 7.0], [2.35, 2.1, 2.1], color="#555", lw=1.2)
    arrow(ax, 7.0, 2.1, 7.0, 2.35)
    ax.plot([7.0, 9.75], [2.1, 2.1], color="#555", lw=1.2)
    arrow(ax, 9.75, 2.1, 9.75, 2.35)
    box(ax, 0.1, 0.3, 3.5, 1.4, "自适应提醒：Thompson 采样\n每个时段 Beta(α, β)\n提醒后 2 小时内完成 = 成功", C_LLM, fs=8.6)
    box(ax, 3.8, 0.3, 3.6, 1.4, "安全约束：宠物不反映血糖/检验结果\n漏打胰岛素提示「不要自行补打双倍」\n红色风险由界面提示卡传达；可关闭负面反馈", "#8C2F2F", fs=8.4)
    box(ax, 7.6, 0.3, 3.3, 1.4, "数据回流（经同意）\n运动、发热等生活事件\n作为 UACR 暂时升高的判读上下文", C_GREY, fs=8.6)
    save(fig, "fig4_pet.png")


def fig_results():
    fig, axes = plt.subplots(1, 2, figsize=(11, 3.9), gridspec_kw={"width_ratios": [1, 1.25]})
    # (a) 实验 A/B：错误安慰与识别错误
    ax = axes[0]
    labels = ["进入判读的\n识别错误", "错误安慰率\n（未知被当正常）"]
    base, ours = [3.9, 8.5], [0.39, 0]
    x = range(len(labels))
    ax.bar([i - 0.18 for i in x], base, 0.34, color="#B8BEC4", label="对照（自动接受 / 逐项比对）")
    ax.bar([i + 0.18 for i in x], ours, 0.34, color=C_DEV, label="MediLens")
    for i, (b, o) in enumerate(zip(base, ours)):
        ax.text(i - 0.18, b + 0.2, f"{b}%", ha="center", fontsize=9)
        ax.text(i + 0.18, o + 0.2, f"{o:g}%", ha="center", fontsize=9, color=C_DEV, fontweight="bold")
    ax.set_xticks(list(x))
    ax.set_xticklabels(labels, fontsize=9)
    ax.set_ylim(0, 10.5)
    ax.set_ylabel("%（越低越好）", fontsize=9)
    ax.set_title("(a) 局部确认与组合规则（合成测试集）", fontsize=10)
    ax.legend(fontsize=8, frameon=False, loc="upper left")
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    # (b) 实验 D
    ax = axes[1]
    labels = ["感染干扰\n提示召回↑", "附资料\n来源↑", "错误安慰↓", "断定诊断↓"]
    base, ours = [60, 0, 13.3, 18.3], [100, 75, 0, 0]
    x = range(len(labels))
    ax.bar([i - 0.18 for i in x], base, 0.34, color="#B8BEC4", label="同一大模型直接解读")
    ax.bar([i + 0.18 for i in x], ours, 0.34, color=C_DEV, label="MediLens")
    for i, (b, o) in enumerate(zip(base, ours)):
        ax.text(i - 0.18, b + 2, f"{b:g}%", ha="center", fontsize=9)
        ax.text(i + 0.18, o + 2, f"{o:g}%", ha="center", fontsize=9, color=C_DEV, fontweight="bold")
    ax.set_xticks(list(x))
    ax.set_xticklabels(labels, fontsize=9)
    ax.set_ylim(0, 112)
    ax.set_title("(b) 与通用大模型直接解读对照（60 份分层合成报告）", fontsize=10)
    ax.legend(fontsize=8, frameon=False, loc="upper right")
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    fig.tight_layout()
    save(fig, "fig5_results.png")


def fig_screens():
    shots = ["04_局部确认_原图高亮与候选.png", "07_解读总览.png", "13_老年模式_紧急提示置顶.png", "16_小兔_漏药生病.png"]
    caps = ["(a) 原图局部确认", "(b) 解读总览", "(c) 老年模式·紧急置顶", "(d) 小兔陪伴·漏药生病"]
    ims = [Image.open(ROOT / "docs" / "screenshots" / s).convert("RGB") for s in shots]
    h = 900
    ims = [im.resize((int(im.width * h / im.height), h)) for im in ims]
    fig, axes = plt.subplots(1, 4, figsize=(11, 5.2))
    for ax, im, c in zip(axes, ims, caps):
        ax.imshow(im)
        ax.set_title(c, fontsize=10, y=-0.08)
        ax.axis("off")
    fig.tight_layout()
    save(fig, "fig6_screens.png")


if __name__ == "__main__":
    fig_architecture()
    fig_ocr_flow()
    fig_safety()
    fig_pet()
    fig_results()
    fig_screens()
