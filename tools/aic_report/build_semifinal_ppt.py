"""AIC 半决赛答辩 PPT：在组员修改后的答辩 PPT 上调整（不重画版式）。

- 依评分表顺序重排：创新性 → 需求与背景 → AI 技术应用 → 实施与规范 → 研究成效 → 总结与展望；附加材料单独一页。
- 底部导航改为评分项名称；录制只讲到「谢谢」页，算法细化、消融对照、参考文献移到其后作附录（评审翻阅可见）。
- 新增「受控工具调用」与「附加材料」两页；更新创新点、珍珠鸟、系统实现、下一步与局限；重写每页讲稿（约 5 分钟）。
用法：tools/.venv/Scripts/python tools/aic_report/build_semifinal_ppt.py <组员版.pptx> <输出.pptx> <讲稿.md> <珍珠鸟截图.png>
"""
import copy
import re
import sys

from pptx import Presentation
from pptx.dml.color import RGBColor

SRC, OUT, SCRIPT = sys.argv[1], sys.argv[2], sys.argv[3]
SHOT = sys.argv[4]  # 珍珠鸟生活页的手机截图（1080×2400）

prs = Presentation(SRC)
S = list(prs.slides)  # 原始顺序，S[0] 为第 1 页
NAV = ["创新性", "需求与背景", "AI 技术应用", "实施与规范", "研究成效", "总结与展望"]
ON_FILL, OFF_FILL, ON_TXT, OFF_TXT = "1F7A6E", "EEF4F3", "FFFFFF", "6E7D83"


# ---------- 工具 ----------
def shape(slide, starts):
    for sh in slide.shapes:
        if sh.has_text_frame and sh.text_frame.text.strip().startswith(starts):
            return sh
    raise KeyError(starts)


def set_text(sh, text):
    """保留第一个文字段的格式，换成新文字（可多行，每行一段）。"""
    tf = sh.text_frame
    p0 = tf.paragraphs[0]
    for p in tf.paragraphs[1:]:
        p._p.getparent().remove(p._p)
    for r in p0.runs[1:]:
        r._r.getparent().remove(r._r)
    lines = text.split("\n")
    p0.runs[0].text = lines[0]
    for line in lines[1:]:
        np_ = copy.deepcopy(p0._p)
        tf._txBody.append(np_)
        runs = np_.findall(".//{http://schemas.openxmlformats.org/drawingml/2006/main}t")
        runs[0].text = line
        for extra in runs[1:]:
            extra.text = ""


def replace(slide, starts, text):
    set_text(shape(slide, starts), text)


def duplicate(src):
    new = prs.slides.add_slide(src.slide_layout)
    for sh in list(new.shapes):
        sh._element.getparent().remove(sh._element)
    for sh in src.shapes:
        el = copy.deepcopy(sh._element)
        # 组员用的排版插件在每个形状上留有 tags 引用（custDataLst），复制到新页后会指向不存在的文件、使文件损坏，故去掉
        for tag in el.findall(".//{http://schemas.openxmlformats.org/presentationml/2006/main}custDataLst"):
            tag.getparent().remove(tag)
        new.shapes._spTree.insert_element_before(el, "p:extLst")
    return new


def replace_phone_picture(slide, which=-1):
    """把竖向（手机截图）图片换成新的截图，位置与大小不变。"""
    pics = [sh for sh in slide.shapes if sh.shape_type == 13 and sh.height > sh.width]
    old = pics[which]
    new = slide.shapes.add_picture(SHOT, old.left, old.top, old.width, old.height)
    old._element.addprevious(new._element)
    old._element.getparent().remove(old._element)


