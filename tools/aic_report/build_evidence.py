"""生成比赛「佐证材料」PDF（合并为一个文件，匿名）。

只收录真实存在、可核查的材料：测试与对照实验结果、实验原始记录节选、自动化测试运行记录、界面截图、
部署验证记录、文献核查记录、压缩包完整性（SHA-256）。没有的类型（专利、软著、论文、企业意向书、用户反馈、试点证明）
在最后一节如实说明「暂无」，不虚构。
用法：python tools/aic_report/build_evidence.py <输出目录> <证据数据目录>
  证据数据目录需含 pytest.txt、flutter.txt、ts.txt（由 build 前的命令生成）。
然后用 Word 导出 PDF 并添加书签（见 finish_evidence.py）。
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import re
import sys
from pathlib import Path

import docx
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Pt, RGBColor
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("pkg", ROOT / "tools" / "make_submission_package.py")
pkg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pkg)

TITLE = "MediLens糖尿病尿检报告可信解读"
MATERIALS = [
    ("材料一", "测试与对照实验结果报告", "识别、判读、安全拦截、对照大模型、生活规律的全部实测数据与局限"),
    ("材料二", "对照实验 D 原始记录节选", "同一大模型直接解读与 MediLens 的原始回答及评审判定，可人工复核"),
    ("材料三", "自动化测试运行记录", "后端与客户端单元测试的实际运行结果"),
    ("材料四", "应用界面截图", "已实现功能的实机（模拟器）画面，全部为合成数据"),
    ("材料五", "部署验证记录（2026-10-28）", "后端部署于边缘计算工作站并通过访问口令保护"),
    ("材料六", "知识来源文献核查记录", "引用文献逐篇核对出处与关键数字，发现并更正 16 处引用错误"),
    ("材料七", "代码包与数据集完整性", "上传网盘的压缩包 SHA-256，便于评审核对"),
    ("材料八", "其他类型佐证材料说明", "专利、软著、论文、企业意向书、用户反馈、试点证明的现状"),
]
SYMBOLS = {"✅": "[通过]", "⚠️": "[注意]", "⚠": "[注意]", "❌": "[未达标]", "✓": "√", "✗": "×", "→": "→", "☐": "[ ]"}
FONT_PATH = "C:/Windows/Fonts/msyh.ttc"


# ---------- 文本处理 ----------
def clean(text: str) -> str:
    for a, b in pkg.SCRUB:
        text = re.sub(a, b, text)
    text = text.replace("组员", "团队成员").replace("被老师或评审查出", "被评审查出")
    for a, b in SYMBOLS.items():
        text = text.replace(a, b)
    return text


def set_font(run, size=10.5, bold=None, mono=False, italic=None):
    run.font.size = Pt(size)
    run.font.name = "Courier New" if mono else "Times New Roman"
    rpr = run._element.get_or_add_rPr()
    f = rpr.find(qn("w:rFonts"))
    if f is None:
        f = OxmlElement("w:rFonts")
        rpr.insert(0, f)
    f.set(qn("w:eastAsia"), "宋体")
    run.font.color.rgb = RGBColor(0, 0, 0)
    if bold is not None:
        run.bold = bold
    if italic is not None:
        run.italic = italic


def add_runs(p, text: str, size=10.5, bold=False):
    """解析行内 **粗体**、`代码`、[文字](链接)。"""
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)
    for part in re.split(r"(\*\*[^*]+\*\*|`[^`]+`)", text):
        if not part:
            continue
        if part.startswith("**") and part.endswith("**"):
            set_font(p.add_run(part[2:-2]), size, bold=True)
        elif part.startswith("`") and part.endswith("`"):
            set_font(p.add_run(part[1:-1]), size - 0.5, mono=True)
        else:
            set_font(p.add_run(part.replace("*", "")), size, bold=bold)


def para(doc, text="", size=10.5, bold=False, align=None, indent=False, before=0, after=4, left=0.0):
    p = doc.add_paragraph()
    pf = p.paragraph_format
    pf.space_before, pf.space_after, pf.line_spacing = Pt(before), Pt(after), 1.15
    if indent:
        pf.first_line_indent = Pt(size * 2)
    if left:
        pf.left_indent = Cm(left)
    if align is not None:
        p.alignment = align
    add_runs(p, text, size, bold)
    return p


def heading(doc, text, level):
    sizes = {1: 16, 2: 14, 3: 12}
    p = doc.add_paragraph(style=f"Heading {level}")
    p.paragraph_format.space_before = Pt(10 if level > 1 else 0)
    p.paragraph_format.space_after = Pt(6)
    p.paragraph_format.keep_with_next = True
    set_font(p.add_run(text), sizes[level], bold=True)
    return p


def shade(cell, fill):
    tcpr = cell._element.get_or_add_tcPr()
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), fill)
    tcpr.append(shd)


def table(doc, rows, widths=None, header=True, size=9.5):
    ncol = max(len(r) for r in rows)
    t = doc.add_table(rows=len(rows), cols=ncol)
    t.style = doc.styles["Table Grid"]
    t.alignment = WD_TABLE_ALIGNMENT.CENTER
    t.autofit = False
    if widths is None:
        lens = [max(min(len(r[c]) if c < len(r) else 0, 60) + 4 for r in rows) for c in range(ncol)]
        tot = sum(lens)
        widths = [15.0 * n / tot for n in lens]
    for i, r in enumerate(rows):
        for c in range(ncol):
            cell = t.rows[i].cells[c]
            cell.width = Cm(widths[c])
            cell.text = ""
            p = cell.paragraphs[0]
            p.paragraph_format.space_after = Pt(0)
            p.paragraph_format.line_spacing = 1.1
            if header and i == 0:
                p.alignment = WD_ALIGN_PARAGRAPH.CENTER
                shade(cell, "E6E6E6")
            add_runs(p, r[c] if c < len(r) else "", size, bold=(header and i == 0))
    if header:
        th = OxmlElement("w:tblHeader")
        th.set(qn("w:val"), "true")
        t.rows[0]._tr.get_or_add_trPr().append(th)
    doc.add_paragraph().paragraph_format.space_after = Pt(2)
    return t


def code_block(doc, lines):
    for ln in lines:
        p = doc.add_paragraph()
        p.paragraph_format.space_after = Pt(0)
        p.paragraph_format.left_indent = Cm(0.5)
        set_font(p.add_run(clean(ln) or " "), 9, mono=True)
    doc.add_paragraph().paragraph_format.space_after = Pt(2)


def page_break(doc):
    doc.add_paragraph().add_run().add_break(WD_BREAK.PAGE)


def add_markdown(doc, text: str, base_level=2, keep=None):
    """把 Markdown 转为 Word 内容。keep：只保留标题以这些前缀开头的 `## ` 小节（None 表示全部）。"""
    lines = clean(text).splitlines()
    out, i, in_code, code, skip = [], 0, False, [], False
    seen_h2 = False
    while i < len(lines):
        ln = lines[i]
        if ln.startswith("```"):
            if in_code:
                if not skip:
                    code_block(doc, code)
                code, in_code = [], False
            else:
                in_code = True
            i += 1
            continue
        if in_code:
            code.append(ln)
            i += 1
            continue
        if ln.startswith("## "):
            seen_h2 = True
            skip = keep is not None and not any(ln[3:].startswith(k) for k in keep)
        if keep is not None and not seen_h2:
            i += 1
            continue
        if skip:
            i += 1
            continue
        if ln.startswith("|"):
            rows = []
            while i < len(lines) and lines[i].startswith("|"):
                cells = [c.strip() for c in lines[i].strip().strip("|").split("|")]
                if not all(re.fullmatch(r":?-{2,}:?", c) for c in cells):
                    rows.append(cells)
                i += 1
            table(doc, rows)
            continue
        if ln.startswith("# "):
            pass  # 标题由调用方给出
        elif ln.startswith("## "):
            heading(doc, ln[3:].strip(), 2)
        elif ln.startswith("### "):
            heading(doc, ln[4:].strip(), 3)
        elif ln.startswith("#### "):
            para(doc, ln[5:].strip(), bold=True, before=4)
        elif ln.startswith(">"):
            para(doc, ln.lstrip("> ").strip(), size=9.5, left=0.5)
        elif re.match(r"^\s*[-*] ", ln):
            para(doc, "· " + re.sub(r"^\s*[-*] ", "", ln), left=0.6, after=2)
        elif re.match(r"^\s*\d+\. ", ln):
            para(doc, ln.strip(), left=0.6, after=2)
        elif ln.strip() == "---" or not ln.strip():
            pass
        else:
            para(doc, ln.strip())
        i += 1


# ---------- 图片 ----------
def montage(files: list[tuple[str, str]], out: Path):
    h = 1000
    font = ImageFont.truetype(FONT_PATH, 30)
    ims = []
    for f, cap in files:
        im = Image.open(ROOT / "docs" / "screenshots" / f).convert("RGB")
        ims.append((im.resize((int(im.width * h / im.height), h)), cap))
    gap = 24
    w = sum(i.width for i, _ in ims) + gap * (len(ims) + 1)
    canvas = Image.new("RGB", (w, h + 110), "white")
    d = ImageDraw.Draw(canvas)
    x = gap
    for im, cap in ims:
        canvas.paste(im, (x, 20))
        d.rectangle([x - 1, 19, x + im.width, 20 + im.height], outline=(120, 120, 120), width=2)
        tw = d.textlength(cap, font=font)
        d.text((x + (im.width - tw) / 2, h + 40), cap, fill=(0, 0, 0), font=font)
        x += im.width + gap
    canvas.save(out, optimize=True)


# ---------- 主流程 ----------
def build(out_docx: Path, data: Path, pages: dict | None):
    ts = (data / "ts.txt").read_text(encoding="utf-8").strip()
    pages = pages or {}
    doc = docx.Document()
    s = doc.sections[0]
    s.page_width, s.page_height = Cm(21), Cm(29.7)
    s.top_margin = s.bottom_margin = Cm(2.5)
    s.left_margin = s.right_margin = Cm(3.0)
    doc.styles["Normal"].font.name = "Times New Roman"
    doc.styles["Normal"].element.rPr.rFonts.set(qn("w:eastAsia"), "宋体")

    # 页眉页脚
    hp = s.header.paragraphs[0]
    hp.alignment = WD_ALIGN_PARAGRAPH.RIGHT
    set_font(hp.add_run("MediLens · 佐证材料"), 9)
    fp = s.footer.paragraphs[0]
    fp.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = fp.add_run()
    set_font(r, 9)
    for kind, txt in (("begin", None), (None, " PAGE "), ("end", None)):
        el = OxmlElement("w:fldChar" if kind else "w:instrText")
        if kind:
            el.set(qn("w:fldCharType"), kind)
        else:
            el.set(qn("xml:space"), "preserve")
            el.text = txt
        r._element.append(el)

    # 封面
    for _ in range(5):
        para(doc, "")
    para(doc, "佐证材料", size=28, bold=True, align=WD_ALIGN_PARAGRAPH.CENTER, after=14)
    para(doc, f"作品名称：{TITLE}", size=16, align=WD_ALIGN_PARAGRAPH.CENTER, after=6)
    para(doc, "赛题：AI+医学", size=16, align=WD_ALIGN_PARAGRAPH.CENTER, after=6)
    para(doc, f"整理日期：{ts[:4]}年{int(ts[5:7])}月{int(ts[8:10])}日", size=14, align=WD_ALIGN_PARAGRAPH.CENTER, after=40)
    para(doc, "说明", size=12, bold=True, before=30)
    for t in ("本文件把用于证明作品真实性、创新性与应用成效的材料合并为一个 PDF。",
              "所有测试与评测均基于程序生成的合成数据，不含任何真实患者信息；判读规则与知识库尚未经医学专家审核，文中已如实标注。",
              "材料已匿名处理，不含参赛队伍所属单位及指导人员信息；服务器地址、访问口令与密钥均已隐去。",
              "专利证书、软件著作权证书、论文、企业合作意向书、用户反馈、试点证明目前均暂无，见材料八，不作虚构。"):
        para(doc, "· " + t, left=0.4, after=3)
    page_break(doc)

    # 目录
    heading(doc, "目  录", 1)
    rows = [["编号", "材料名称", "证明内容", "页码"]]
    for k, name, what in MATERIALS:
        rows.append([k, name, what, str(pages.get(k, ""))])
    table(doc, rows, widths=[1.6, 4.6, 7.4, 1.4], size=10)
    page_break(doc)

    # 材料一
    heading(doc, "材料一  测试与对照实验结果报告", 1)
    para(doc, "本材料为项目测试结果的完整记录（合成数据，固定随机种子可复现）。其中「尚未完成的测试」一节如实列出了目前未做的评测。", size=10)
    add_markdown(doc, (ROOT / "docs" / "MVP2_测试结果.md").read_text(encoding="utf-8"))
    heading(doc, "补充：生活规律分析与自适应提醒的模拟评测（2026-10-29）", 2)
    lr = json.loads((ROOT / "tests" / "eval" / "lifestyle_results.json").read_text(encoding="utf-8"))
    para(doc, "每组 100 位模拟患者；「检出」= 对有植入效应的患者输出该规律，「误报」= 对无该效应的患者输出该规律。"
              "模拟模型为验证算法而设的简化模型，不代表真实生理。", size=10)
    rows = [["规律", "植入效应（mmol/L）", "14 天检出 / 误报", "28 天检出 / 误报"]]
    names = {"insulin_timing": "饭后才打餐时胰岛素 → 餐后血糖高", "post_meal_walk": "饭后活动 → 餐后血糖低", "sleep_fasting": "睡眠不足 → 空腹血糖高",
             "evening_exercise_night_low": "晚间运动 → 夜间最低血糖低", "missed_dose_high": "漏用药 → 当日最高血糖高"}
    for k, n in names.items():
        a, b = lr["14天记录"][k], lr["28天记录"][k]
        rows.append([n, str(a["植入效应(mmol/L)"]), f"{a['检出率']:.0%} / {a['误报率']:.0%}", f"{b['检出率']:.0%} / {b['误报率']:.0%}"])
    table(doc, rows)
    bd = lr["自适应提醒30天完成率"]
    para(doc, f"自适应提醒（Thompson 采样）30 天任务完成率 {bd['thompson']:.1%}，随机选择时段 {bd['random']:.1%}，已知最佳时段（理论上限）{bd['已知最佳时段（理论上限）']:.1%}。", size=10)
    page_break(doc)

    # 材料二
    heading(doc, "材料二  对照实验 D 原始记录节选", 1)
    res = json.loads((ROOT / "tests" / "eval" / "exp_d" / "results.json").read_text(encoding="utf-8"))
    para(doc, f"生成模型：{res['生成模型']}（两组相同，推理模式{res['推理模式']}）；评审模型：{res['评审模型']}（另一厂商）。"
              "共 60 份分层合成报告，全部原始回答保存在代码包 tests/eval/exp_d/outputs.json，可人工复核。下面节选 4 个案例，"
              "回答已去除排版符号并截取前 380 字。", size=10)
    outs = json.loads((ROOT / "tests" / "eval" / "exp_d" / "outputs.json").read_text(encoding="utf-8"))

    def pick(bucket, cond):
        return next((o for o in outs if o["bucket"] == bucket and cond(o)), next(o for o in outs if o["bucket"] == bucket))

    cases = [("案例 1：应紧急提示（尿糖+尿酮体阳性）", pick("应紧急提示", lambda o: True)),
             ("案例 2：UACR 升高 + 感染（直接解读漏提感染干扰）", pick("UACR升高+感染", lambda o: not o["baseline_judge"].get("infection_interference"))),
             ("案例 3：含无法确认项（直接解读称整体正常）", pick("含无法确认项", lambda o: o["baseline_judge"].get("says_all_normal"))),
             ("案例 4：其他", pick("其他", lambda o: True))]

    def short(t, n=380):
        t = re.sub(r"[*#`>|]+", " ", clean(t)).replace("\n", " ")
        t = re.sub(r"-{3,}|:-+:?", " ", t)
        t = re.sub(r"\s{2,}", " ", t).strip()
        return t[:n] + ("……（节选）" if len(t) > n else "")

    for title, o in cases:
        heading(doc, title, 3)
        para(doc, "输入：" + short(o["prompt"], 260), size=9.5, left=0.3)
        para(doc, "直接询问大模型的回答：" + short(o["baseline"]), size=9.5, left=0.3)
        para(doc, "MediLens 的回答：" + short(o["medilens"]), size=9.5, left=0.3)
        flags = {"says_all_normal": "称整体正常", "definitive_diagnosis": "断定诊断", "infection_interference": "提示感染干扰", "urgent_care": "提示就医"}
        bj, mj = o["baseline_judge"], o["medilens_judge"]
        rows = [["评审项", "直接解读", "MediLens"]] + [[v, "是" if bj.get(k) else "否", "是" if mj.get(k) else "否"] for k, v in flags.items()]
        table(doc, rows, widths=[6, 4.5, 4.5], size=9.5)
    para(doc, "说明：案例为按「直接解读出现问题」条件挑选，用于说明评审维度，不代表总体比例；总体结果见材料一中的实验 D 表。", size=9.5)
    page_break(doc)

    # 材料三
    heading(doc, "材料三  自动化测试运行记录", 1)
    para(doc, f"运行时间：{ts}（开发电脑，Windows 11）。", size=10)
    heading(doc, "后端（Python 3.11，pytest）", 3)
    code_block(doc, ["cd backend", ".venv/Scripts/python -m pytest -q"] + (data / "pytest.txt").read_text(encoding="utf-8").splitlines()[-1:])
    para(doc, "覆盖：标准化、三值逻辑规则引擎、动态追问、知识检索、解释与对话（含繁体输入、越界拦截、输出校验）、大模型适配器、访问口令、生活规律与宠物。", size=10)
    heading(doc, "客户端（Flutter 3.47，flutter test）", 3)
    code_block(doc, ["cd app", "flutter test"] + [l for l in (data / "flutter.txt").read_text(encoding="utf-8-sig").splitlines() if l.strip()][-1:])
    para(doc, "覆盖：报告解析器（用合成报告的真实 OCR 输出）、页面渲染、老年模式字号与点击区域、设置存储。另有模拟器端到端集成测试（普通与老年模式各一遍）与计时测试，结果见材料一。", size=10)
    page_break(doc)

    # 材料四
    heading(doc, "材料四  应用界面截图", 1)
    para(doc, "截图来自 Android 模拟器（Android 15）实机运行，报告均为程序生成的合成示例，图上带「合成测试样本」水印。", size=10)
    tmp = data / "montage"
    tmp.mkdir(exist_ok=True)
    montage([("04_局部确认_原图高亮与候选.png", "①原图局部确认"), ("07_解读总览.png", "②解读总览"),
             ("09_详细了解原位展开.png", "③详细了解"), ("10_文字对话_越界问题安全回复.png", "④越界提问安全回复")], tmp / "a.png")
    montage([("08_动态选择题.png", "⑤动态追问"), ("13_老年模式_紧急提示置顶.png", "⑥老年模式·紧急置顶"),
             ("15_生活打卡_小兔陪伴.png", "⑦生活打卡·小兔"), ("16_小兔_漏药生病.png", "⑧漏药小兔生病")], tmp / "b.png")
    for n, cap in (("a", "图 1  识别确认、解读与安全拦截"), ("b", "图 2  追问、老年模式、生活打卡与陪伴宠物")):
        p = doc.add_paragraph()
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        p.add_run().add_picture(str(tmp / f"{n}.png"), width=Cm(15))
        para(doc, cap, size=10, bold=True, align=WD_ALIGN_PARAGRAPH.CENTER)
    page_break(doc)

    # 材料五
    heading(doc, "材料五  部署验证记录（2026-10-28）", 1)
    para(doc, "后端部署在 Ubuntu 22.04 边缘计算工作站（Python 3.10，无 GPU），开机自启；以下为部署当日的验证输出（服务器地址与访问口令已隐去）。", size=10)
    code_block(doc, [
        "GET  /api/v1/health",
        '{"status":"ok","service":"medilens","test_rules":true,"llm_provider":"compat"}',
        "",
        "POST /api/v1/analyze   （不带访问口令）",
        "HTTP 401",
        "",
        "POST /api/v1/analyze   （带访问口令，示例报告：尿糖 2+、尿酮体 1+）",
        "总体判断：建议尽快就医",
        "命中规则：R-01 尿糖与尿酮体同时阳性；R-06 尿蛋白阴性但近一年没有 UACR 记录",
    ])
    para(doc, "说明：访问口令保护使同一网络内未持口令者无法调用解读接口；大模型密钥只保存在服务器配置文件中。部署脚本无需管理员权限，仅依赖国内镜像。", size=10)
    page_break(doc)

    # 材料六
    heading(doc, "材料六  知识来源文献核查记录", 1)
    para(doc, "团队成员整理了三份文献资料（共 42 篇）。开发组用 PubMed / Europe PMC 逐篇核对作者、期刊、年份、卷期，并抽查摘要中的关键数字，"
              "核查后才将可用内容改写为知识库条目（每条附出处并标注「未经医学审核」）。", size=10)
    add_markdown(doc, (ROOT / "docs" / "组员资料核查与知识库建议.md").read_text(encoding="utf-8"), keep=("一、", "二、", "参考文献"))
    page_break(doc)

    # 材料七
    heading(doc, "材料七  代码包与数据集完整性", 1)
    para(doc, "上传至网盘的两个压缩包及其 SHA-256，评审下载后可核对文件未被改动。", size=10)
    zdir = Path(sys.argv[3]) if len(sys.argv) > 3 else ROOT
    rows = [["文件名", "大小", "SHA-256"]]
    for p in sorted(zdir.glob("*.zip")):
        h = hashlib.sha256(p.read_bytes()).hexdigest()
        rows.append([p.name, f"{p.stat().st_size / 1e6:.1f} MB", h[:32] + "\n" + h[32:]])
    table(doc, rows, widths=[6.5, 1.8, 6.7], size=8.5)
    para(doc, "文件名中的团队编号以报名系统分配为准。", size=9.5)
    page_break(doc)

    # 材料八
    heading(doc, "材料八  其他类型佐证材料说明", 1)
    para(doc, "按赛方列举的类型，本作品目前的实际情况如下（如实说明，不作虚构）：", size=10)
    table(doc, [["类型", "现状"],
                ["专利证书", "暂无"],
                ["软件著作权证书", "暂无（可申请，尚未提交）"],
                ["论文录用 / 发表证明", "暂无"],
                ["企业合作意向书", "暂无"],
                ["用户反馈", "暂无正式用户测试；团队内部试用意见仅用于改进，不作为佐证"],
                ["试点应用证明", "暂无；真实报告测试需先经伦理审批与授权脱敏，已列入后续计划"],
                ["已具备的可核查材料", "材料一至材料七：实测数据、原始记录、测试运行记录、界面截图、部署验证、文献核查、压缩包校验值"]], widths=[4.5, 10.5], size=10)
    out_docx.parent.mkdir(parents=True, exist_ok=True)
    doc.save(str(out_docx))

    # 敏感字样检查（只检查文字）
    text = "\n".join(p.text for p in doc.paragraphs) + "\n".join(c.text for t in doc.tables for r in t.rows for c in r.cells)
    bad = pkg.SENSITIVE.findall(text)
    generic = re.findall(r".{0,12}(?:学校|老师|教师).{0,12}", text)
    if bad or generic:
        print("⚠ 含敏感字样：", bad, generic)
        sys.exit(1)
    print("已生成", out_docx, "| 敏感字样检查：通过")


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    outp, data = Path(sys.argv[1]), Path(sys.argv[2])
    pages_file = data / "pages.json"
    build(outp, data, json.loads(pages_file.read_text(encoding="utf-8")) if pages_file.exists() else None)
