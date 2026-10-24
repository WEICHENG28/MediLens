# MediLens

面向糖尿病患者的尿常规 / UACR 报告智能解读 APP（课程项目，MVP 2.0「项目可运行」）。

> ⚠️ **内部开发版**：所有判读规则均为**测试规则，未经医学审核**；知识库为开发团队自编的**占位说明**（非指南原文）；只使用**合成报告**测试。不得用于真实患者诊疗。

- 需求基线：[docs/MediLens_MVP1_跨模型开发交接说明.md](docs/MediLens_MVP1_跨模型开发交接说明.md)
- 设计记录（小组文档）：[docs/MVP2_设计记录.md](docs/MVP2_设计记录.md)
- 开发进展（每轮迭代）：[docs/开发进展.md](docs/开发进展.md)
- **测试与课堂演示指南**：[docs/MVP2_测试与演示指南.md](docs/MVP2_测试与演示指南.md)（一键启动：`powershell -ExecutionPolicy Bypass -File scripts\start_demo.ps1`）
- 网络请求清单与大陆网络测试方案：[docs/网络请求清单与大陆网络测试.md](docs/网络请求清单与大陆网络测试.md)

## 目录结构

```
app/        Flutter 客户端（Android / iOS）
  lib/ocr/        端侧 OCR：PP-OCRv5 ONNX 推理、后处理、报告解析、图像质量
  lib/features/   页面：P01 启动 / 主页 / P02 导入 / P03 局部确认 / P04 总览 / P05 选择题 / P06 详细了解+对话 / 保存 / P09 历史 / P10 复诊问题 / P11 设置 / 待实现页
  assets/ocr/     端侧 OCR 模型（随 APP 打包，不联网下载）
  test/           单元测试（解析器用合成报告的真实 OCR 输出）
  integration_test/ 端到端测试（模拟器 + 本机后端，普通/老年模式各一遍）
backend/    FastAPI 后端：标准化、规则引擎、选择题、详细了解、对话、大模型 adapter、输出校验、待实现接口
  app/knowledge_base/  指标字典、测试规则、选择题、占位知识（YAML，可版本化）
tests/fixtures/  合成报告图片（*.synthetic.png，带「合成测试样本」水印）与标注
tools/      合成报告生成、OCR 参考实现、网络合规检查
scripts/    一条命令启动后端、开发环境变量
```

## 环境要求

| 组件 | 版本 | 说明 |
|---|---|---|
| Python | 3.11+ | 后端 |
| Flutter | 3.47.8 stable（Dart 3.13） | 客户端 |
| JDK | 17 | Android 构建 |
| Android SDK | platform 35/36、build-tools 35、NDK 28.2.13676358 | Android 构建 |

本仓库开发机把工具链放在 `.toolchain/`（不入库）。加载环境变量：

```powershell
. .\scripts\dev-env.ps1        # PowerShell；设置 JAVA_HOME / ANDROID_HOME / PATH 与国内镜像
```

开发依赖镜像（**仅开发环境**，与 APP 运行时网络无关）：pub → `pub.flutter-io.cn`，Flutter SDK → `storage.flutter-io.cn`，pip → `mirrors.aliyun.com/pypi`。

## 启动

### 1. 后端（一条命令）

```bash
python scripts/run_backend.py            # 首次自动创建 backend/.venv 并安装依赖
# API 文档：http://127.0.0.1:8000/docs     模拟器内访问：http://10.0.2.2:8000
```

未配置大模型密钥时自动使用 mock，全流程可跑通。需要真实模型时：复制 `.env.example` 为 `.env`，设置 `LLM_PROVIDER=deepseek`（或 qwen / zhipu）并填写密钥。**密钥只放后端，`.env` 不入库。**

Docker（⚠️ 开发机未安装 Docker，**以下未经实测**）：

```bash
docker compose up --build
```

### 2. Android APP

```powershell
. .\scripts\dev-env.ps1
emulator -avd MediLens_API35          # 或连接开启 USB 调试的真机
cd app
flutter run                           # 默认后端地址 http://10.0.2.2:8000（模拟器访问开发机）
# 真机：flutter run --dart-define=API_BASE_URL=http://<电脑局域网IP>:8000
```

构建安装包：`flutter build apk --debug`，输出 `app/build/app/outputs/flutter-apk/app-debug.apk`。

### 3. iOS

没有 Mac 环境，**iOS 未编译验证**。代码未使用仅 Android 的 API；ONNX Runtime、SQLCipher、TTS 等插件均支持 iOS。在 Mac 上：`cd app && flutter build ios --no-codesign`。`ios/Runner/Info.plist` 已加入相机、相册、麦克风权限说明与本地网络访问（开发用）。

## 使用合成报告走完整流程

1. 启动后端与 APP → 「游客体验」
2. 主页「体验合成示例报告（演示用）」选择一份（或把 `tests/fixtures/*.synthetic.png` 推到模拟器相册：`adb push tests/fixtures/02_glucose_ketone.synthetic.png /sdcard/Pictures/` 后从相册选择）
3. 开始识别（本机 OCR）→ 局部确认 → 同意发送指标 → 总览 → 补充问题 → 详细了解 → 提问 → 保存/不保存
4. 设置中可切换老年模式，流程相同

| 合成样本 | 预期 |
|---|---|
| 01 正常尿常规 | 命中 R-06（绿色） |
| 02 尿糖+酮体阳性 | R-01 红色 + 紧急提示置顶 |
| 03 尿蛋白被遮挡 | 触发局部确认（候选 2+/1+/3+） |
| 04 UACR+感染 | R-03 黄色；回答「首次」后 R-04 |
| 05 UACR mg/mmol | 单位换算 ≈46 mg/g |
| 06 缺参考范围 | 按字典通用参考比对并注明 |
| 07 肝功能 | 提示不支持该报告 |
| 08 横置 | 自动旋转后识别 |
| 09 模糊 | 质量提示重拍 |

## 测试

```bash
# 后端
cd backend && .venv/Scripts/python -m pytest -q        # Linux/macOS: .venv/bin/python

# 客户端单元测试
cd app && flutter test

# 端到端（需先启动后端与模拟器）
cd app && flutter test integration_test/app_flow_test.dart -d emulator-5554

# 网络合规检查（源码 + APK）
python tools/check_network.py --apk app/build/app/outputs/flutter-apk/app-debug.apk

# 重新生成合成报告 / OCR 参考输出
python tools/gen_synthetic_reports.py
tools/.venv/Scripts/python -I tools/ocr_reference.py --export
```

## 本轮范围与待实现

已实现（阶段 1 核心链路）：游客模式、拍照/相册/文件（图片+PDF 首页）、本地 OCR、局部确认、测试规则引擎、总览、动态选择题、逐条详细了解、文字对话、本机加密保存/不保存、历史删除、复诊问题、设置中心、普通/老年模式。

保留入口、接口与数据结构，标注「待实现」：实时语音（可打断）、药盒识别、注册登录、云端 OCR、云端备份/恢复、趋势图、复查提醒。

## 安全与隐私约定

- 不提交 API 密钥、`.env`、真实报告图片；只提交 `.env.example`
- 游客原始报告图片只在本机识别，不上传；解读只发送确认后的指标（不含姓名、医院）
- APP 不使用 Google 服务、Firebase、Google Fonts、境外 CDN；大模型只接入国内服务
