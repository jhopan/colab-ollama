#!/bin/bash
# colab-ollama install.sh
# Jalankan di Google Colab: install Ollama + cloudflared, pull model,
# serve Ollama di background, buka Cloudflare Tunnel, print URL akses.
#
# Pakai di Colab dengan GPU T4 (16GB VRAM) atau CPU.
# Model default: qwen2.5:14b (OpenAI-compatible via /v1).

set -euo pipefail

MODEL="${MODEL:-qwen2.5:14b}"
OLLAMA_HOME="/usr/share/ollama"
PORT=11434
DRIVE_DIR="/content/drive/MyDrive/colab-ollama"

echo "=== colab-ollama install ==="
echo "Model: $MODEL"

# ---- 0. Deteksi lingkungan (Colab vs local) ----
IN_COLAB=false
if [ -d /content/drive ] || [ -d "/content" ]; then
    IN_COLAB=true
fi
echo "Environment: Colab=$IN_COLAB"

# ---- 1. Install Ollama (direct binary, skip installer that needs zstd) ----
OLLAMA_VERSION="0.35.1"
if command -v ollama &>/dev/null; then
    echo "Ollama sudah ada: $(ollama --version)"
else
    echo "Install Ollama binary v$OLLAMA_VERSION..."
    # Unduh binary langsung, extract ke /usr/local/bin
    OLLAMA_DL="/tmp/ollama-linux-amd64.tar.zst"
    curl -fsSL -o "$OLLAMA_DL" "https://github.com/ollama/ollama/releases/download/v$OLLAMA_VERSION/ollama-linux-amd64.tar.zst"
    # Extract: zstd if available, else apt-get install, else fallback
    if command -v tar &>/dev/null; then
        # Tar zst: modern GNU tar supports zstd natively
        tar --zstd -xf "$OLLAMA_DL" -C /usr/local 2>/dev/null || \
        {
            # If native tar fails, try zstd manual
            if ! command -v zstd &>/dev/null; then
                echo "Install zstd..."
                (apt-get update -qq && apt-get install -y zstd) || \
                (sudo apt-get update -qq && sudo apt-get install -y zstd)
            fi
            zstd -d "$OLLAMA_DL" -o /tmp/ollama.tar
            tar -xf /tmp/ollama.tar -C /usr/local
        }
    fi
    export PATH="$HOME/.local/bin:$PATH:/usr/bin:/usr/local/bin:$PATH"
    echo "Ollama version: $(ollama --version 2>&1 || echo 'binary tidak ada')"
    if ! command -v ollama &>/dev/null; then
        echo "ERROR: Ollama binary gagal diinstall."
        exit 1
    fi
fi

# ---- 2. Cache model ke Google Drive (Colab) ----
if [ "$IN_COLAB" = true ]; then
    mkdir -p "$DRIVE_DIR/ollama-models"
    # Arahkan Ollama ke storage Drive sehingga model tidak pull ulang tiap recycle
    # (Colab filesystem volatile; Drive persist)
    export OLLAMA_MODELS="$DRIVE_DIR/ollama-models"
    echo "Model cache: $OLLAMA_MODELS"
fi

# ---- 3. Hentikan Ollama lama kalau ada (dari session sebelumnya) ----
pkill -f "ollama serve" 2>/dev/null || true
sleep 1

# ---- 4. Serve Ollama di background (dulu) ----
echo "Serve Ollama di port $PORT..."
OLLAMA_HOST="0.0.0.0:$PORT" OLLAMA_MODELS="${OLLAMA_MODELS:-$HOME/.ollama/models}" nohup ollama serve > /tmp/ollama.log 2>&1 &
# Tunggu sampai siap (max 30 detik)
READY=0
for i in $(seq 1 30); do
    if curl -s --max-time 2 "http://localhost:$PORT/v1/models" > /dev/null 2>&1; then
        READY=1; break
    fi
    sleep 1
done
if [ "$READY" = 0 ]; then
    echo "ERROR: Ollama tidak hidup setelah 30 detik. Cek /tmp/ollama.log"
    tail -30 /tmp/ollama.log
    exit 1
fi
echo "Ollama siap di port $PORT"

# ---- 5. Pull model (server harus hidup dulu) ----
echo "Pull model $MODEL..."
PULLED=0
for i in 1 2 3; do
    if ollama pull "$MODEL" 2>&1; then
        PULLED=1; break
    fi
    echo "Pull gagal (percobaan $i/3), retry..."
    sleep 5