def nav(slide, active):
    """底部 6 个导航标签改为评分项；active 为高亮的序号（None 表示不高亮，例如附录）。"""
    E = 914400
    pills = sorted([sh for sh in slide.shapes if sh.shape_type == 1 and sh.top > 6.4 * E and sh.height < 0.4 * E and 0.3 * E < sh.width < 2.1 * E],
                   key=lambda s: s.left)
    labels = sorted([sh for sh in slide.shapes if sh.shape_type == 17 and sh.top > 6.4 * E and sh.height < 0.3 * E and 0.3 * E < sh.width < 2.1 * E],
                    key=lambda s: s.left)
    if len(labels) == 6 and len(pills) <= 1:
        # 附录页的小型导航：只有当前项有底色；附录不属于评分项，去掉底色、统一改名
        for pl in pills:
            pl._element.getparent().remove(pl._element)
        for i, t in enumerate(labels):
            set_text(t, NAV[i])
            r = t.text_frame.paragraphs[0].runs[0]
            r.font.color.rgb = RGBColor.from_string(OFF_TXT)
            r.font.bold = False
        return
    if len(pills) != 6 or len(labels) != 6:
        return
    for i, (p, t) in enumerate(zip(pills, labels)):
        on = i == active
        p.fill.solid()
        p.fill.fore_color.rgb = RGBColor.from_string(ON_FILL if on else OFF_FILL)
        set_text(t, NAV[i])
        r = t.text_frame.paragraphs[0].runs[0]
        r.font.color.rgb = RGBColor.from_string(ON_TXT if on else OFF_TXT)
        r.font.bold = on


def title(slide, text):
    for sh in slide.shapes:
        if sh.is_placeholder and sh.placeholder_format.type == 1 or (sh.is_placeholder and sh.placeholder_format.idx == 0):
            set_text(sh, text)
            return
    set_text(list(slide.shapes)[0], text)


def notes(slide, text):
    slide.notes_slide.notes_text_frame.text = text


# ---------- 内容修改 ----------
# 第 19 页 创新点
s = S[18]
title(s, "创新性：围绕可信解读与长期管理的四项设计")
replace(s, "医学规则与大模型协同解释框架", "规则下结论、大模型受控调用工具")
replace(s, "构建医学规则判读与大模型受约束表达", "风险结论只由可审核的规则决定；大模型只负责读懂问题、从固定工具中挑选资料并组织语言，输出经校验、来源可追溯。")
replace(s, "任务驱动的虚拟宠物陪伴机制", "珍珠鸟陪伴的长期自我管理")
replace(s, "设计健康任务与宠物互动相联系", "打卡、血糖达标时开心，超出目标或久未记录时温和关心、不责备；结合个人规律分析与自适应提醒，支持长期依从。")

# 第 12 页 生活规律与陪伴
s = S[11]
title(s, "算法④ 生活规律分析与珍珠鸟陪伴")
replace(s, "虚拟宠物健康陪伴", "珍珠鸟健康陪伴")
replace(s, "漏做任务时，小兔以温和方式提醒", "打卡、血糖达标时开心；超出范围或久未记录时温和关心，不责备、可关闭，不代表真实病情。")
replace_phone_picture(s)

# 第 17 页 系统实现
s = S[16]
title(s, "系统实现：Android 应用、服务端与安全设计")
replace(s, "生活打卡·小兔", "生活打卡·珍珠鸟")
replace_phone_picture(s)
replace(s, "移动端：", "移动端：Flutter 开发 Android 应用，报告文字在手机本地识别，原图不上传\n"
        "服务端：FastAPI 部署于边缘计算工作站，访问口令验证\n"
        "账户与传输：用户名＋密码账户、HTTPS 与证书钉选（已开发，待部署）\n"
        "扩展功能：语音提问、复查提醒、拍餐饮估算糖与碳水\n"
        "稳定性：大模型不可用时自动退回规则说明，功能完整\n"
        "质量：后端 223 项、客户端 190 项自动化测试通过")

# 第 20 页 下一步
s = S[19]
title(s, "总结与展望：从模拟测试走向真实应用")
replace(s, "完成审批与授权后", "完成伦理审批与授权后，用不少于 100 份脱敏真实报告测试；开展患者与家属问卷访谈（一手需求调研）；邀请医学专家审核规则与知识。")

