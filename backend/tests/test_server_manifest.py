"""服务器部署清单 scripts/server-files.txt 必须与仓库中的后端文件一致。

服务器连不上 GitHub 时经 jsDelivr 部署；jsDelivr 的分支文件列表有缓存（会缺新文件），
因此部署脚本按指定提交下载这份清单，再逐个下载文件。新增或删除后端文件后请重新生成：
  git ls-files backend "scripts/server-*" .env.example tools/check_llm.py | sort > scripts/server-files.txt
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]


def test_server_manifest_matches_tracked_files():
    try:
        out = subprocess.run(["git", "ls-files", "backend", "scripts/server-*", ".env.example", "tools/check_llm.py"],
                             cwd=ROOT, capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        pytest.skip("没有 git（例如在服务器上运行测试）")
    tracked = set(out.split()) | {"scripts/server-files.txt"}
    listed = set((ROOT / "scripts" / "server-files.txt").read_text(encoding="utf-8").split())
    assert listed == tracked, f"清单需要更新：缺少 {sorted(tracked - listed)}，多余 {sorted(listed - tracked)}"
