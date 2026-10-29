// AIC·AI+医学竞赛答辩 PPT（16:9）。数字取自 docs/MVP2_测试结果.md 与 tests/eval/lifestyle_results.json。
// 用法：node tools/aic_report/build_ppt.js <输出.pptx>
const path = require("path");
const pptxgen = require("pptxgenjs");

const OUT = process.argv[2] || "MediLens-答辩.pptx";
const ROOT = path.resolve(__dirname, "..", "..");
const FIG = (n) => path.join(__dirname, "figures", n);
const SHOT = (n) => path.join(ROOT, "docs", "screenshots", n);
const SKILL_THEME = process.env.APPLY_THEME_JS;

const THEME = {
  name: "MediLens",
  headFontFace: "Microsoft YaHei",
  bodyFontFace: "Microsoft YaHei",
  colors: {
    dk1: "1F2A2E", lt1: "FFFFFF", dk2: "0E3B43", lt2: "EEF5F4",
    accent1: "1F7A6E", accent2: "D9634A", accent3: "E8A33D", accent4: "4F6FA8",
    accent5: "8C959D", accent6: "2E7D6B", hlink: "1F7A6E", folHlink: "4F6FA8",
  },
};
const H = THEME.colors;

const pres = new pptxgen();
pres.layout = "LAYOUT_WIDE"; // 13.33 × 7.5 in
pres.theme = { headFontFace: THEME.headFontFace, bodyFontFace: THEME.bodyFontFace };
pres.title = "MediLens 糖尿病尿检报告可信解读";
const C = pres.SchemeColor;

// —— 版式 ——
pres.defineSlideMaster({
  title: "DARK",
  background: { color: H.dk2 },
  objects: [],
  placeholders: [],
});
pres.defineSlideMaster({
  title: "CONTENT",
  background: { color: H.lt1 },
  objects: [
    { text: { text: "MediLens · 糖尿病尿检报告可信解读", options: { x: 0.6, y: 7.0, w: 6, h: 0.3, fontSize: 10, color: H.accent5 } } },
    // 标题占位符：写在 objects 中，pptxgenjs 才会套用位置、字号与颜色
    { placeholder: { options: { name: "title", type: "title", x: 0.6, y: 0.35, w: 12.1, h: 0.8, fontSize: 30, bold: true, color: H.dk2, valign: "middle", align: "left" }, text: "" } },
  ],
  slideNumber: { x: 12.2, y: 7.0, w: 0.6, h: 0.3, fontSize: 10, color: H.accent5, align: "right" },
});

// —— 工具 ——
const T = (slide, text, opts) => slide.addText(text, { isTextBox: true, fontSize: 14, color: H.dk1, valign: "top", ...opts });
function card(slide, x, y, w, h, n, title, body, opts = {}) {
  slide.addShape(pres.shapes.ROUNDED_RECTANGLE, { x, y, w, h, rectRadius: 0.12, fill: { color: opts.fill || H.lt2 }, line: { color: opts.fill || H.lt2 }, objectName: `card-${title}` });
  if (n !== null && n !== undefined) {
    slide.addShape(pres.shapes.OVAL, { x: x + 0.2, y: y + 0.2, w: 0.5, h: 0.5, fill: { color: opts.badge || H.accent1 }, line: { color: opts.badge || H.accent1 } });
    T(slide, String(n), { x: x + 0.2, y: y + 0.2, w: 0.5, h: 0.5, fontSize: 16, bold: true, color: H.lt1, align: "center", valign: "middle", margin: 0 });
  }
  const tx = n !== null && n !== undefined ? x + 0.85 : x + 0.25;
  T(slide, title, { x: tx, y: y + 0.17, w: x + w - tx - 0.2, h: 0.56, fontSize: 17, bold: true, color: opts.titleColor || H.dk2, valign: "middle", margin: 0 });
  T(slide, body, { x: x + 0.25, y: y + 0.85, w: w - 0.5, h: h - 1.0, fontSize: opts.bodySize || 14, margin: 0, paraSpaceAfter: 4 });
}
function stat(slide, x, y, w, big, label, color) {
  T(slide, big, { x, y, w, h: 0.9, fontSize: 36, bold: true, color: color || H.accent1, margin: 0, valign: "bottom" });
  T(slide, label, { x, y: y + 0.95, w, h: 0.7, fontSize: 13, color: H.dk1, margin: 0 });
}
function phone(slide, file, x, y, h) {
  const w = h * 0.45;
  slide.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: x - 0.06, y: y - 0.06, w: w + 0.12, h: h + 0.12, rectRadius: 0.15, fill: { color: H.dk1 }, line: { color: H.dk1 } });
  slide.addImage({ path: SHOT(file), x, y, w, h });
}
const img = (slide, file, x, y, w, ratio) => slide.addImage({ path: FIG(file), x, y, w, h: w / ratio });
const content = (title, section) => {
  const s = pres.addSlide({ masterName: "CONTENT", sectionTitle: section });
  s.addText(title, { placeholder: "title" });
  return s;
};
const chartBase = (title) => ({
  showTitle: true, title, titleFontSize: 14, titleColor: H.dk2, titleFontFace: "+mn-lt",
  showValue: true, dataLabelPosition: "outEnd", dataLabelFontSize: 11, dataLabelFontFace: "+mn-lt", dataLabelColor: H.dk1,
  catAxisLabelFontSize: 12, catAxisLabelFontFace: "+mn-lt", catAxisLabelColor: H.dk1,
  valAxisLabelFontSize: 10, valAxisLabelFontFace: "+mn-lt", valAxisLabelColor: H.accent5,
  valGridLine: { color: "E3E7EA", size: 0.5 }, catGridLine: { style: "none" },
  showLegend: true, legendPos: "b", legendFontSize: 11, legendFontFace: "+mn-lt", legendColor: H.dk1,
  chartColors: [H.accent5, H.accent1],
});

