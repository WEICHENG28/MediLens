// 机器人格斗及竞技大赛 · 智能机器人创意设计 —— PPT 第一稿（16:9，3 分钟，8 页）。
// 匿名评审：不出现学校名称、Logo 与人名。数字取自 docs/开发进展.md（实验 A/D/F，均为合成数据）。
// 用法：node tools/aic_report/build_robot_ppt.js <输出.pptx>
const path = require("path");
const pptxgen = require("pptxgenjs");

const OUT = process.argv[2] || "MediLens-机器人大赛-PPT第一稿.pptx";
const ROOT = path.resolve(__dirname, "..", "..");
const ASSET = (n) => path.join(ROOT, "docs", "機器人格鬥大賽", "素材", n);

const H = { dk1: "1F2A2E", lt1: "FFFFFF", dk2: "0E3B43", lt2: "EEF5F4", a1: "1F7A6E", a2: "D9634A", a3: "E8A33D", a4: "4F6FA8", grey: "8C959D", warm: "FFF4EA" };
const pres = new pptxgen();
pres.layout = "LAYOUT_WIDE"; // 13.33 × 7.5 in
pres.theme = { headFontFace: "Microsoft YaHei", bodyFontFace: "Microsoft YaHei" };
pres.title = "MediLens 糖尿病陪护机器人";

pres.defineSlideMaster({ title: "DARK", background: { color: H.dk2 }, objects: [] });
pres.defineSlideMaster({
  title: "CONTENT",
  background: { color: H.lt1 },
  objects: [
    { rect: { x: 0, y: 0, w: 13.33, h: 0.12, fill: { color: H.a1 } } },
    { text: { text: "MediLens 糖尿病陪护机器人 · 智能机器人创意设计", options: { x: 0.6, y: 7.0, w: 7, h: 0.3, fontSize: 10, color: H.grey } } },
    { placeholder: { options: { name: "title", type: "title", x: 0.6, y: 0.35, w: 12.1, h: 0.8, fontSize: 28, bold: true, color: H.dk2, valign: "middle", align: "left" }, text: "" } },
  ],
  slideNumber: { x: 12.2, y: 7.0, w: 0.6, h: 0.3, fontSize: 10, color: H.grey, align: "right" },
});

const T = (s, text, o) => s.addText(text, { isTextBox: true, fontSize: 14, color: H.dk1, valign: "top", margin: 0, ...o });
const box = (s, x, y, w, h, fill, line) => s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x, y, w, h, rectRadius: 0.12, fill: { color: fill }, line: { color: line || fill } });
const content = (title) => { const s = pres.addSlide({ masterName: "CONTENT" }); s.addText(title, { placeholder: "title" }); return s; };
// 待补占位：橙色虚线框，提醒组员换成真实照片/数据
function todo(s, x, y, w, h, text) {
  s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x, y, w, h, rectRadius: 0.1, fill: { color: "FFF8EE" }, line: { color: H.a3, dashType: "dash", width: 1.5 } });
  T(s, "【待补】" + text, { x: x + 0.15, y, w: w - 0.3, h, fontSize: 13, color: "B26A00", align: "center", valign: "middle" });
}
// 状态标签：已实现 / 原型机已具备 / 开发中 / 展望
const TAG = { done: ["已实现", H.a1], proto: ["原型机已具备", H.a4], dev: ["开发中", H.a3], future: ["展望", H.grey] };
function tag(s, x, y, kind) {
  const [t, c] = TAG[kind];
  s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x, y, w: 1.45, h: 0.32, rectRadius: 0.16, fill: { color: c }, line: { color: c } });
  T(s, t, { x, y, w: 1.45, h: 0.32, fontSize: 11, bold: true, color: H.lt1, align: "center", valign: "middle" });
}
function phone(s, file, x, y, h) {
  const w = h * 0.45;
  box(s, x - 0.06, y - 0.06, w + 0.12, h + 0.12, H.dk1);
  s.addImage({ path: ASSET(file), x, y, w, h });
}

