#!/usr/bin/env bash
# 启动（或重新启动）MediLens 后端。开机时由 crontab 自动执行；修改 .env 后手动执行一次即可生效。
# 8000：HTTP（报告解读等，旧版 APP 仍可用）；8443：HTTPS（账户与个人资料只走这里），证书由 server-setup.sh 生成。
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$HOME/medilens-backend.log"
TLS_LOG="$HOME/medilens-backend-tls.log"
PORT=8000
TLS_PORT=8443
CERT="$DIR/tls/cert.pem"
KEY="$DIR/tls/key.pem"

pkill -f "uvicorn app.main:app --host 0.0.0.0 --port" 2>/dev/null && sleep 1
cd "$DIR/backend" || exit 1
nohup "$DIR/backend/.venv/bin/python" -m uvicorn app.main:app --host 0.0.0.0 --port $PORT >"$LOG" 2>&1 &
if [ -f "$CERT" ] && [ -f "$KEY" ]; then
  nohup "$DIR/backend/.venv/bin/python" -m uvicorn app.main:app --host 0.0.0.0 --port $TLS_PORT \
    --ssl-certfile "$CERT" --ssl-keyfile "$KEY" >"$TLS_LOG" 2>&1 &
fi

for _ in $(seq 1 30); do
  if HEALTH=$(wget -qO- --timeout=2 --tries=1 "http://127.0.0.1:$PORT/api/v1/health" 2>/dev/null); then
    echo "✓ 后端已启动：$HEALTH"
    if [ -f "$CERT" ]; then
      sleep 2
      if wget -qO- --no-check-certificate --timeout=3 --tries=1 "https://127.0.0.1:$TLS_PORT/api/v1/health" >/dev/null 2>&1; then
        echo "✓ 加密连接（HTTPS $TLS_PORT）已启动"
      else
        echo "✗ 加密连接没有启动，日志："; tail -n 10 "$TLS_LOG"
      fi
    fi
    exit 0
  fi
  sleep 1
done
echo "✗ 后端 30 秒内没有启动，最后的日志："
tail -n 20 "$LOG"
exit 1