// ===== 1 封面 =====
pres.addSection({ title: "开场" });
let s = pres.addSlide({ masterName: "DARK", sectionTitle: "开场" });
T(s, "第八届全球校园人工智能算法精英大赛 · 算法主题赛 · AI+医学", { x: 0.7, y: 0.6, w: 8, h: 0.4, fontSize: 14, color: "A9C9C4" });
T(s, "MediLens", { x: 0.7, y: 1.6, w: 7.5, h: 1.2, fontSize: 54, bold: true, color: H.lt1 });
T(s, "糖尿病尿检报告可信解读", { x: 0.7, y: 2.75, w: 7.5, h: 0.7, fontSize: 30, bold: true, color: H.lt1 });
T(s, "规则定结论、模型只表达的可审计 AI 医学信息解释系统", { x: 0.7, y: 3.5, w: 7.5, h: 0.5, fontSize: 18, color: "CFE3E0" });
T(s, "团队编号：__________", { x: 0.7, y: 6.3, w: 5, h: 0.4, fontSize: 14, color: "A9C9C4" });
phone(s, "13_老年模式_紧急提示置顶.png", 8.2, 1.0, 5.4);
phone(s, "16_小兔_漏药生病.png", 10.75, 1.5, 5.0);
s.addNotes("大家好，我们的作品是 MediLens，帮助糖尿病患者看懂尿常规和 UACR 报告。它的核心思路是：由确定性的算法来下结论，大模型只负责把话说清楚，每一步都可以核查。");