// 1 封面 ——————————————————————————————————————
let s = pres.addSlide({ masterName: "DARK" });
T(s, "中国智能机器人格斗及竞技大赛 · 智能机器人创意设计", { x: 0.7, y: 0.6, w: 9, h: 0.4, color: "A9C9C4" });
T(s, "MediLens 糖尿病陪护机器人", { x: 0.7, y: 1.7, w: 8.5, h: 1.0, fontSize: 44, bold: true, color: H.lt1 });
T(s, "看得懂报告，守得住日常", { x: 0.7, y: 2.75, w: 8.5, h: 0.7, fontSize: 28, bold: true, color: "F6C9A0" });
T(s, "软件大脑：可信的报告解读与生活陪伴  ×  机器人身体：导航 · 视觉 · 机械臂", { x: 0.7, y: 3.55, w: 8.5, h: 0.5, fontSize: 17, color: "CFE3E0" });
s.addImage({ path: ASSET("珍珠鸟.png"), x: 9.4, y: 1.6, w: 3.0, h: 3.0 * 405 / 431 });
T(s, "队伍编号：__________", { x: 0.7, y: 6.3, w: 5, h: 0.4, color: "A9C9C4" });
s.addNotes("（约 15 秒）各位评委好，我们的作品是 MediLens 糖尿病陪护机器人。一句话概括：它看得懂检查报告，也守得住病人的日常。软件是它的大脑，机器人是它的身体。");

// 2 痛点 ——————————————————————————————————————
s = content("为什么需要陪护机器人：糖尿病管理难在「看不懂」和「没人看着」");
T(s, "2.33 亿", { x: 0.6, y: 1.45, w: 3.6, h: 0.9, fontSize: 44, bold: true, color: H.a1, valign: "bottom" });
T(s, "2023 年我国糖尿病患者估计人数", { x: 0.6, y: 2.4, w: 3.6, h: 0.5, fontSize: 13 });
const pains = [
  ["看不懂", "尿检指标要组合着看：尿糖＋酮体要警惕酮症，感染会让尿蛋白指标暂时升高；直接问通用大模型，可能把看不清的项目说成正常"],
  ["记不住", "一天多次用药、打针、测血糖，漏了没人提醒，也说不清给医生听"],
  ["没人看着", "老人独居时，跌倒或低血糖晕倒可能很久才被发现"],
];
pains.forEach(([t, b], i) => {
  const y = 1.4 + i * 1.75;
  box(s, 4.6, y, 8.1, 1.55, i === 2 ? "FBEDE9" : H.lt2);
  T(s, t, { x: 4.85, y: y + 0.15, w: 2, h: 0.5, fontSize: 20, bold: true, color: i === 2 ? H.a2 : H.dk2 });
  T(s, b, { x: 4.85, y: y + 0.65, w: 7.6, h: 0.8, fontSize: 14 });
});
T(s, "来源：Zhou M, et al. Military Medical Research, 2025（2005–2023 年中国糖尿病患病研究）", { x: 0.6, y: 6.4, w: 6, h: 0.3, fontSize: 10, color: H.grey });
s.addNotes("（约 25 秒）我国有约 2.33 亿糖尿病患者。管理的难处有三个：一是报告看不懂，很多指标要组合着看；二是用药、打针、测血糖记不住；三是没人看着，独居老人跌倒或低血糖晕倒，可能很久才被发现。手机软件能解决前两个，第三个需要一个能移动、能看见、能动手的机器人。");

