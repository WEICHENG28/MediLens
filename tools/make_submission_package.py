"""生成比赛「作品其他材料」网盘上传包（匿名：不含学校、教师、账号、密钥、服务器地址）。

输出两个压缩包，命名遵循大赛规则「参赛团队编号-赛题名称-作品名称-XX（材料名称）」：
  <编号>-AI+医学-<作品名称>-完整代码包.zip      代码、测试、评测脚本、知识库、核心文档
  <编号>-AI+医学-<作品名称>-合成测试数据集.zip  评测用合成报告图片与标注（开发集/测试集/测试集2）
用法：python tools/make_submission_package.py <输出目录> [团队编号，默认 XXXX]
代码包只打包 git 已跟踪的文件，因此 .env、密钥、构建产物不会进入压缩包；数据集收录 tests/eval/{dev,test,test2} 整个目录。
"""
from __future__ import annotations

import re
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NAME = "MediLens糖尿病尿检报告可信解读"
CONTEST = "AI+医学"

DATA_PREFIXES = ("tests/eval/dev/", "tests/eval/test/", "tests/eval/test2/")
# 内部协作、竞赛材料生成与含个人信息的文件不进入代码包
EXCLUDE_PREFIXES = DATA_PREFIXES + ("tools/aic_report/", "docs/figures/", "docs/归档/")
EXCLUDE_FILES = {
    "README.md",  # 由 代码说明 替换
    "tools/make_team_figures.py", "tools/kb_draft_team.py", "tools/make_submission_package.py",
    "scripts/server-setup.sh", "scripts/server-run.sh", "scripts/start_demo.ps1", "scripts/fit_emulator_window.ps1", "scripts/dev-env.ps1",
    "docs/文档导览.md", "docs/演示录制脚本.md", "docs/开发进展.md", "docs/服务器部署与启动指南.md",
    "docs/组员电脑安装与运行指南.md", "docs/MediLens成果与技术说明（组员版）.md", "docs/组员资料核查与知识库建议.md",
    "docs/MVP2_测试与演示指南.md", "docs/知识库初稿_组员资料核实版.xlsx", "docs/知识库资料调研.md",
}
# 文本中需要替换的字样（出现学校/教师/账号等信息的位置）
SCRUB = [
    (r"老师提供正式资料后", "取得正式资料后"),
    (r"老师提供授权、脱敏的真实报告", "取得授权、脱敏的真实报告"),
    (r"学校提供的多模型聚合平台，并行科技", "第三方多模型聚合平台"),
    (r"学校等多模型聚合平台", "OpenAI 兼容的多模型聚合平台"),
    (r"学校多模型平台", "多模型聚合平台"),
    (r"学校提供的", ""),
    (r"学校平台", "该平台"),
    (r"学校等 ?", ""),
    (r"学校服务器", "服务器"),
]
def _local_secrets() -> list[str]:
    """从本机 .env 读取访问口令等机密，打包时用来检查有没有混进压缩包（机密本身不写进代码）。"""
    env = ROOT / ".env"
    out = []
    if env.exists():
        for line in env.read_text(encoding="utf-8-sig").splitlines():
            k, _, v = line.partition("=")
            if v.strip() and any(t in k.upper() for t in ("TOKEN", "KEY", "SECRET", "SERVER")):
                out.append(re.escape(v.strip().strip("\"'")))
    return out


SENSITIVE = re.compile("|".join([r"清华|tsinghua|aiop|101\.6\.1|weicheng|陈威诚|杨明亮|指导教师|sk-[A-Za-z0-9]{10,}"] + _local_secrets()), re.I)


def tracked() -> list[str]:
    out = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT, capture_output=True, check=True).stdout
    return [p for p in out.decode("utf-8").split("\0") if p]


def is_text(path: str) -> bool:
    return path.endswith(".example") or Path(path).suffix.lower() in {".py", ".md", ".yaml", ".yml", ".txt", ".dart", ".json", ".ps1", ".sh", ".toml", ".xml", ".gradle", ".kts", ".properties", ".html", ".js"}


def scrub(path: str, data: bytes) -> bytes:
    if not is_text(path):
        return data
    text = data.decode("utf-8", errors="ignore")
    for a, b in SCRUB:
        text = re.sub(a, b, text)
    return text.encode("utf-8")


