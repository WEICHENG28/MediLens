"""AIC 半决赛答辩 PPT：版式统一与视觉动线简化（在 build_semifinal_ppt.py 产出的版本上调整，不改内容结论）。

评审反馈：内容不错，但每页排版不太一致、视觉动线太复杂。本程序：
- 统一：所有内容页与附录页的标题位置与字号、资料来源行位置、底部评分项导航、页码；
  第 13 页卡片改为与第 2 页相同的「编号圆 + 标题 + 说明」样式；附录小标题统一位置。
- 简化：第 5、6、8、10 页原为细节很多的流程图图片（多行、交叉箭头、小字），
  改为一行由左到右的步骤（每步一个标题 + 一句说明），并把与图重复的说明卡片合并进步骤里；
  第 12 页右侧说明改成与其他页一致的卡片；第 18 页避免文字与「谢谢」重叠。
用法：tools/.venv/Scripts/python tools/aic_report/polish_semifinal_ppt.py <输入.pptx> <输出.pptx>
"""
import copy
import sys

from lxml import etree
from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_SHAPE
from pptx.enum.text import MSO_ANCHOR, PP_ALIGN
from pptx.util import Emu, Inches, Pt

SRC, OUT = sys.argv[1], sys.argv[2]
prs = Presentation(SRC)
S = list(prs.slides)
FONT = "Microsoft YaHei"
TITLE_C, PRIMARY, CARD, BODY, MUTED = "0E3B43", "1F7A6E", "EEF5F4", "1F2A2E", "6E7D83"
ARROW, ALERT, ALERT_BG = "9FC9C2", "B23A2E", "FBEDEB"
NAV_ON, NAV_OFF = PRIMARY, "EEF4F3"
NAV = ["创新性", "需求与背景", "AI 技术应用", "实施与规范", "研究成效", "总结与展望"]
# 页码 → 所属评分项（附录页标在其补充的评分项上；参考文献不标）
SECTION = {2: 0, 3: 1, 4: 1, 5: 2, 6: 2, 7: 2, 8: 2, 9: 2, 10: 2, 11: 3, 12: 3, 13: 3, 14: 4, 15: 4, 16: 4, 17: 5,
           19: 2, 20: 2, 21: 2, 22: 4, 23: 4, 24: None, 25: None}
E = 914400


def inch(v):
    return Emu(int(v * E))


# ---------- 基本绘图 ----------
def box(sl, x, y, w, h, fill, shape=MSO_SHAPE.ROUNDED_RECTANGLE, radius=0.08, name=None):
    sh = sl.shapes.add_shape(shape, inch(x), inch(y), inch(w), inch(h))
    sh.fill.solid()
    sh.fill.fore_color.rgb = RGBColor.from_string(fill)
    sh.line.fill.background()
    sh.shadow.inherit = False
    if shape == MSO_SHAPE.ROUNDED_RECTANGLE:
        sh.adjustments[0] = radius
    if name:
        sh.name = name
    return sh


def text(sl, x, y, w, h, lines, size=14, color=BODY, bold=False, align=PP_ALIGN.LEFT, anchor=MSO_ANCHOR.TOP, space=4, line=None):
    """lines：字符串（\n 分段）或 [(文字, 字号, 颜色, 粗体)] 段落列表。"""
    tb = sl.shapes.add_textbox(inch(x), inch(y), inch(w), inch(h))
    tf = tb.text_frame
    tf.word_wrap = True
    tf.vertical_anchor = anchor
    tf.margin_left = tf.margin_right = Inches(0.02)
    tf.margin_top = tf.margin_bottom = Inches(0.02)
    if isinstance(lines, str):
        lines = [(t, size, color, bold) for t in lines.split("\n")]
    for i, (t, sz, c, b) in enumerate(lines):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.alignment = align
        p.space_after = Pt(space)
        if line:
            p.line_spacing = line  # 与原卡片说明相近的行距
        r = p.add_run()
        r.text = t
        f = r.font
        f.size, f.bold, f.name = Pt(sz), b, FONT
        f.color.rgb = RGBColor.from_string(c)
        rpr = r._r.get_or_add_rPr()
        ea = rpr.find("{http://schemas.openxmlformats.org/drawingml/2006/main}ea")
        if ea is None:
            ea = etree.SubElement(rpr, "{http://schemas.openxmlformats.org/drawingml/2006/main}ea")
        ea.set("typeface", FONT)
    return tb