// 3 核心理念 ——————————————————————————————————
s = content("核心理念：软件大脑 × 机器人身体");
box(s, 0.6, 1.4, 5.6, 4.9, H.lt2);
T(s, "软件大脑：MediLens", { x: 0.9, y: 1.6, w: 5, h: 0.5, fontSize: 20, bold: true, color: H.a1 });
T(s, [
  { text: "规则下结论，大模型只负责说明", options: { bold: true, breakLine: true } },
  { text: "风险判断全由可审核的规则决定，每句话附出处", options: { breakLine: true } },
  { text: " ", options: { breakLine: true } },
  { text: "看不清就说「未知」，不当成正常", options: { bold: true, breakLine: true } },
  { text: " ", options: { breakLine: true } },
  { text: "珍珠鸟陪伴打卡", options: { bold: true, breakLine: true } },
  { text: "用药、饮食、血糖记录与提醒", options: {} },
], { x: 0.9, y: 2.25, w: 5.1, h: 3.8, fontSize: 15, paraSpaceAfter: 2 });
T(s, "×", { x: 6.25, y: 3.3, w: 0.8, h: 0.9, fontSize: 44, bold: true, color: H.a2, align: "center" });
box(s, 7.1, 1.4, 5.6, 4.9, H.warm);
T(s, "机器人身体：原型机", { x: 7.4, y: 1.6, w: 5, h: 0.5, fontSize: 20, bold: true, color: H.a2 });
[["自主导航", "按时走到老人身边"], ["摄像头视觉", "跌倒检测，及时发现异常"], ["机械臂", "递药、递血糖仪"]].forEach(([t, b], i) => {
  const y = 2.3 + i * 1.25;
  T(s, t, { x: 7.4, y, w: 2.3, h: 0.45, fontSize: 17, bold: true, color: H.dk2 });
  T(s, b, { x: 7.4, y: y + 0.45, w: 3.4, h: 0.45, fontSize: 14 });
  tag(s, 11.0, y + 0.05, "proto");
});
T(s, "让软件「走出手机」：从提醒你，到走到你身边、看见你、帮你一把", { x: 0.6, y: 6.45, w: 12.1, h: 0.45, fontSize: 16, bold: true, color: H.dk2, align: "center" });
s.addNotes("（约 25 秒）我们的核心理念是软件大脑加机器人身体。大脑是 MediLens：规则下结论、大模型只负责说明，看不清就说未知；还有珍珠鸟陪伴打卡。身体是原型机：自主导航、摄像头和机械臂。两者结合，让软件走出手机，从提醒你，变成走到你身边、看见你、帮你一把。");

// 4 系统架构 ——————————————————————————————————
s = content("系统架构：机器人负责感知与行动，服务器负责可信判断");
const col = (x, title, items, fill, tc) => {
  box(s, x, 1.45, 3.75, 4.6, fill);
  T(s, title, { x: x + 0.25, y: 1.6, w: 3.3, h: 0.5, fontSize: 18, bold: true, color: tc });
  items.forEach((t, i) => { box(s, x + 0.25, 2.25 + i * 0.92, 3.25, 0.75, H.lt1, "D5DEDC"); T(s, t, { x: x + 0.4, y: 2.25 + i * 0.92, w: 3.0, h: 0.75, fontSize: 14, valign: "middle" }); });
};
col(0.6, "机器人 / 手机（端侧）", ["报告拍照：本机识别，原图不上传", "导航到用户身边", "摄像头：跌倒检测", "机械臂：递药、递血糖仪"], H.warm, H.a2);
col(4.8, "服务器（可信判断）", ["组合规则：三值逻辑，未知不变绿", "知识库检索：回答附出处", "受控大模型：只组织语言", "安全校验：拦截停药与诊断提问"], H.lt2, H.a1);
col(9.0, "用户与家属", ["看懂报告：一句白话＋可展开细节", "珍珠鸟打卡与提醒", "复诊问题清单", "异常时通知家属（开发中）"], "EEF1F8", H.a4);
[[4.4, 3.7], [8.6, 3.7]].forEach(([x, y]) => s.addShape(pres.shapes.RIGHT_ARROW, { x, y, w: 0.38, h: 0.4, fill: { color: H.grey }, line: { color: H.grey } }));
T(s, "账户资料存服务器（HTTPS 加密，开发中）；报告照片始终只在设备上识别", { x: 0.6, y: 6.3, w: 12.1, h: 0.4, fontSize: 13, color: H.grey, align: "center" });
s.addNotes("（约 20 秒）系统分三块。机器人和手机负责感知与行动：本机识别报告、导航、跌倒检测、机械臂递物。服务器负责可信判断：三值逻辑规则、知识库检索、受控大模型和安全校验。最后用白话把结果交给用户和家属。");