// ===== 2 成果一览 =====
s = content("一张图看懂：每一道防线都有量化收益", "开场");
const stats = [
  ["0.39%", "原 3.9%", "进入判读的识别错误（置信度驱动的局部确认）"],
  ["0", "原 8.5%", "错误安慰：看不清的项目被说成「全部正常」"],
  ["100%", "直接问大模型 60%", "感染干扰提示召回（同一大模型对照）"],
  ["≤1%", "检出率 78%–100%", "生活规律误报率（28 天模拟记录）"],
];
stats.forEach(([b, before, l], i) => {
  const x = 0.6 + i * 3.1;
  s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x, y: 1.6, w: 2.85, h: 2.9, rectRadius: 0.12, fill: { color: H.lt2 }, line: { color: H.lt2 } });
  T(s, b, { x: x + 0.25, y: 1.8, w: 2.45, h: 0.95, fontSize: 44, bold: true, color: i === 1 ? H.accent2 : H.accent1, margin: 0, valign: "bottom" });
  T(s, before, { x: x + 0.25, y: 2.8, w: 2.45, h: 0.4, fontSize: 14, bold: true, color: H.accent5, margin: 0 });
  T(s, l, { x: x + 0.25, y: 3.3, w: 2.45, h: 1.0, fontSize: 13, color: H.dk1, margin: 0 });
});
T(s, "端侧识别 · 三值逻辑组合规则 · 检索约束生成 · 两层安全拦截 · 依从驱动的陪伴宠物", { x: 0.6, y: 4.9, w: 12.1, h: 0.5, fontSize: 18, bold: true, color: H.dk2 });
T(s, "已实现 Android 应用并部署于边缘计算工作站；全部评测基于合成数据，判读规则与知识尚未经医学专家审核。", { x: 0.6, y: 5.5, w: 12.1, h: 0.5, fontSize: 14, color: H.accent5 });
s.addNotes("先看结论。局部确认把进入判读的识别错误从 3.9% 降到 0.39%；看不清的项目不会再被说成全部正常；和直接问同一个大模型相比，感染干扰的提示从 60% 提升到 100%；生活规律分析在模拟患者上检出率 78% 到 100%，误报不到 1%。这些都是合成数据上的结果，规则还没经过医学审核，我们会如实说明。");

// ===== 3 背景 =====
pres.addSection({ title: "背景与需求" });
s = content("背景：报告看不懂，组合关系更难懂", "背景与需求");
stat(s, 0.6, 1.4, 3.6, "2.33 亿", "2023 年我国糖尿病患者估计人数 [1]");
stat(s, 0.6, 3.3, 3.6, "每年", "指南建议筛查 UACR 与 eGFR，DKD 早期常无症状 [4][7]");
card(s, 4.6, 1.4, 4.0, 2.4, 1, "看不懂", "缩写、「±/1+」半定量等级、单位与参考区间，患者只记住「+」或「↑」");
card(s, 8.85, 1.4, 3.85, 2.4, 2, "组合更难", "尿糖+酮体需警惕酮症；感染使 UACR 暂时升高；SGLT2 抑制剂使尿糖阳性");
card(s, 4.6, 4.05, 4.0, 2.4, 3, "未知被当正常", "看不清的项目被隐藏，总体显示「全部正常」，形成错误安慰");
card(s, 8.85, 4.05, 3.85, 2.4, 4, "大模型有风险", "可能编造、断定诊断、回应停药询问，且没有出处", { badge: H.accent2 });
s.addNotes("糖尿病患者约 2.33 亿，需要定期复查尿检，但报告很难看懂。更难的是组合关系：尿糖加酮体要警惕酮症，感染会让 UACR 暂时升高，有些降糖药本身就会让尿糖阳性。还有两个隐患：看不清的项目被当成正常，以及直接问大模型可能下诊断、没有出处。");

// ===== 4 需求与现有方案 =====
s = content("现有方案为何不够：三种做法对比", "背景与需求");
const Y = "✓", N = "✗", P = "△";
const rows = [
  ["能力", "逐项比对参考范围", "直接问通用大模型", "MediLens"],
  ["多指标组合与干扰因素", N, P + "（感染干扰 60%）", Y + "（100%）"],
  ["看不清的项目不当正常", N + "（8.5% 误报正常）", P + "（13.3% 错误安慰）", Y + "（0）"],
  ["解释附资料来源", N, N + "（0%）", Y + "（75%）"],
  ["停药 / 诊断 / 危险症状拦截", "—", P, Y + "（两层拦截 90.9%）"],
  ["报告照片不出手机", "视实现而定", N, Y],
  ["无大模型时仍可运行", Y, N, Y],
];
s.addTable(rows.map((r, i) => r.map((v, j) => ({
  text: v,
  options: {
    bold: i === 0 || j === 0, fontSize: 14, color: i === 0 ? H.lt1 : (j === 3 ? H.accent1 : H.dk1),
    fill: { color: i === 0 ? H.dk2 : (j === 3 ? "E2F0ED" : (i % 2 ? "FFFFFF" : "F6F8F9")) },
    align: j === 0 ? "left" : "center", valign: "middle",
  },
}))), { x: 0.6, y: 1.45, w: 12.1, colW: [3.6, 2.8, 2.9, 2.8], rowH: 0.62, border: { type: "solid", pt: 0.5, color: "D5DCE0" }, fontFace: "Microsoft YaHei" });
T(s, "数据来自实验 A（1000 份）与实验 D（60 份分层，两组用同一大模型）；△ 表示部分做到。", { x: 0.6, y: 6.05, w: 12.1, h: 0.4, fontSize: 12, color: H.accent5 });
s.addNotes("我们比较了三种做法。逐项比对没有组合判断；直接问大模型在基本安全上不错，但感染干扰只提示了 60%，有 13% 把不确定说成良好，而且没有出处。MediLens 在这些项目上都做到，并且报告照片不离开手机，没有大模型也能运行。");