# 第 23 页 结语与局限
s = S[22]
replace(s, "当前评测基于合成数据", "当前评测基于合成数据，真实报告识别效果尚待验证\n"
        "判读规则及知识内容尚需医学专家审核\n"
        "问答自然度依赖外部大模型平台；不可用时已设计自动降级\n"
        "仅提供信息解释与复诊准备，不替代诊断或治疗建议")

# 第 3 页 核心成果
title(S[2], "研究成效：识别更准确，解读更可靠")
replace(S[2], "本地报告识别", "本地报告识别 · 三值逻辑组合判读 · 知识溯源解释 · 受控工具调用 · 珍珠鸟陪伴")
replace(S[2], "已完成 Android", "已完成 Android 应用与服务端部署；数字均来自合成/模拟数据测试，规则与知识尚待医学专家审核。")

# 新页 A：受控工具调用（以第 2 页的「两个数字 + 四张卡片」版式为底）
A = duplicate(S[1])
title(A, "算法③+ 受控工具调用：大模型挑资料，程序给结论")
replace(A, "2.33 亿", "54%→100%")
replace(A, "2023 年我国糖尿病患者估计人数", "难题「回答到所问」比例（实验 F，药物影响、与上次比较等 6 类问法）")
replace(A, "每年", "0")
replace(A, "指南建议筛查", "越界用药建议与断定诊断（开启检索规划后）")
replace(A, "医学术语难理解", "读懂问题")
replace(A, "报告中有大量医学缩写", "大模型从 7 个固定工具中挑选要查的资料：指标说明、报告提示、整份报告、与上次比较、药物影响、检查前注意、指标关系。")
replace(A, "单项指标不能说明全部问题", "程序执行")
replace(A, "尿检结果还需结合用药", "工具结果全部来自规则引擎、知识库与历史记录；参数只能取本次报告的指标与提示，非法参数一律丢弃。")
replace(A, "识别错误可能影响解读", "组织回答")
replace(A, "如果 AI 没有识别清楚", "大模型把结果说成白话，再经输出校验；紧急报告的就医提示由程序确定性补回。")
replace(A, "通用 AI 缺少医学约束", "安全不变")
replace(A, "通用 AI 可能给出依据不足", "停药、诊断、急症仍由关键词与专门分类器先行拦截；规划失败即退回规则路由。")
replace(A, "资料：", "资料：实验 F，合成数据；DeepSeek-V4.1-Flash 生成、Qwen3.8-Flash 评审；常规题回答到所问 96%→98%，平均多等约 2 秒。")

# 新页 B：附加材料（以第 19 页四卡片版式为底）
B = duplicate(S[18])
title(B, "附加材料：数据、代码与文献均可核查")
replace(B, "关键字段的智能复核方法", "完整代码与自动化测试")
replace(B, "提出置信度与领域规则联合驱动", "Flutter 客户端与 FastAPI 服务端完整源码及注释；后端 223 项、客户端 190 项自动化测试，可一键复现。")
replace(B, "区分“未知”与“正常”的判读机制", "合成数据集")
replace(B, "引入三值逻辑区分条件成立", "390 张合成报告图片与 786 份标注，开发集与测试集分离，用于识别与判读评测。")
replace(B, "规则下结论、大模型受控调用工具", "实验原始记录")
replace(B, "风险结论只由可审核的规则决定", "对照实验的全部原始回答、评审结果与汇总，每个数字都能追溯到原始记录。")
replace(B, "珍珠鸟陪伴的长期自我管理", "参考文献与资料核查")
replace(B, "打卡、血糖达标时开心", "引用 24 篇文献与指南；团队逐篇核对 42 篇资料，更正 16 处引用错误。")

# ---------- 顺序、导航、附录 ----------
order = [S[0], S[18], S[1], S[3], S[4], S[5], S[7], S[9], A, S[11], S[12], S[16], S[17], S[2], S[14], B, S[19], S[22],
         S[6], S[8], S[10], S[13], S[15], S[20], S[21]]