// 5 核心技术① ——————————————————————————————————
s = content("核心技术①：可信的报告解读");
const steps = ["本机识别", "存疑处人工确认", "三值逻辑规则判读", "知识检索·规划", "受控生成＋安全校验"];
steps.forEach((t, i) => {
  const x = 0.6 + i * 2.5;
  box(s, x, 1.45, 2.2, 0.95, i === 2 ? H.a1 : H.lt2);
  T(s, t, { x: x + 0.1, y: 1.45, w: 2.0, h: 0.95, fontSize: 14, bold: true, align: "center", valign: "middle", color: i === 2 ? H.lt1 : H.dk2 });
  if (i < 4) s.addShape(pres.shapes.RIGHT_ARROW, { x: x + 2.22, y: 1.75, w: 0.26, h: 0.35, fill: { color: H.grey }, line: { color: H.grey } });
});
[["0.39%", "进入判读的识别错误（原 3.9%）"], ["100%", "感染干扰提示（对照组 60%）"], ["0", "看不清却说「正常」的错误安慰"], ["100%", "难题「回答到所问」（原 54%）"]].forEach(([b, l], i) => {
  const x = 0.6 + i * 3.05;
  T(s, b, { x, y: 2.75, w: 2.9, h: 0.9, fontSize: 40, bold: true, color: i === 2 ? H.a2 : H.a1, valign: "bottom" });
  T(s, l, { x, y: 3.7, w: 2.9, h: 0.6, fontSize: 13 });
});
phone(s, "app_解读总览.png", 10.7, 4.35, 2.4);
T(s, "大模型不做医学判断：只读懂问题、从固定工具中挑要查的资料，再把规则结论说成白话；越界提问一律转为安全回复。", { x: 0.6, y: 4.6, w: 9.6, h: 0.9, fontSize: 15 });
T(s, "以上为合成数据测试结果；判读规则与知识尚未经医学专家审核。", { x: 0.6, y: 6.3, w: 9.6, h: 0.4, fontSize: 12, color: H.grey });
s.addNotes("（约 30 秒）第一项核心技术是可信的报告解读。照片在本机识别，看不清的地方请用户确认，再由三值逻辑规则判读，看不清的项目绝不当成正常。大模型只负责读懂问题、挑资料、把结论说成白话。在合成数据上，识别错误从 3.9% 降到 0.39%，感染干扰提示从 60% 提升到 100%，难题的回答到所问从 54% 提升到 100%。");

// 6 核心技术② ——————————————————————————————————
s = content("核心技术②：机器人守护闭环");
const flows = [
  ["按时用药", ["到点提醒", "导航到身边", "机械臂递药", "珍珠鸟打卡"], ["done", "proto", "proto", "done"]],
  ["跌倒守护", ["摄像头检测", "语音询问", "无回应通知家属"], ["proto", "dev", "dev"]],
  ["低血糖晕倒守护", ["血糖记录偏低", "主动巡视确认", "递糖并通知家属"], ["done", "future", "future"]],
];
flows.forEach(([name, st, kinds], r) => {
  const y = 1.45 + r * 1.6;
  T(s, name, { x: 0.6, y: y + 0.2, w: 2.2, h: 0.6, fontSize: 18, bold: true, color: r === 2 ? H.a2 : H.dk2, valign: "middle" });
  st.forEach((t, i) => {
    const x = 2.75 + i * 2.1;
    box(s, x, y, 1.8, 0.85, H.lt2);
    T(s, t, { x: x + 0.08, y, w: 1.64, h: 0.85, fontSize: 14, bold: true, align: "center", valign: "middle" });
    tag(s, x + 0.17, y + 0.92, kinds[i]);
    if (i < st.length - 1) s.addShape(pres.shapes.RIGHT_ARROW, { x: x + 1.82, y: y + 0.25, w: 0.26, h: 0.35, fill: { color: H.grey }, line: { color: H.grey } });
  });
});
phone(s, "app_珍珠鸟生活页.png", 11.35, 1.45, 3.9);
T(s, "珍珠鸟：打卡与血糖达标时开心跳跃；不达标时担心你，话语只关心、不责备", { x: 0.6, y: 6.35, w: 10, h: 0.4, fontSize: 13, color: H.grey });
s.addNotes("（约 30 秒）第二项是机器人守护闭环。按时用药：到点提醒，机器人导航到老人身边，用机械臂递药，完成后珍珠鸟打卡。跌倒守护：摄像头检测到跌倒，先语音询问，没有回应就通知家属。低血糖晕倒守护是我们的下一步：结合血糖记录主动巡视。图中标签如实标出哪些已实现、哪些还在开发。");