// ===== 5 架构 =====
pres.addSection({ title: "核心技术" });
s = content("总体架构：确定性算法判断，大模型只负责表达", "核心技术");
img(s, "fig1_architecture.png", 0.6, 1.35, 8.1, 1.702);
card(s, 8.95, 1.35, 3.75, 1.55, null, "移动端", "报告图像只在手机处理：质量评估、文字检测与识别、局部确认", { bodySize: 13 });
card(s, 8.95, 3.05, 3.75, 1.55, null, "服务端", "标准化 → 组合规则 → 追问 → 检索 → 受约束生成 → 校验", { bodySize: 13 });
card(s, 8.95, 4.75, 3.75, 1.55, null, "大模型只做两件事", "把草稿改写成口语；判断提问是否越界。超时或不过校验即回退", { bodySize: 13, fill: "FBEDE9", titleColor: H.accent2 });
s.addNotes("整体架构分三层。手机端完成拍照识别，原图不上传；服务端依次做标准化、组合规则判读、追问、知识检索和受约束生成。大模型只做两件事：把草稿说得口语，以及判断提问有没有越界。风险等级完全由规则决定。");

// ===== 6 算法① =====
s = content("算法①  端侧识别 + 置信度驱动的局部确认", "核心技术");
img(s, "fig2_ocr_confirm.png", 0.6, 1.35, 8.9, 2.727);
s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: 0.6, y: 4.85, w: 8.9, h: 0.75, rectRadius: 0.1, fill: { color: H.lt2 }, line: { color: H.lt2 } });
T(s, "R(f) = 1[c<τ] ∨ 1[写法不合法] ∨ 1[单独「+」] ∨ 1[超出合理范围] ∨ 1[f∈K]，τ = 0.85，K = {UACR}", { x: 0.8, y: 4.85, w: 8.5, h: 0.75, fontSize: 13, bold: true, color: H.dk2, valign: "middle", margin: 0 });
T(s, "只请用户确认约 11.5% 的字段，拦下约 90% 的识别错误；针对「置信度高却丢了小数点」（UACR 81.1→811），关键定量值一律核对，新测试集静默错误为 0。", { x: 0.6, y: 5.75, w: 8.9, h: 0.9, fontSize: 14, margin: 0 });
phone(s, "04_局部确认_原图高亮与候选.png", 10.3, 1.35, 5.3);
s.addNotes("第一个算法是置信度驱动的局部确认。手机上用 PP-OCRv5 做文字检测和识别，每个字段算出置信度。我们设计了一个触发函数：置信度低于 0.85、写法不合法、单独一个加号、超出合理范围，或者是 UACR 这种关键数值，就在原图上框出来请用户确认，并给出候选值。这样只确认约一成字段，就拦下九成错误。");

