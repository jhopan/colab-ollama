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
# Clone kalau belum ada
[ -d colab-ollama ] || git clone https://github.com/jhopan/colab-ollama /content/colab-ollama

# Mount Drive (untuk cache model) — di luar Colab ini gagal, skip
if [ -d /content/drive ]; then
    echo "Drive sudah mounted"
else
    echo "Note: mount Drive dulu (cell 2 notebook) untuk cache model; lanjut tanpa cache"
fi

bash /content/colab-ollama/install.sh

# Start keepalive
nohup bash /content/colab-ollama/keepalive.sh > /tmp/keepalive.log 2>&1 &
echo "Keepalive di-start. Cek: tail /tmp/keepalive.log"

echo ""
echo "=================================================="
echo " colab-ollama SELESAI"
echo " Baca /tmp/colab-ollama.env untuk URL + config:"
cat /tmp/colab-ollama.env
echo "=================================================="
