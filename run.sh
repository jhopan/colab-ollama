#!/bin/bash
# colab-ollama run.sh
# SATU PERINTAH di Colab: clone repo + install Ollama + cloudflared + pull model
# + serve + buka tunnel + start keepalive. Print URL akses.
#
# Cara pakai di Colab (satu cell):
#   !curl -fsSL https://raw.githubusercontent.com/jhopan/colab-ollama/main/run.sh | bash
#
# Atau kalau sudah clone:
#   !bash /content/colab-ollama/run.sh

set -euo pipefail

cd /content

# Install zstd dulu (Ollama .zst / tool butuh)
if ! command -v zstd &>/dev/null; then
    echo "Install zstd..."
    (apt-get update -qq && apt-get install -y zstd) || \
    (sudo apt-get update -qq && sudo apt-get install -y zstd) || \
    echo "WARNING: zstd gagal install"
fi

# Clone repo; kalau sudah ada, PULL (bukan skip) agar dapat versi terbaru
if [ -d colab-ollama ]; then
    echo "Repo sudah ada, git pull..."
    git -C colab-ollama pull --ff-only || git -C colab-ollama reset --hard origin/main
else
    git clone https://github.com/jhopan/colab-ollama /content/colab-ollama
fi

# Mount Drive (untuk cache model) — di luar Colab ini gagal, skip
if [ -d /content/drive ]; then
    echo "Drive sudah mounted (cache model antar recycle)"
else
    echo "Note: mount Drive dulu untuk cache model antar recycle; lanjut tanpa cache"
fi

bash /content/colab-ollama/install.sh

# Start keepalive (cegah idle timeout, sekali jalan, background)
nohup bash /content/colab-ollama/keepalive.sh > /tmp/keepalive.log 2>&1 &
echo "Keepalive di-start (background)."

# Start Web UI server + tunnel (URL SATU: web UI + proxy /v1 Ollama + /search SearXNG)
echo ""
echo ">>> Start Web UI + tunnel..."
bash /content/colab-ollama/webui.sh

echo ""
echo "=================================================="
echo " SELESAI — BUKA URL WEB UI DI ATAS, LANGSUNG CHAT."
echo " (zero-config: halaman auto-detect, tak perlu isi Base URL)"
echo "=================================================="