// ===== 7 算法② =====
s = content("算法②  三值逻辑组合规则：未知不变绿", "核心技术");
const tv = [["AND", "T", "U", "F"], ["T", "T", "U", "F"], ["U", "U", "U", "F"], ["F", "F", "F", "F"]];
s.addTable(tv.map((r, i) => r.map((v, j) => ({
  text: v, options: {
    bold: i === 0 || j === 0, fontSize: 16, align: "center", valign: "middle",
    color: i === 0 || j === 0 ? H.lt1 : (v === "U" ? H.accent3 : H.dk1),
    fill: { color: i === 0 || j === 0 ? H.dk2 : "FFFFFF" },
  },
}))), { x: 0.6, y: 1.5, w: 3.6, colW: [0.9, 0.9, 0.9, 0.9], rowH: 0.6, border: { type: "solid", pt: 0.75, color: "C9D2D6" }, fontFace: "Microsoft YaHei" });
T(s, "T 成立 · F 不成立 · U 信息缺失（看不清、未回答、未检测）", { x: 0.6, y: 4.0, w: 3.8, h: 0.7, fontSize: 13, color: H.accent5, margin: 0 });
card(s, 4.6, 1.5, 4.0, 2.2, 1, "规则只在 T 时命中", "U 进入「哪些结论受信息缺失影响」列表，绝不当作 F；用户答「不确定/跳过」也是 U");
card(s, 4.6, 3.9, 4.0, 2.2, 2, "未知不变绿", "无规则命中但有无法确认项或缺关键项 → 总体「部分信息无法判断」（灰），而不是「正常」");
const rules = [["R-01", "尿糖+酮体阳性", "红"], ["R-02", "尿糖阳性+SGLT2", "绿·解释"], ["R-03", "UACR↑+感染", "黄"], ["R-04", "UACR 30–300", "黄"], ["R-05", "尿蛋白等级上升", "黄"], ["R-06", "近一年无 UACR", "绿"]];
s.addTable([[{ text: "规则（YAML，可版本化）", options: { colspan: 3, bold: true, color: H.lt1, fill: { color: H.dk2 }, fontSize: 14 } }]].concat(
  rules.map((r) => r.map((v, j) => ({ text: v, options: { fontSize: 13, color: j === 2 && v === "红" ? H.accent2 : H.dk1, fill: { color: "FFFFFF" } } })))),
  { x: 8.85, y: 1.5, w: 3.85, colW: [0.8, 2.0, 1.05], rowH: 0.5, border: { type: "solid", pt: 0.5, color: "D5DCE0" }, fontFace: "Microsoft YaHei" });
T(s, "1000 份报告：红色规则召回 100%（103/103），误报 0/897", { x: 8.85, y: 5.25, w: 3.85, h: 0.8, fontSize: 13, color: H.accent1, bold: true, margin: 0 });
s.addNotes("第二个算法是三值逻辑的组合规则引擎。每个条件有三种结果：成立、不成立、信息缺失。规则只在成立时命中；信息缺失时，绝不当作不成立，而是列出哪些结论因此无法判断。所以看不清的项目不会让报告显示全部正常，我们称为未知不变绿。");

// ===== 8 算法③ =====
s = content("算法③  检索约束生成 + 两层越界拦截", "核心技术");
img(s, "fig3_safety.png", 1.4, 1.25, 10.5, 2.938);
card(s, 0.6, 5.0, 3.85, 1.75, null, "检索打分", "s(e,q) = 2·|C_q∩C_e| + Σ1[k∈q] + 0.5·|B(q)∩B(title)|", { bodySize: 13 });
card(s, 4.72, 5.0, 3.85, 1.75, null, "输出三项校验", "数值须出自报告与知识；禁用「确诊/停药」；紧急结论须有规则支持", { bodySize: 13 });
card(s, 8.85, 5.0, 3.85, 1.75, null, "越界拦截", "仅关键词 59.1% → 加入语义分类 90.9%，正常提问误拦截 0", { bodySize: 13, fill: "FBEDE9", titleColor: H.accent2 });
s.addNotes("第三个算法保证回答可信。先按指标、关键词和标题字词打分检索知识，用规则结论和知识组装回答草稿；大模型只改写草稿，改写后必须通过三项检查，否则退回草稿。提问在生成前先过两层拦截：关键词组合和大模型语义分类，对新题的拦截率从 59% 提升到 91%，正常问题没有误拦。");

// ===== 9 算法④ =====
s = content("算法④  生活作息分析 + 依从驱动的陪伴宠物", "核心技术");
img(s, "fig4_pet.png", 0.6, 1.3, 9.3, 2.727);
card(s, 0.6, 4.85, 2.95, 1.85, null, "n-of-1 规律", "两组中位数差 + 置换检验；只说相关，不给剂量", { bodySize: 13 });
card(s, 3.75, 4.85, 2.95, 1.85, null, "漏药小兔会生病", "警示依从，按时用药即恢复，不会死亡，可关闭", { bodySize: 13, fill: "FBEDE9", titleColor: H.accent2 });
card(s, 6.9, 4.85, 3.0, 1.85, null, "自适应提醒", "Thompson 采样学习最易完成的提醒时段", { bodySize: 13 });
phone(s, "16_小兔_漏药生病.png", 10.5, 1.3, 5.4);
s.addNotes("第四部分把解读延伸到日常管理。患者打卡用药、饮食、运动、睡眠和血糖，系统在个人数据上比较两组血糖的中位数，用置换检验判断是不是巧合，找出像饭后才打胰岛素血糖偏高这样的规律。小兔的健康只跟按时用药有关，漏药会生病，按时用药就恢复；它不反映血糖值，避免患者因为数值不好就不敢记录。提醒时间用 Thompson 采样自动学习。");

