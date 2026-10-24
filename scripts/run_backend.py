"""一条命令启动后端（无需 Docker）。

用法：python scripts/run_backend.py [--port 8000] [--install]
  --install  首次运行时创建 backend/.venv 并安装依赖（使用国内 PyPI 镜像，仅开发环境）
模拟器访问本机后端地址为 http://10.0.2.2:8000
"""
import argparse
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BACKEND = ROOT / "backend"
VENV = BACKEND / ".venv"
PY = VENV / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
MIRROR = os.environ.get("PIP_INDEX_URL", "https://mirrors.aliyun.com/pypi/simple/")


def main() -> None:
    # 兼容繁体/其他代码页的 Windows 控制台（如 cp950），避免打印中文时崩溃
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--install", action="store_true")
    args = ap.parse_args()
    if args.install or not PY.exists():
        if not PY.exists():
            subprocess.check_call([sys.executable, "-m", "venv", str(VENV)])
        subprocess.check_call([str(PY), "-m", "pip", "install", "-q", "-i", MIRROR, "-r", str(BACKEND / "requirements.txt")])
    print(f"MediLens 后端启动：http://127.0.0.1:{args.port}/docs （模拟器内访问 http://10.0.2.2:{args.port}）")
    subprocess.call([str(PY), "-m", "uvicorn", "app.main:app", "--host", args.host, "--port", str(args.port)], cwd=BACKEND)


if __name__ == "__main__":
    main()