done
[ "$PULLED" = 1 ] || { echo "ERROR: pull model gagal 3x. Cek log di atas"; exit 1; }
echo "Model siap: $(ollama list | grep -F "$MODEL" || echo 'sudah ada di cache')"

# ---- 6. Install cloudflared ----
if ! command -v cloudflared &>/dev/null; then
    echo "Install cloudflared..."
    curl -fsSL -o /tmp/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
    chmod +x /tmp/cloudflared
    cp /tmp/cloudflared /usr/local/bin/cloudflared 2>/dev/null || true
fi
command -v cloudflared &>/dev/null || { echo "cloudflared tak tersedia"; exit 1; }

# ---- 6.5. Setup tools: SearXNG (search/scrape endpoint) ----
echo "Setup SearXNG (web_search + web_fetch tool)..."
bash /content/colab-ollama/setup-tools.sh || {
    echo "WARNING: SearXNG gagal, model tetap jalan tapi tanpa web search"
}

# ---- 6.6. Start web UI (Flask, chat + tools + proxy /v1 ke Ollama) ----
echo "Start web UI di port 5000..."
pkill -f "webui.py" 2>/dev/null || true
sleep 1
python3 -c "import flask" 2>/dev/null || pip install --quiet flask requests
OLLAMA_API="http://localhost:$PORT" SEARCH_API="http://localhost:8080" \
MODEL="$MODEL" PORT=5000 \
nohup python3 /content/colab-ollama/webui.py > /tmp/webui.log 2>&1 &
# Tunggu webui siap
WEBREADY=0
for i in $(seq 1 20); do
    if curl -s --max-time 2 "http://localhost:5000/health" > /dev/null 2>&1; then
        WEBREADY=1; break
    fi
    sleep 1
done
[ "$WEBREADY" = 1 ] && echo "Web UI siap di port 5000" || {
    echo "ERROR: webui tidak hidup. Cek /tmp/webui.log"; tail -20 /tmp/webui.log;
}

# ---- 7. Hentikan tunnel lama, buka ke WEB UI (satu URL: web + API) ----
pkill -f "cloudflared tunnel" 2>/dev/null || true
sleep 1

echo "Buka Cloudflare Tunnel (ke webui port 5000)..."
TUNNEL_LOG=/tmp/tunnel.log
nohup cloudflared tunnel --url "http://localhost:5000" > "$TUNNEL_LOG" 2>&1 &

# Tunggu sampai URL muncul (max 60 detik)
URL=""
for i in $(seq 1 30); do
    URL=$(grep -oiE 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -1 || true)
    [ -n "$URL" ] && break
    sleep 2
done

if [ -z "$URL" ]; then
    echo "ERROR: tunnel tak menghasilkan URL. Cek /tmp/tunnel.log"
    tail -30 "$TUNNEL_LOG"
    exit 1
fi

# ---- 8. Verify endpoint luar (web + API) ----
echo "Verifikasi $URL ..."
if curl -s "$URL/health" | grep -q '"ok"'; then
    echo "Web UI luar OK"
else
    echo "PERINGATAN: web UI belum respon. Tunnel mungkin butuh waktu."
fi
if curl -s "$URL/v1/models" | grep -q '"model"'; then
    echo "API /v1 luar OK"
else
    echo "PERINGATAN: API /v1 belum respon."
fi

echo ""
echo "==============================="
echo "  colab-ollama siap"
echo "  Model       : $MODEL"
echo "  Web UI      : $URL"
echo "  API OpenAI  : $URL/v1/chat/completions"
echo "  Web search  : $URL (model bisa browse)"
echo "  Local Ollama: http://localhost:$PORT"
echo "  Local Web   : http://localhost:5000"
echo ""
echo "  Buka browser: $URL"
echo "  Atau curl:"
echo "    curl $URL/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"cari berita AI terbaru\"}]}'"
echo "==============================="

# Simpan URL ke file agar bisa di-print ulang / dipakai Panrouter
{
    echo "OLLAMA_BASE_URL=$URL/v1"
    echo "WEB_UI_URL=$URL"
    echo "MODEL=$MODEL"
    echo "LOCAL_PORT=$PORT"
    echo "WEB_PORT=5000"
    date
} > /tmp/colab-ollama.env
echo "Config ditulis ke /tmp/colab-ollama.env"
if [ "$IN_COLAB" = true ]; then
    cp /tmp/colab-ollama.env "$DRIVE_DIR/last.env" 2>/dev/null || true
    echo "Juga disimpan: $DRIVE_DIR/last.env"
fi

echo "Selesai. Ollama + SearXNG + Web UI + tunnel jalan."
echo "Session idle 90 menit = mati; keepalive.sh sudah jalan."