// ===== 10 实验设计 =====
pres.addSection({ title: "实验与成效" });
s = content("实验设计：开发与评测严格隔离", "实验与成效");
card(s, 0.6, 1.4, 3.85, 2.45, 1, "合成报告", "3 种版式 × 8 种干扰，带水印、固定种子；开发集调参，测试集冻结后只评一次");
card(s, 4.72, 1.4, 3.85, 2.45, 2, "规则判读", "1000 份随机报告，由独立编写的判定程序逐项比对");
card(s, 8.85, 1.4, 3.85, 2.45, 3, "越界提问", "两轮各 60 句；第二轮在拦截器定型后新写");
card(s, 0.6, 4.1, 5.95, 2.45, 4, "对照通用大模型（实验 D）", "60 份分层报告，两组用同一模型，只差 MediLens 的规则、检索与校验；由另一厂商模型按固定标准评审，并人工抽查");
card(s, 6.75, 4.1, 5.95, 2.45, 5, "生活规律与提醒", "100 名植入已知效应 + 100 名无效应的模拟患者，统计检出率与误报率；30 天在线模拟比较提醒策略");
s.addNotes("实验设计上，我们坚持开发和评测分开：调参只用开发集，测试集调完才生成、只评一次。开发集和测试集的拦截率分别是 98% 和 90%，说明只看调参数据会高估效果。对照大模型的实验中，两组用同一个模型，差别只在我们的规则、检索和校验。");

// ===== 11 结果① =====
s = content("结果①：与通用做法的对照", "实验与成效");
s.addChart(pres.charts.BAR, [
  { name: "对照（自动接受 / 逐项比对）", labels: ["进入判读的识别错误", "错误安慰率"], values: [3.9, 8.5] },
  { name: "MediLens", labels: ["进入判读的识别错误", "错误安慰率"], values: [0.39, 0] },
], { x: 0.6, y: 1.35, w: 5.6, h: 4.6, barDir: "col", barGapWidthPct: 60, valAxisMaxVal: 10, valAxisMinVal: 0, dataLabelFormatCode: "0.0#\"%\"", ...chartBase("实验 A/B（%，越低越好）") });
s.addChart(pres.charts.BAR, [
  { name: "同一大模型直接解读", labels: ["感染干扰提示↑", "附资料来源↑", "错误安慰↓", "断定诊断↓"], values: [60, 0, 13.3, 18.3] },
  { name: "MediLens", labels: ["感染干扰提示↑", "附资料来源↑", "错误安慰↓", "断定诊断↓"], values: [100, 75, 0, 0] },
], { x: 6.5, y: 1.35, w: 6.2, h: 4.6, barDir: "col", barGapWidthPct: 50, valAxisMaxVal: 110, valAxisMinVal: 0, dataLabelFormatCode: "0.0\"%\"", ...chartBase("实验 D（%，60 份分层合成报告）") });
T(s, "如实说明：直接解读在「不编造检查结果、不建议停药、紧急就医提示」上同样表现良好；「断定诊断」评审偏严，可能高估。", { x: 0.6, y: 6.1, w: 12.1, h: 0.7, fontSize: 13, color: H.accent5, margin: 0 });
s.addNotes("左图是局部确认和组合规则的效果：识别错误和错误安慰都大幅下降。右图是和同一大模型直接解读的对照：感染干扰提示从 60% 到 100%，附出处从 0 到 75%，错误安慰和断定诊断都降到 0。我们也如实说明，直接问大模型在不编造、不建议停药、紧急提示上同样做得好。");