section = {sl.slide_id: n for sl, n in [(S[18], 0), (S[1], 1), (S[3], 1), (S[4], 2), (S[5], 2), (S[7], 2), (S[9], 2), (A, 2),
           (S[11], 2), (S[12], 3), (S[16], 3), (S[17], 3), (S[2], 4), (S[14], 4), (B, None), (S[19], 5)]}
appendix = [S[6], S[8], S[10], S[13], S[15], S[20], S[21]]
for sl in order:
    if sl.slide_id in section:
        nav(sl, section[sl.slide_id])
for sl in appendix:
    nav(sl, None)
    t = sorted([sh for sh in sl.shapes if sh.has_text_frame and sh.text_frame.text.strip() and sh.top < int(1.0 * 914400)], key=lambda x: x.top)
    if t and not t[0].text_frame.text.startswith("附录"):
        set_text(t[0], "附录 · " + t[0].text_frame.text)

ids = prs.slides._sldIdLst
by_id = {el.id: el for el in ids}
els = [by_id[sl.slide_id] for sl in order]
for el in list(ids):
    ids.remove(el)
for el in els:
    ids.append(el)

# ---------- 讲稿（约 5 分钟，另留约 50 秒演示） ----------
SPEECH = [
    (S[0], 8, "各位评委好，我们是【团队名称】，作品是 MediLens，糖尿病尿检报告的可信解读系统。"),
    (S[18], 25, "先讲创新性。我们有四项设计：一是置信度和医学规则联合的关键字段复核；二是三值逻辑，把看不清的项目当作未知，而不是正常；三是规则下结论、大模型受控调用工具，大模型只负责读懂问题和表达；四是珍珠鸟陪伴，把报告解读延伸到长期自我管理。"),
    (S[1], 20, "为什么需要？我国约 2.33 亿糖尿病患者，需要定期复查尿检。但报告难懂，很多指标要组合着看，比如感染会让 UACR 暂时升高；看不清的项目还可能被当成正常；直接问通用大模型，可能下诊断、谈停药，也没有出处。"),
    (S[3], 15, "和现有做法比：逐项比对参考范围做不到组合判断；直接问大模型，感染干扰只提示了 60%，也不附来源。MediLens 在这些项目上都做到，而且报告照片不出手机。"),
    (S[4], 18, "AI 技术方面，整体架构是医学规则负责判断，大模型辅助解释。手机端完成识别，服务端做规则判读、知识检索和受约束生成，最后经过安全校验。"),
    (S[5], 18, "算法一：手机上用 PP-OCRv5 识别，按置信度、写法和合理范围决定哪些字段要用户确认。只确认约一成字段，就拦下约九成识别错误，识别错误从 3.9% 降到 0.39%。"),
    (S[7], 18, "算法二：三值逻辑的组合规则。每个条件有成立、不成立、信息不足三种结果，信息不足时绝不当成正常，而是明确告诉用户哪些结论无法判断。1000 份合成报告上，红色规则召回 100%，误报为零。"),
    (S[9], 15, "算法三：回答有依据、有边界。先检索知识、用规则结论组装草稿，大模型只在依据内表达，输出必须通过数值、越界和紧急提示三项校验。"),
    (A, 22, "我们最新的改进是受控工具调用。大模型先读懂问题，从七个固定工具里挑要查的资料，比如与上次比较、药物影响；工具由程序执行，结论仍来自规则和知识库。对照实验中，难题回答到所问的比例从 54% 提升到 100%，越界用药建议和断定诊断仍然为零。"),
    (S[11], 15, "算法四把解读延伸到日常：分析个人生活规律和血糖的关系，并用珍珠鸟陪伴打卡；它只表达关心、不责备，提醒时段会根据完成情况自动调整。"),
    (S[12], 15, "项目实施上，我们坚持开发和测试分离：调参只用开发集，测试集只评一次；和通用大模型对照时两组用同一个模型，只差在我们的规则、检索和校验。"),
    (S[16], 18, "系统已经实现：Android 应用、部署在边缘计算工作站的服务端；新增语音提问、复查提醒和拍餐饮估算糖与碳水。账户与 HTTPS 加密传输已开发完成，待部署。后端 223 项、客户端 190 项自动化测试全部通过。"),
    (S[17], 12, "在伦理与规范上：原图不上传、可一键删除；只辅助理解，不诊断、不调药；关键依据可追溯，并如实标注只在合成数据上验证。"),
    (S[2], 15, "研究成效：识别错误降到 0.39%；未知被说成正常降到 0；感染干扰提示从 60% 到 100%；生活规律分析误报不超过 1%。"),
    (S[14], 15, "左图是识别和组合判读的效果，右图是和同一大模型直接解读的对照：附出处从 0 到 75%，错误安慰和断定诊断都降到 0。"),
    (B, 15, "附加材料方面，我们提供完整源码和自动化测试、390 张合成报告和 786 份标注、全部实验原始记录，以及 24 篇参考文献，团队还逐篇核对了 42 篇资料。"),
    (S[19], 15, "下一步：完成伦理审批后用真实报告测试，开展患者和家属的问卷访谈，请医学专家审核规则；中期接入血糖仪，远期扩展到更多指标和社区试点。"),
    (S[22], 12, "最后如实说明局限：评测基于合成数据，规则尚需医学审核，它只辅助理解、不替代医生。我们希望让每一项尿检指标都被看懂。谢谢各位评委。接下来演示 APP。"),
]
total = 0
lines = ["# AIC 半决赛答辩讲稿（按评分表顺序）", "",
         "录制：腾讯会议，全员开摄像头，共享屏幕放映 PPT；开头先报团队名称；**汇报＋演示 ≤ 6 分钟，无剪辑、无快进**。",
         "PPT 讲到「谢谢」页即止（约 5 分钟），之后约 50 秒演示 APP；「谢谢」之后的附录页不讲。", "",
         "| 页 | 评分项 | 秒 | 讲稿 |", "|---|---|---|---|"]
