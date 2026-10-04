#!/bin/bash
# colab-ollama keepalive.sh
# Cegah Google Colab idle timeout (90 menit) dengan ping API Ollama tiap 30 menit.
# Jalankan di background setelah install.sh selesai.
#
# Cara pakai di Colab:
#   nohup bash keepalive.sh > /tmp/keepalive.log 2>&1 &

set -uo pipefail

PORT=11434
INTERVAL="${INTERVAL:-1800}"   # 30 menit

# Ambil base URL dari install.sh
BASE="http://localhost:$PORT"

echo "keepalive aktif. Interval ${INTERVAL}s. Target $BASE"

while true; do
    ts=$(date '+%H:%M:%S')
    # Ping /v1/models — ringan, tak pakai model
    if curl -s --max-time 10 "$BASE/v1/models" > /dev/null 2>&1; then
        echo "$ts ping OK"
    else
        echo "$ts ping FAIL (Ollama mati? cek /tmp/ollama.log)"
    fi
    sleep "$INTERVAL"
done
