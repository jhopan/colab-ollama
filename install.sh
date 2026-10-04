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

# ---- 1. Install Ollama ----
if command -v ollama &>/dev/null; then
    echo "Ollama sudah ada: $(ollama --version)"
else
    echo "Install Ollama..."
    # Colab image sering tak punya zstd; installer Ollama butuh untuk extract
    if ! command -v zstd &>/dev/null; then
        echo "Install zstd dulu..."
        apt-get update -qq && apt-get install -y -qq zstd 2>/dev/null || sudo apt-get install -y zstd
    fi
    # Colab = Linux, pakai script resmi
    if [ "$IN_COLAB" = true ]; then
        curl -fsSL https://ollama.com/install.sh | sh
    else
        # local: asumsikan Linux; Windows pakai winget (di luar scope script ini)
        curl -fsSL https://ollama.com/install.sh | sh
    fi
    export PATH="$HOME/.local/bin:$PATH:/usr/bin:/usr/local/bin:$PATH"
fi

# ---- 2. Cache model ke Google Drive (Colab) ----
if [ "$IN_COLAB" = true ]; then
    mkdir -p "$DRIVE_DIR/ollama-models"
    # Arahkan Ollama ke storage Drive sehingga model tidak pull ulang tiap recycle
    # (Colab filesystem volatile; Drive persist)
    export OLLAMA_MODELS="$DRIVE_DIR/ollama-models"
    echo "Model cache: $OLLAMA_MODELS"
fi

# ---- 3. Pull model ----
echo "Pull model $MODEL..."
ollama pull "$MODEL"
echo "Model siap: $(ollama list | grep -F "$MODEL" || echo 'sudah ada di cache')"

# ---- 4. Hentikan Ollama lama kalau ada (dari session sebelumnya) ----
pkill -f "ollama serve" 2>/dev/null || true
sleep 1

# ---- 5. Serve Ollama di background ----
echo "Serve Ollama di port $PORT..."
nohup ollama serve --host 0.0.0.0 --port "$PORT" > /tmp/ollama.log 2>&1 &
sleep 3

# Cek hidup
if curl -s "http://localhost:$PORT/v1/models" > /dev/null 2>&1; then
    echo "Ollama hidup. Model: $(curl -s http://localhost:$PORT/v1/models | grep -oP '"id":"\K[^"]+' || echo none)"
else
    echo "ERROR: Ollama tidak hidup. Cek /tmp/ollama.log"
    tail -20 /tmp/ollama.log
    exit 1
fi

# ---- 6. Install cloudflared ----
if ! command -v cloudflared &>/dev/null; then
    echo "Install cloudflared..."
    curl -fsSL -o /tmp/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
    chmod +x /tmp/cloudflared
    cp /tmp/cloudflared /usr/local/bin/cloudflared 2>/dev/null || true
fi
command -v cloudflared &>/dev/null || { echo "cloudflared tak tersedia"; exit 1; }

# ---- 7. Hentikan tunnel lama, bikin yang baru ----
pkill -f "cloudflared tunnel" 2>/dev/null || true
sleep 1

echo "Buka Cloudflare Tunnel..."
TUNNEL_LOG=/tmp/tunnel.log
nohup cloudflared tunnel --no-authtls --url "http://localhost:$PORT" > "$TUNNEL_LOG" 2>&1 &

# Tunggu sampai URL muncul
URL=""
for i in $(seq 1 60); do
    URL=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -1 || true)
    [ -n "$URL" ] && break
    sleep 2
done

if [ -z "$URL" ]; then
    echo "ERROR: tunnel tak menghasilkan URL. Cek $TUNNEL_LOG"
    tail -20 "$TUNNEL_LOG"
    exit 1
fi

# ---- 8. Verify endpoint luar ----
echo "Verifikasi $URL/v1/models ..."
if curl -s "$URL/v1/models" | grep -q '"model"'; then
    echo "Endpoint luar OK"
else
    echo "PERINGATAN: endpoint luar belum respon. Tunnel mungkin butuh waktu."
fi

echo ""
echo "==============================="
echo "  colab-ollama siap"
echo "  Model      : $MODEL"
echo "  Local      : http://localhost:$PORT"
echo "  Akses luar : $URL"
echo "  API (OpenAI-compatible):"
echo "    $URL/v1/chat/completions"
echo "  Contoh curl:"
echo "    curl $URL/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"halo\"}]}'"
echo "==============================="

# Simpan URL ke file agar bisa di-print ulang / dipakai Panrouter
{
    echo "OLLAMA_BASE_URL=$URL/v1"
    echo "MODEL=$MODEL"
    echo "LOCAL_PORT=$PORT"
    date
} > /tmp/colab-ollama.env
echo "Config ditulis ke /tmp/colab-ollama.env"
if [ "$IN_COLAB" = true ]; then
    cp /tmp/colab-ollama.env "$DRIVE_DIR/last.env" 2>/dev/null || true
    echo "Juga disimpan: $DRIVE_DIR/last.env"
fi

echo "Selesai. Ollama + tunnel jalan. Session idle 90 menit = mati; pakai keepalive.sh"