for i, (sl, sec, text) in enumerate(SPEECH, 1):
    notes(sl, f"（约 {sec} 秒）{text}")
    total += sec
    item = NAV[section[sl.slide_id]] if section.get(sl.slide_id) is not None else ("附加分" if sl is B else "—")
    lines.append(f"| {i} | {item} | {sec} | {text} |")
lines += ["", f"合计约 {total // 60} 分 {total % 60} 秒（PPT），加演示约 50 秒。",
          "", "## 演示建议（约 50 秒，可在 PPT 后进行）",
          "1. 首页「体验合成示例报告」→ 尿糖＋尿酮体阳性 → 识别与确认 → 解读总览（紧急提示置顶）。",
          "2. 文字提问「尿酮体是什么」，再问「那它要注意什么」（追问理解），再问「我可以停药吗」（安全回复）。",
          "3. 生活打卡：珍珠鸟、打卡吃药后记血糖、拍餐饮估算糖与碳水。",
          "", "## 录制前检查",
          "- 封面写好团队名称；PPT 中不得出现学校名称、指导老师、校徽或暗示标识。",
          "- 大模型平台密钥需恢复，否则问答为规则说明（仍可演示，但较生硬）。"]
open(SCRIPT, "w", encoding="utf-8").write("\n".join(lines) + "\n")
prs.save(OUT)

# ---------- 匿名检查 ----------
bad = re.compile(r"清华|大学|学院|学校|老师|教师|导师|AIOP|101\.6|tsinghua", re.I)
found = []
for i, sl in enumerate(prs.slides, 1):
    for sh in sl.shapes:
        if sh.has_text_frame and bad.search(sh.text_frame.text):
            found.append((i, bad.findall(sh.text_frame.text)))
    if sl.has_notes_slide and bad.search(sl.notes_slide.notes_text_frame.text):
        found.append((i, "讲稿"))
print("页数", len(prs.slides), "| 讲稿合计", total, "秒 | 匿名检查：", found or "通过")