def arrow(sl, x, y, w=0.32, h=0.34):
    a = sl.shapes.add_shape(MSO_SHAPE.CHEVRON, inch(x), inch(y), inch(w), inch(h))
    a.fill.solid()
    a.fill.fore_color.rgb = RGBColor.from_string(ARROW)
    a.line.fill.background()
    a.shadow.inherit = False
    return a


def num(sl, x, y, n, d=0.5, fill=PRIMARY, color="FFFFFF"):
    box(sl, x, y, d, d, fill, shape=MSO_SHAPE.OVAL)
    text(sl, x, y, d, d, str(n), size=16, color=color, bold=True, align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE, space=0)


def remove(sh):
    sh._element.getparent().remove(sh._element)


def find(sl, starts):
    for sh in sl.shapes:
        if sh.has_text_frame and sh.text_frame.text.strip().startswith(starts):
            return sh
    raise KeyError(starts)


def pos(sh):
    return sh.left / E, sh.top / E, sh.width / E, sh.height / E


def remove_where(sl, pred):
    for sh in list(sl.shapes):
        if pred(sh):
            remove(sh)


def steps(sl, x, y, total_w, h, items, gap=0.42, highlight=None, body_size=13):
    """一行由左到右的步骤卡片：编号圆 + 标题 + 说明；步骤之间以小箭头连接。"""
    n = len(items)
    w = (total_w - gap * (n - 1)) / n
    for i, (title, desc) in enumerate(items):
        bx = x + i * (w + gap)
        hi = highlight == i
        box(sl, bx, y, w, h, PRIMARY if hi else CARD)
        num(sl, bx + 0.18, y + 0.2, i + 1, d=0.42, fill="FFFFFF" if hi else PRIMARY, color=PRIMARY if hi else "FFFFFF")
        text(sl, bx + 0.18, y + 0.72, w - 0.32, 0.5, title, size=16, color="FFFFFF" if hi else TITLE_C, bold=True)
        c = "FFFFFF" if hi else BODY
        lines = [(desc, body_size, c, False)] if isinstance(desc, str) else [(t, sz, "FFFFFF" if hi else col, False) for t, sz, col in desc]
        text(sl, bx + 0.18, y + 1.22, w - 0.32, h - 1.32, lines, space=3, line=1.35)
        if i < n - 1:
            arrow(sl, bx + w + (gap - 0.24) / 2, y + h / 2 - 0.17, w=0.24)
    return w


# ---------- 1. 全页统一：标题、来源行、导航、页码 ----------
nav_tpl = [copy.deepcopy(sh._element) for sh in S[1].shapes if sh.top / E > 7.05 and sh.name != "Slide Number Placeholder"]
num_tpl = next(copy.deepcopy(sh._element) for sh in S[1].shapes if sh.name.startswith("Slide Number"))
TITLE_BOX = (0.60, 0.35, 12.10, 0.80)


def unify_title(sl):
    title = min((sh for sh in sl.shapes if sh.has_text_frame and sh.text_frame.text.strip() and sh.top / E < 0.6),
                key=lambda s: s.top)
    title.left, title.top, title.width, title.height = (inch(v) for v in TITLE_BOX)
    tf = title.text_frame
    tf.vertical_anchor = MSO_ANCHOR.MIDDLE
    tf.word_wrap = True
    for p in tf.paragraphs:
        for r in p.runs:
            r.font.size, r.font.bold, r.font.name = Pt(30), True, FONT
            rpr = r._r.get_or_add_rPr()
            ea = rpr.find("{http://schemas.openxmlformats.org/drawingml/2006/main}ea")
            if ea is None:
                ea = etree.SubElement(rpr, "{http://schemas.openxmlformats.org/drawingml/2006/main}ea")
            ea.set("typeface", FONT)
            r.font.color.rgb = RGBColor.from_string(TITLE_C)
    return title