// ===== 12 结果② =====
s = content("结果②：生活规律检出与自适应提醒", "实验与成效");
s.addChart(pres.charts.BAR, [
  { name: "检出率", labels: ["饭后才打胰岛素", "睡眠不足", "饭后活动", "漏用药", "晚间运动"], values: [100, 94, 78, 58, 51] },
  { name: "误报率", labels: ["饭后才打胰岛素", "睡眠不足", "饭后活动", "漏用药", "晚间运动"], values: [1, 0, 0, 0, 0] },
], { x: 0.6, y: 1.35, w: 7.6, h: 4.7, barDir: "col", barGapWidthPct: 45, valAxisMaxVal: 110, valAxisMinVal: 0, dataLabelFormatCode: "0\"%\"", ...chartBase("28 天模拟记录：规律检出率 / 误报率（%）"), chartColors: [H.accent1, H.accent2] });
s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: 8.55, y: 1.35, w: 4.15, h: 4.7, rectRadius: 0.12, fill: { color: H.lt2 }, line: { color: H.lt2 } });
T(s, "自适应提醒 · 30 天任务完成率", { x: 8.8, y: 1.55, w: 3.7, h: 0.5, fontSize: 16, bold: true, color: H.dk2, margin: 0 });
stat(s, 8.8, 2.2, 3.7, "54.6%", "Thompson 采样");
stat(s, 8.8, 3.75, 3.7, "48.0%", "随机选择时段（已知最佳时段上限 65%）", H.accent5);
T(s, "记录越久越准：14 天时「睡眠不足」检出 60%，28 天达 94%。", { x: 0.6, y: 6.15, w: 12.1, h: 0.5, fontSize: 13, color: H.accent5, margin: 0 });
s.addNotes("生活模块在 100 名有效应和 100 名无效应的模拟患者上评测。28 天记录下，饭后才打胰岛素的规律检出率 100%，睡眠不足 94%，误报都在 1% 以内；晚间运动和漏药事件较少，需要更长记录。自适应提醒 30 天把任务完成率从 48% 提升到 54.6%。");

// ===== 13 实现与部署 =====
s = content("系统实现与部署", "实验与成效");
[["07_解读总览.png", "解读总览"], ["10_文字对话_越界问题安全回复.png", "越界提问安全回复"], ["13_老年模式_紧急提示置顶.png", "老年模式·紧急置顶"], ["15_生活打卡_小兔陪伴.png", "生活打卡·小兔"]].forEach(([f, c], i) => {
  const x = 0.75 + i * 2.15;
  phone(s, f, x, 1.4, 4.2);
  T(s, c, { x: x - 0.1, y: 5.75, w: 2.1, h: 0.4, fontSize: 12, align: "center", color: H.dk1, margin: 0 });
});
const facts = ["Flutter 客户端 + ONNX 端侧 OCR，Android 已可安装使用", "FastAPI 后端部署于 Ubuntu 边缘计算工作站，开机自启、访问口令", "原图不出手机；本机记录加密，可一键删除", "大模型不可用时自动降级，功能完整", "后端 112 项、客户端 31 项单元测试 + 端到端测试", "端到端 3.3–8.0 秒（目标 ≤15 秒）"];
T(s, facts.map((t, i) => ({ text: t, options: { bullet: true, breakLine: i < facts.length - 1 } })), { x: 9.55, y: 1.4, w: 3.15, h: 4.8, fontSize: 13, paraSpaceAfter: 8, margin: 0 });
s.addNotes("系统已经实现并部署。客户端用 Flutter，识别模型在手机上运行；后端部署在学校提供的边缘计算工作站。原图不出手机，本机记录加密。没有大模型时功能照样完整。后端和客户端都有自动化测试，单份报告从载入到出结果 3 到 8 秒。");

// ===== 14 创新点 =====
pres.addSection({ title: "创新与展望" });
s = content("创新点", "创新与展望");
card(s, 0.6, 1.4, 5.95, 2.45, 1, "置信度 × 领域规则的局部确认", "把人在回路精确施加到少数高风险字段，并专门处理「高置信度静默错误」");
card(s, 6.75, 1.4, 5.95, 2.45, 2, "三值逻辑组合判读", "把信息缺失建模为第三种真值，从机制上杜绝把未知说成正常");
card(s, 0.6, 4.1, 5.95, 2.45, 3, "规则定结论、模型只表达", "检索约束 + 输出校验 + 两层拦截，大模型的不确定性被限制在可校验范围");
card(s, 6.75, 4.1, 5.95, 2.45, 4, "依从驱动、与检验解耦的陪伴", "漏药生病以示警示但可恢复；规律分析连接作息与血糖，提醒时段自适应", { badge: H.accent2 });
s.addNotes("我们的创新不在单项技术，而在组合：一是置信度和领域规则结合的局部确认；二是用三值逻辑从机制上避免把未知说成正常；三是规则定结论、模型只表达；四是依从驱动、但不反映检验结果的陪伴宠物，把报告解读延伸到日常管理。");

