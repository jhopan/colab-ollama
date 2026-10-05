#!/bin/bash
# colab-ollama keepalive.sh — SEL 2: cegah runtime Colab idle-timeout
# Ping Ollama + SearXNG local + tulis /content tiap interval (reset idle timer Colab).
# Jalankan di background. Cara pakai di Colab (sel 2):
#   !curl -fsSL https://raw.githubusercontent.com/jhopan/colab-ollama/main/keepalive.sh | bash

set -uo pipefail

PORT=11434
SEARCH_PORT=8081
INTERVAL="${INTERVAL:-1500}"   # 25 menit (< 90m idle timeout)
LOG=/tmp/keepalive.log

echo "keepalive aktif. Interval ${INTERVAL}s. Ollama :$PORT, SearXNG :$SEARCH_PORT"

# Hentikan instance lama biar tak dobel
pkill -f "colab-ollama-keepalive-loop" 2>/dev/null || true
sleep 1

# Loop di background (nama process unik untuk pkill)
nohup bash -c '
P="$1"; S="$2"; I="$3"; shift 3
while true; do
  ts=$(date "+%Y-%m-%d %H:%M:%S")
  echo "$ts ping" >> /content/.keepalive.log 2>/dev/null || true
  if curl -s --max-time 15 "http://localhost:$P/v1/models" > /dev/null 2>&1; then
    echo "$ts ollama OK" >> /tmp/keepalive.log 2>/dev/null
  else
    echo "$ts ollama FAIL" >> /tmp/keepalive.log 2>/dev/null
  fi
  curl -s --max-time 10 "http://localhost:$S/health" > /dev/null 2>&1 || true
  sleep "$I"
done' colab-ollama-keepalive-loop "$PORT" "$SEARCH_PORT" "$INTERVAL" > /dev/null 2>&1 &
KEEPPID=$!
echo "$KEEPPID" > /tmp/keepalive.pid
echo "keepalive PID $KEEPPID di-background. Cek: tail $LOG"
echo "Stop: kill \$(cat /tmp/keepalive.pid)"