def unify_footer(idx, sl):
    sec = SECTION[idx]
    # 删除原导航（标准版在 y≈7.1；附录旧版为右下角小字，y≈6.9）
    remove_where(sl, lambda sh: sh.top / E > 7.05 and not sh.name.startswith("Slide Number"))
    remove_where(sl, lambda sh: sh.has_text_frame and sh.text_frame.text.strip() in NAV and sh.top / E > 6.8)
    for sh in sl.shapes:
        if sh.name.startswith("Slide Number"):
            remove(sh)
    tree = sl.shapes._spTree
    for el in nav_tpl:
        tree.append(copy.deepcopy(el))
    nav = [sh for sh in sl.shapes if sh.top / E > 7.05]
    rects = sorted([s for s in nav if not s.has_text_frame or not s.text_frame.text.strip()], key=lambda s: s.left)
    labels = sorted([s for s in nav if s.has_text_frame and s.text_frame.text.strip()], key=lambda s: s.left)
    for i, (rc, lb) in enumerate(zip(rects, labels)):
        on = i == sec
        rc.fill.solid()
        rc.fill.fore_color.rgb = RGBColor.from_string(NAV_ON if on else NAV_OFF)
        for r in lb.text_frame.paragraphs[0].runs:
            r.font.color.rgb = RGBColor.from_string("FFFFFF" if on else MUTED)
            r.font.bold = on
    tree.append(copy.deepcopy(num_tpl))
    # 来源行：统一放在导航上方同一位置
    for sh in sl.shapes:
        if sh.has_text_frame and 6.6 < sh.top / E < 7.0 and not sh.name.startswith("Slide Number"):
            sh.left, sh.top, sh.width, sh.height = inch(0.67), inch(6.76), inch(12.0), inch(0.22)


for idx, sl in enumerate(S, 1):
    if idx in SECTION:
        unify_title(sl)
        unify_footer(idx, sl)

# 附录页的小标题（原在 y≈0.94，与统一后的标题重叠）
for idx in (19, 20, 21, 22):
    sub = next(sh for sh in S[idx - 1].shapes if sh.has_text_frame and 0.85 < sh.top / E < 1.0)
    sub.left, sub.top, sub.width, sub.height = inch(0.62), inch(1.08), inch(12.0), inch(0.36)

# ---------- 2. 第 13 页：卡片样式与第 2 页一致 ----------
sl = S[12]
cards = sorted([sh for sh in sl.shapes if sh.name.startswith("Rounded Rectangle") and 1.0 < sh.top / E < 6.0],
               key=lambda s: (round(s.top / E, 1), s.left))
heads = sorted([sh for sh in sl.shapes if sh.has_text_frame and sh.text_frame.text.strip()[:2] in ("01", "02", "03", "04")],
               key=lambda s: s.text_frame.text)
bodies = []
for h in heads:
    hx, hy, _, _ = pos(h)
    bodies.append(min((sh for sh in sl.shapes if sh.has_text_frame and sh is not h and abs(sh.left / E - hx) < 0.05 and sh.top / E > hy),
                      key=lambda s: s.top))
GRID = [(0.60, 1.40), (6.75, 1.40), (0.60, 4.10), (6.75, 4.10)]
texts = []
for c, h, b in zip(cards, heads, bodies):
    texts.append((h.text_frame.text.strip()[2:].strip(), b.text_frame.text.strip()))
    remove(c); remove(h); remove(b)
for i, ((x, y), (t, d)) in enumerate(zip(GRID, texts), 1):
    box(sl, x, y, 5.95, 2.45, CARD)
    num(sl, x + 0.2, y + 0.2, i)
    text(sl, x + 0.85, y + 0.22, 4.9, 0.5, t, size=18, color=TITLE_C, bold=True)
    text(sl, x + 0.25, y + 0.93, 5.6, 1.4, d, size=14, line=1.5)