// 7 研发历程 ——————————————————————————————————
s = content("研发历程：我们与原型机的故事");
const tl = ["软件起步：报告解读与安全拦截", "陪伴：珍珠鸟打卡与提醒", "接上原型机：导航 · 摄像头 · 机械臂", "场景联调：用药递送与跌倒守护"];
tl.forEach((t, i) => {
  const x = 0.6 + i * 3.1;
  s.addShape(pres.shapes.OVAL, { x: x + 1.25, y: 1.5, w: 0.45, h: 0.45, fill: { color: i < 2 ? H.a1 : H.a3 }, line: { color: i < 2 ? H.a1 : H.a3 } });
  if (i < 3) s.addShape(pres.shapes.LINE, { x: x + 1.7, y: 1.725, w: 2.65, h: 0, line: { color: "C8D2D0", width: 2 } });
  T(s, t, { x, y: 2.05, w: 2.95, h: 0.8, fontSize: 14, bold: true, align: "center" });
});
todo(s, 0.6, 3.1, 3.9, 2.9, "原型机照片（整机）");
todo(s, 4.7, 3.1, 3.9, 2.9, "开发过程照片 / 视频截图\n（导航、摄像头、机械臂各一张）");
todo(s, 8.8, 3.1, 3.9, 2.9, "遇到的问题与解决\n（一句话＋一张图）");
s.addNotes("（约 25 秒）【由「我们与原型机的故事」负责同学补充】我们先做软件：报告解读与安全拦截，再加入珍珠鸟陪伴；之后把它接上原型机，加入导航、摄像头和机械臂三个新功能，正在进行用药递送和跌倒守护的场景联调。（这里讲一个开发中遇到的真实问题与解决办法。）");

// 8 创新点与展望 ——————————————————————————————
s = content("创新点与未来展望");
const inno = [
  ["新颖性", "规则下结论、大模型只说明；看不清不当正常"],
  ["应用前景", "居家与养老场景：报告解读＋用药＋跌倒守护一体"],
  ["科学性", "合成数据对照实验，每项结论可追溯到规则与出处"],
  ["设计表达", "珍珠鸟陪伴、白话呈现、老年模式与语音"],
];
inno.forEach(([t, b], i) => {
  const y = 1.45 + i * 1.15;
  box(s, 0.6, y, 6.3, 1.0, H.lt2);
  T(s, t, { x: 0.85, y, w: 1.6, h: 1.0, fontSize: 17, bold: true, color: H.a1, valign: "middle" });
  T(s, b, { x: 2.5, y, w: 4.25, h: 1.0, fontSize: 14, valign: "middle" });
});
box(s, 7.2, 1.45, 5.5, 4.45, H.warm);
T(s, "未来展望", { x: 7.5, y: 1.6, w: 5, h: 0.5, fontSize: 20, bold: true, color: H.a2 });
T(s, [
  { text: "升级机器人载体", options: { bold: true, breakLine: true } },
  { text: "原型机较小较矮，后续升级为带屏幕、可移动的陪护机器人，适合老人直接操作", options: { breakLine: true } },
  { text: " ", options: { breakLine: true } },
  { text: "跌倒守护 · 低血糖晕倒守护", options: { bold: true, breakLine: true } },
  { text: "视觉检测结合血糖记录，异常时主动确认并通知家属", options: { breakLine: true } },
  { text: " ", options: { breakLine: true } },
  { text: "医学审核与真实场景试用", options: { bold: true, breakLine: true } },
  { text: "规则与知识经专业审核后，再进入养老机构试点", options: {} },
], { x: 7.5, y: 2.2, w: 5.0, h: 3.6, fontSize: 14 });
T(s, "让每一位糖尿病患者：看得懂报告，也有人守着日常。", { x: 0.6, y: 6.3, w: 12.1, h: 0.45, fontSize: 17, bold: true, color: H.dk2, align: "center" });
s.addNotes("（约 25 秒）我们的创新对应四个方面：规则下结论的可信设计、居家养老一体化的应用前景、可追溯的对照实验，以及珍珠鸟和白话呈现的设计表达。未来我们会把原型机升级为带屏幕、更适合老人操作的陪护机器人，加入跌倒和低血糖晕倒守护，并在医学审核后进入真实场景试用。谢谢各位评委。");

pres.writeFile({ fileName: OUT }).then(() => console.log("已生成 " + OUT));