// ===== 15 前景 =====
s = content("应用前景与规划", "创新与展望");
const plan = [["近期 1–3 个月", "伦理审批后用 ≥100 份授权脱敏真实报告评测；医学专家审核规则与知识；5–10 人可理解度评分；新一轮独立越界题库"],
  ["中期 3–6 个月", "系统通知提醒、对接血糖仪 / CGM；用公开 CGM 数据集验证规律分析；评估宠物负面反馈对依从与情绪的影响"],
  ["远期", "扩展血糖、HbA1c、肌酐 / eGFR 联合解读；家属共享；与社区医疗机构合作试点"]];
plan.forEach(([t, b], i) => {
  const y = 1.4 + i * 1.55;
  s.addShape(pres.shapes.OVAL, { x: 0.6, y: y + 0.25, w: 0.5, h: 0.5, fill: { color: H.accent1 }, line: { color: H.accent1 } });
  T(s, String(i + 1), { x: 0.6, y: y + 0.25, w: 0.5, h: 0.5, fontSize: 16, bold: true, color: H.lt1, align: "center", valign: "middle", margin: 0 });
  T(s, t, { x: 1.3, y, w: 2.4, h: 1.0, fontSize: 16, bold: true, color: H.dk2, valign: "middle", margin: 0 });
  T(s, b, { x: 3.7, y, w: 4.6, h: 1.3, fontSize: 13, valign: "middle", margin: 0 });
});
card(s, 8.75, 1.4, 3.95, 4.6, null, "应用场景", "· 患者：复诊前看懂报告、整理问题\n· 家属：代老人整理报告与提醒用药\n· 基层医疗：规范、可追溯的基础解释\n· 成本：服务器无需 GPU，可无模型运行");
s.addNotes("下一步最重要的是真实数据和医学审核：经过伦理审批后用真实报告评测，并请医学专家审核规则。中期做系统通知、对接血糖仪，用公开数据集验证规律分析；远期扩展到血糖和肾功能等联合解读，并与社区医疗机构试点。");

// ===== 16 结语 =====
s = pres.addSlide({ masterName: "DARK", sectionTitle: "创新与展望" });
T(s, "让每一项尿检指标都被看懂", { x: 0.7, y: 1.6, w: 11.9, h: 1.0, fontSize: 40, bold: true, color: H.lt1 });
T(s, "可审计 · 不把未知当正常 · 规则定结论 · 陪伴长期依从", { x: 0.7, y: 2.7, w: 11.9, h: 0.6, fontSize: 20, color: "CFE3E0" });
const lim = ["全部评测基于合成数据，真实照片识别率待验证", "判读规则与知识尚未经医学专家正式审核", "辅助理解与复诊准备，不替代医生诊断，不给用药建议"];
T(s, lim.map((t, i) => ({ text: t, options: { bullet: true, breakLine: i < lim.length - 1 } })), { x: 0.7, y: 3.9, w: 11.9, h: 1.6, fontSize: 16, color: "A9C9C4", paraSpaceAfter: 6, margin: 0 });
T(s, "谢谢！", { x: 0.7, y: 5.9, w: 6, h: 0.8, fontSize: 32, bold: true, color: H.lt1 });
s.addNotes("最后总结：MediLens 希望让每一项尿检指标都被看懂。我们也清楚目前的局限：评测基于合成数据，规则还需医学审核，它是辅助理解的工具，不替代医生。谢谢各位老师。");

(async () => {
  await pres.writeFile({ fileName: OUT });
  if (SKILL_THEME) {
    const { applyTheme } = require(SKILL_THEME);
    await applyTheme(OUT, THEME);
  }
  console.log("已生成", OUT);
})();