# 两行来源说明合并为一行
dup = find(sl, "设计依据")
remove(dup)
set_src = find(sl, "规范依据")
set_src.text_frame.paragraphs[0].runs[0].text = "设计与规范依据：本项目技术报告“部署、隐私与安全”“数据说明”；产品尚未进行临床效果验证，真实数据测试须经授权与必要的伦理审查。"
for r in set_src.text_frame.paragraphs[0].runs[1:]:
    r.text = ""

# ---------- 3. 第 5 页：技术架构改为三栏 ----------
sl = S[4]
remove_where(sl, lambda sh: 1.2 < sh.top / E < 6.5 and sh.left / E < 12.8 and not sh.name.startswith("Slide Number"))
cols = [
    ("手机端", "原图不出手机", ["拍照与图像质量评估", "本地文字识别与版面解析", "重点字段请用户核对"], "只上传用户确认后的指标"),
    ("服务端", "医学规则负责判断", ["指标标准化", "组合规则判读（三值逻辑）", "检索知识，生成回答草稿"], "无大模型时仍可完整运行"),
    ("大模型", "受控辅助，不下结论", ["识别越界提问", "从固定工具中挑选资料", "通俗改写，并经输出校验"], "校验不通过即退回规则草稿"),
]
cw, gap, cy, ch = 3.6, 0.65, 1.40, 4.25
for i, (head, sub, items, foot) in enumerate(cols):
    x = 0.6 + i * (cw + gap)
    box(sl, x, cy, cw, ch, CARD)
    num(sl, x + 0.22, cy + 0.22, i + 1)
    text(sl, x + 0.85, cy + 0.2, cw - 1.0, 0.5, head, size=20, color=TITLE_C, bold=True)
    text(sl, x + 0.85, cy + 0.68, cw - 1.0, 0.4, sub, size=13, color=PRIMARY, bold=True)
    for j, it in enumerate(items):
        iy = cy + 1.3 + j * 0.72
        box(sl, x + 0.22, iy, cw - 0.44, 0.58, "FFFFFF", radius=0.2)
        text(sl, x + 0.38, iy, cw - 0.7, 0.58, it, size=14, color=BODY, anchor=MSO_ANCHOR.MIDDLE, space=0)
    text(sl, x + 0.22, cy + 3.55, cw - 0.44, 0.5, foot, size=13, color=MUTED)
    if i < 2:
        arrow(sl, x + cw + 0.2, cy + ch / 2 - 0.2, w=0.25, h=0.4)
box(sl, 0.6, 5.85, 12.1, 0.62, PRIMARY, radius=0.2)
text(sl, 0.85, 5.85, 11.6, 0.62, "风险结论只来自可审核、可版本化的医学规则（YAML）；知识库每条资料附出处，大模型不得新增结论", size=15,
     color="FFFFFF", bold=True, anchor=MSO_ANCHOR.MIDDLE, space=0)

# ---------- 4. 第 6 页：识别流程改为一行五步 ----------
sl = S[5]
remove(next(sh for sh in sl.shapes if sh.shape_type == 13 and sh.top / E < 1.5 and sh.left / E < 1))
steps(sl, 0.6, 1.40, 8.9, 3.2, [
    ("图像质量", "模糊、反光、暗光时提示重拍"),
    ("文字检测", "DB 模型找出文字区域"),
    ("文字识别", "CTC 识别文字与数值"),
    ("版面解析", "按行配对指标、结果与参考范围"),
    ("重点复核", "低置信度或关键字段请用户确认"),
], gap=0.32, highlight=4, body_size=13)

f = find(sl, "R(f)")
for p in f.text_frame.paragraphs:
    for r in p.runs:
        r.font.size = Pt(12)

