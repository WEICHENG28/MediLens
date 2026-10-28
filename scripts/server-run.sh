#!/usr/bin/env bash
# 启动（或重新启动）MediLens 后端。开机时由 crontab 自动执行；修改 .env 后手动执行一次即可生效。
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$HOME/medilens-backend.log"
PORT=8000

pkill -f "uvicorn app.main:app --host 0.0.0.0 --port $PORT" 2>/dev/null && sleep 1
cd "$DIR/backend" || exit 1
nohup "$DIR/backend/.venv/bin/python" -m uvicorn app.main:app --host 0.0.0.0 --port $PORT >"$LOG" 2>&1 &

for _ in $(seq 1 30); do
  if curl -s -m 2 "http://127.0.0.1:$PORT/api/v1/health" >/dev/null; then
    echo "✓ 后端已启动：$(curl -s "http://127.0.0.1:$PORT/api/v1/health")"
    exit 0
  fi
  sleep 1
done
echo "✗ 后端 30 秒内没有启动，最后的日志："
tail -n 20 "$LOG"
exit 1
