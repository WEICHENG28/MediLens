#!/usr/bin/env bash
# MediLens 后端服务器部署（Ubuntu 22.04 以上，不需要 sudo）。可重复执行：第二次执行即为「更新到最新版」。
#
# 在服务器终端执行（全部小写，方便在不能输入大写的远程桌面里打字）：
#   wget raw.githubusercontent.com/weicheng28/medilens/dev/scripts/server-setup.sh
#   bash server-setup.sh
#
# 服务器连不上 GitHub 时，改用部署包 medilens-server.zip（放到服务器的主目录后）：
#   python3 -m zipfile -e medilens-server.zip medilens
#   bash medilens/scripts/server-setup.sh
#
# 做的事：下载代码 → 建 Python 虚拟环境并安装依赖 → 生成 .env（含访问口令）→ 设定开机自动启动 → 启动后端。
# 大模型密钥不会由本脚本写入，需要本人用 nano 填写（见最后的提示）。
set -u

REPO="WEICHENG28/MediLens"
BRANCH="dev"
DIR="$HOME/MediLens"
PIP_INDEX="https://mirrors.aliyun.com/pypi/simple/"
PORT=8000

say() { printf '\n== %s\n' "$*"; }
fail() { printf '\n✗ %s\n' "$*"; exit 1; }

say "1/6 检查环境"
. /etc/os-release 2>/dev/null && echo "系统：${PRETTY_NAME:-未知}"
command -v python3 >/dev/null || fail "找不到 python3，请联系管理员安装 Python 3.10 以上"
python3 -c 'import sys; assert sys.version_info >= (3, 10)' || fail "Python 版本需要 3.10 以上：$(python3 -V)"
echo "Python：$(python3 -V 2>&1)"
echo "IP 地址：$(hostname -I 2>/dev/null)"
for u in https://github.com https://mirrors.aliyun.com https://llmapi.paratera.com; do
  code=$(curl -s -m 8 -o /dev/null -w '%{http_code}' "$u" || true)
  echo "联网 $u → ${code:-失败}"
done

SRC_DIR="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)"
if [ -f "$SRC_DIR/backend/requirements.txt" ] && [ ! -d "$SRC_DIR/.git" ]; then
  # 从部署包（压缩包）解压后执行：直接使用解压出的目录，不连 GitHub
  DIR="$SRC_DIR"
  say "2/6 使用部署包中的代码：$DIR"
elif command -v git >/dev/null && [ -d "$DIR/.git" ]; then
  say "2/6 更新代码：$DIR"
  git -C "$DIR" fetch --depth 1 origin "$BRANCH" && git -C "$DIR" reset --hard "origin/$BRANCH" || fail "更新代码失败（检查是否已登录校园网）"
elif command -v git >/dev/null && [ ! -e "$DIR" ]; then
  git clone --depth 1 -b "$BRANCH" "https://github.com/$REPO.git" "$DIR" || fail "下载代码失败（检查是否已登录校园网）"
else
  # 没有 git，或目录不是 git 仓库：下载压缩包覆盖代码，保留 .env 与虚拟环境
  python3 - "$REPO" "$BRANCH" "$DIR" <<'PY' || fail "下载代码失败（检查是否已登录校园网）"
import io, shutil, sys, urllib.request, zipfile
from pathlib import Path
repo, branch, dest = sys.argv[1], sys.argv[2], Path(sys.argv[3])
data = urllib.request.urlopen(f"https://codeload.github.com/{repo}/zip/refs/heads/{branch}", timeout=120).read()
z = zipfile.ZipFile(io.BytesIO(data))
root = z.namelist()[0].split("/")[0]
dest.mkdir(parents=True, exist_ok=True)
for name in z.namelist():
    rel = name[len(root) + 1:]
    if not rel or name.endswith("/"):
        continue
    target = dest / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    with z.open(name) as src, open(target, "wb") as out:
        shutil.copyfileobj(src, out)
print("已下载并解压", len(z.namelist()), "个文件")
PY
fi

say "3/6 建立 Python 虚拟环境并安装依赖（首次约 1–3 分钟）"
VENV="$DIR/backend/.venv"
if [ ! -x "$VENV/bin/python" ]; then
  if ! python3 -m venv "$VENV" 2>/dev/null; then
    echo "系统缺少 venv 组件，改用不需要 sudo 的方式安装 pip"
    rm -rf "$VENV"
    python3 -m venv --without-pip "$VENV" || fail "无法建立虚拟环境"
    curl -s -m 60 https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py || fail "下载 get-pip 失败"
    "$VENV/bin/python" /tmp/get-pip.py -q -i "$PIP_INDEX" || fail "安装 pip 失败"
  fi
fi
"$VENV/bin/python" -m pip install -q -i "$PIP_INDEX" -r "$DIR/backend/requirements.txt" \
  || "$VENV/bin/python" -m pip install -q -i https://pypi.tuna.tsinghua.edu.cn/simple -r "$DIR/backend/requirements.txt" \
  || fail "安装依赖失败（阿里云与清华镜像都连不上）"
echo "依赖安装完成"

say "4/6 设定 .env（已存在则保留，不覆盖）"
ENV_FILE="$DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  TOKEN=$(python3 -c 'import secrets, string; a = string.ascii_lowercase + string.digits; print("".join(secrets.choice(a) for _ in range(8)))')
  cat > "$ENV_FILE" <<EOF
# MediLens 服务器设定。此文件只在服务器上，不要上传、不要截图分享。
LLM_PROVIDER=compat
COMPAT_BASE_URL=https://llmapi.paratera.com
COMPAT_MODEL=DeepSeek-V4.1-Flash
COMPAT_DISABLE_THINKING=true
LLM_TIMEOUT=15
# 把学校大模型平台的密钥填在等号后面（留空时自动使用不调用大模型的模式）
COMPAT_API_KEY=
# 访问口令：APP「设置 → 访问口令」要填同一组
API_TOKEN=$TOKEN
EOF
  chmod 600 "$ENV_FILE"
  echo "已生成 .env"
fi

say "5/6 设定开机自动启动"
RUN="bash $DIR/scripts/server-run.sh"
( crontab -l 2>/dev/null | grep -v 'scripts/server-run.sh'; echo "@reboot sleep 20 && $RUN" ) | crontab - && echo "已加入开机自动启动（crontab）"

say "6/6 启动后端"
bash "$DIR/scripts/server-run.sh"

TOKEN_NOW=$(grep '^API_TOKEN=' "$ENV_FILE" | cut -d= -f2)
KEY_SET=$(grep -q '^COMPAT_API_KEY=.\+' "$ENV_FILE" && echo 已填写 || echo 未填写)
cat <<EOF

================ 部署完成 ================
APP「设置 → 解读服务地址」：http://$(hostname -I | awk '{print $1}'):$PORT
APP「设置 → 访问口令」：$TOKEN_NOW
大模型密钥：$KEY_SET
$( [ "$KEY_SET" = 未填写 ] && echo "→ 请本人执行：nano $ENV_FILE 填写 COMPAT_API_KEY，存档后执行：bash $DIR/scripts/server-run.sh" )
更新到最新版：bash $DIR/scripts/server-setup.sh
查看日志：tail -n 30 $HOME/medilens-backend.log
==========================================
EOF