# ---------- 5. 第 8 页：回答生成改为一条主线 + 一道安全关 ----------
sl = S[7]
remove_where(sl, lambda sh: 1.2 < sh.top / E < 6.6 and not sh.name.startswith("Slide Number"))
box(sl, 0.6, 1.40, 12.1, 0.95, ALERT_BG, radius=0.15)
text(sl, 0.85, 1.40, 2.6, 0.95, "先过安全关", size=18, color=ALERT, bold=True, anchor=MSO_ANCHOR.MIDDLE, space=0)
text(sl, 3.1, 1.40, 9.4, 0.95, [
    ("关键词 + 大模型语义分类，与回答生成同时进行；停药、诊断、急症等提问直接回到固定安全模板", 14, BODY, False),
    ("此前版本模拟测试：拦截率 59.1%（仅关键词）→ 90.9%（加语义识别）；模型参数与校验规则已调整，当前版本待复验", 12, MUTED, False),
], anchor=MSO_ANCHOR.MIDDLE, space=2)
steps(sl, 0.6, 2.65, 12.1, 3.7, [
    ("检索依据", [("按指标代码、关键词与标题为知识打分，取最相关的资料", 13, BODY), ("s(e,q) = 2|C_q∩C_e| + Σ1[k∈q] + 0.5|B(q)∩B(t)|", 10.5, MUTED)]),
    ("规则草稿", "报告事实、规则结论与知识原文组成草稿；结论只来自规则"),
    ("大模型改写", "只调整措辞，让说明更易懂；不允许补充新结论或数值"),
    ("输出校验", "数值须有来源；不得擅自诊断或建议停药；紧急提示须有规则依据。不通过或超时即退回草稿"),
], gap=0.42, body_size=13)

# ---------- 6. 第 10 页：生活管理改为一行四步 ----------
sl = S[9]
remove_where(sl, lambda sh: 1.2 < sh.top / E < 6.6 and sh.left / E < 10.3 and not sh.name.startswith("Slide Number"))
steps(sl, 0.6, 1.40, 9.4, 3.9, [
    ("生活打卡", "用药、血糖、饮食、运动、睡眠，一键记录"),
    ("个人规律分析", "比较不同生活习惯下的血糖记录，找出相关线索，整理成复诊问题；不提供用药剂量建议"),
    ("珍珠鸟陪伴", "打卡、血糖达标时开心；超出目标或久未记录时温和关心。不责备、可关闭，不代表真实病情"),
    ("个性化提醒", "根据以往完成任务的时间（Thompson 采样），逐步调整提醒时段"),
], gap=0.36, body_size=13)
box(sl, 0.6, 5.6, 9.4, 0.9, PRIMARY, radius=0.2)
text(sl, 0.85, 5.6, 8.95, 0.9, "安全边界：风险提示仍由报告的规则提示卡传达；珍珠鸟不做医学判断，负面反馈可关闭", size=14,
     color="FFFFFF", bold=True, anchor=MSO_ANCHOR.MIDDLE, space=0)

# ---------- 7. 第 12 页：右侧说明改为卡片 ----------
sl = S[11]
desc = find(sl, "移动端")
items = [p.text.strip() for p in desc.text_frame.paragraphs if p.text.strip()]
remove(desc)
box(sl, 9.45, 1.34, 3.25, 4.81, CARD)
text(sl, 9.67, 1.5, 2.9, 0.45, "实现要点", size=18, color=TITLE_C, bold=True)
text(sl, 9.67, 2.05, 2.9, 4.0, [(t, 12, BODY, False) for t in items], space=6, line=1.3)

# ---------- 8. 第 18 页：结语与「谢谢」不重叠 ----------
sl = S[17]
lim = find(sl, "当前评测")
lim.top, lim.height = inch(3.55), inch(2.0)
for p in lim.text_frame.paragraphs:
    p.space_after = Pt(4)
    for r in p.runs:
        r.font.size = Pt(16)
thanks = find(sl, "谢谢")
thanks.top = inch(6.0)

prs.save(OUT)
print("saved", OUT, len(prs.slides))