README = f"""# {NAME} · 代码说明

面向糖尿病患者的尿常规 / UACR 报告解读系统：手机端本地识别 → 低置信字段原图确认 → 三值逻辑组合规则判读 →
检索约束的通俗解释（大模型只改写）→ 两层越界拦截；另含「生活打卡 · 陪伴宠物」原型。

> 所有评测均基于**合成数据**（带「合成测试样本」水印，固定随机种子可复现）；判读规则与知识库**未经医学专家审核**，不得用于真实诊疗。

## 目录

| 路径 | 内容 |
|---|---|
| `app/` | Flutter 客户端（Android）：端侧 OCR（`lib/ocr/`）、页面（`lib/features/`）、单元测试 `test/`、端到端测试 `integration_test/` |
| `app/assets/ocr/` | PP-OCRv5 mobile 检测与识别模型（ONNX）与字典，见该目录 `MODEL_SOURCE.md` |
| `backend/app/` | FastAPI 后端：`normalize`（标准化）、`rules_engine`（三值逻辑规则）、`followup`（动态追问）、`knowledge`（检索）、`chat`/`guard`/`llm`（受约束生成、校验、意图识别）、`lifestyle`（生活规律分析、宠物、自适应提醒） |
| `backend/app/knowledge_base/` | 指标字典、规则库、追问库、知识库（YAML，可版本化） |
| `backend/tests/` | 后端单元测试（112 项） |
| `tools/eval/` | 评测脚本：识别、规则、越界拦截、对照大模型实验 D、生活规律与自适应提醒 |
| `tools/gen_synthetic_reports.py` | 合成报告生成器 |
| `tests/fixtures/` | 少量合成报告样例与标注 |
| `tests/eval/` | 评测结果 JSON 与越界提问题库（两轮）；评测用合成图片见「合成测试数据集」压缩包 |
| `docs/` | 测试结果（含全部实验）、设计记录、网络请求清单、知识库填写指南、界面截图 |

## 运行后端（Python 3.10+）

```
cd backend
python -m venv .venv && .venv/Scripts/pip install -r requirements.txt   # Linux/macOS 为 .venv/bin/pip
.venv/Scripts/python -m pytest -q            # 单元测试，离线运行（自动使用不调用大模型的 mock 模式）
.venv/Scripts/python -m uvicorn app.main:app --port 8000
```

大模型为可选：复制 `.env.example` 为 `.env`，填写 OpenAI 兼容接口的地址、模型与**自己的**密钥（本包不含任何密钥）；不配置时全部功能照常运行，只是回答不做口语改写。

## 构建客户端（Flutter 3.47，Dart 3.13）

```
cd app
flutter pub get
flutter test                                  # 单元测试
flutter build apk --debug --dart-define=API_BASE_URL=http://<后端地址>:8000
```

## 复现实验

先解压「合成测试数据集」到 `tests/eval/`（得到 `dev/`、`test/`、`test2/`），然后见 `docs/MVP2_测试结果.md` 末尾的命令：
- 规则判读（1000 份随机报告）：`python tools/eval/eval_rules.py`
- 越界拦截（两轮题库）：`python tools/eval/eval_boundary.py <题库.yaml>`
- 生活规律与自适应提醒：`python tools/eval/eval_lifestyle.py`
- 识别评测需要 Flutter 工具：`dart run tool/eval_ocr.dart test2`（在 `app/` 下）

## 第三方组件与数据来源

- OCR 模型：PaddleOCR 的 PP-OCRv5 mobile（Apache-2.0），经 ONNX 转换后随应用打包；运行时不联网下载。
- 主要依赖：Flutter 及 pub.dev 包（见 `app/pubspec.yaml`）、FastAPI / Pydantic / httpx / PyYAML / OpenCC（见 `backend/requirements.txt`）。
- 知识库中的 14 条条目改写自公开指南与论文，每条附出处（作者、期刊、年份）与「未经医学审核」标注；另有 7 条自编占位说明，界面标注「非指南原文」。
- 全部报告图片均由程序生成，不含任何真实患者数据。
"""


def main() -> None:
    sys.stdout.reconfigure(encoding="utf-8")
    out = Path(sys.argv[1])
    team = sys.argv[2] if len(sys.argv) > 2 else "XXXX"
    out.mkdir(parents=True, exist_ok=True)
    files = tracked()
    code = [p for p in files if p not in EXCLUDE_FILES and not p.startswith(EXCLUDE_PREFIXES)]
    # 评测图片未纳入 git（体积大），直接从工作目录收录整个数据集目录
    data = sorted(f.relative_to(ROOT).as_posix() for pre in DATA_PREFIXES for f in (ROOT / pre).rglob("*") if f.is_file())
    base = f"{team}-{CONTEST}-{NAME}"

    problems = []
    with zipfile.ZipFile(out / f"{base}-完整代码包.zip", "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("README.md", README)
        for p in code:
            blob = scrub(p, (ROOT / p).read_bytes())
            if is_text(p) and SENSITIVE.search(blob.decode("utf-8", errors="ignore")):
                problems.append(p)
            z.writestr(p, blob)
    with zipfile.ZipFile(out / f"{base}-合成测试数据集.zip", "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("说明.txt", "本数据集全部为程序生成的合成尿检报告图片及标注（固定随机种子，可复现），不含任何真实患者数据。\n"
                              "dev 为开发集（种子 20261025），test 为测试集（种子 77031），test2 为测试集 2（种子 50917）。\n"
                              "解压到代码包的 tests/eval/ 目录下即可复现评测。\n")
        for p in data:
            z.write(ROOT / p, p)
    print(f"代码包 {len(code)} 个文件，数据集 {len(data)} 个文件")
    if problems:
        print("⚠ 仍含敏感字样：", *problems, sep="\n  ")
        sys.exit(1)
    print("敏感字样检查：通过")


if __name__ == "__main__":
    main()
