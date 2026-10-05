#!/bin/bash
# colab-ollama webui.sh  —  SEL 3: Web UI (URL sendiri)
# Serve webui-standalone.html + proxy /v1 Ollama + /search SearXNG di port 8888,
# expose via Cloudflare Tunnel (URL terpisah dari Ollama tunnel).
#
# Self-contained: bisa di-curl langsung tanpa run.sh (auto-clone repo,
# install cloudflared, start SearXNG kalau belum hidup).
# Web UI tetap terserve walau Ollama belum install — chat hanya sukses
# setelah Ollama hidup di localhost:11434.
#
# Cara pakai di Colab (sel 3):
#   !curl -fsSL https://raw.githubusercontent.com/jhopan/colab-ollama/main/webui.sh | bash

set -uo pipefail

PORT=8888
OLLAMA_API="${OLLAMA_API:-http://localhost:11434}"
SEARCH_PORT=8081
SEARCH_API="http://localhost:$SEARCH_PORT"
MODEL="${MODEL:-jhopan-unfiltered}"

echo "=== webui.sh: serve Web UI + proxy (port $PORT) ==="

# Clone repo kalau belum ada (self-contained)
cd /content
if [ ! -d colab-ollama ]; then
    echo "Repo belum ada, clone..."
    git clone https://github.com/jhopan/colab-ollama /content/colab-ollama 2>/dev/null || \
        echo "WARNING: clone gagal (offline?). Web UI tetap jalan, tool tak bisa."
fi

# Install cloudflared kalau belum ada (self-contained)
if ! command -v cloudflared &>/dev/null; then
    echo "Install cloudflared..."
    curl -fsSL -o /tmp/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 2>/dev/null
    chmod +x /tmp/cloudflared 2>/dev/null
    cp /tmp/cloudflared /usr/local/bin/cloudflared 2>/dev/null || true
fi
command -v cloudflared &>/dev/null || { echo "ERROR: cloudflared tak tersedia"; exit 1; }

# Hentikan instance webui lama
pkill -f "colab-webui.py" 2>/dev/null || true
sleep 1

# SearXNG: start di 8081 kalau belum hidup (self-contained, tak bergantung install.sh)
if ! curl -s --max-time 2 "http://localhost:$SEARCH_PORT/health" > /dev/null 2>&1; then
    echo "SearXNG tak hidup di $SEARCH_PORT, start..."
    pkill -f "search-endpoint.py" 2>/dev/null || true
    sleep 1
    nohup python3 /content/colab-ollama/search-endpoint.py "$SEARCH_PORT" > /tmp/search.log 2>&1 &
    sleep 2
fi

# Buat mini-server: serve HTML + proxy /v1 ke Ollama + /search,/fetch ke local search
cat > /tmp/colab-webui.py << 'PYEOF'
import os, re, json, sys, threading
import requests
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

PORT = int(os.environ.get("PORT", "8888"))
OLLAMA = os.environ.get("OLLAMA_API", "http://localhost:11434")
SEARCH = os.environ.get("SEARCH_API", "http://localhost:8081")  # SearXNG di 8081
MODEL = os.environ.get("MODEL", "jhopan-unfiltered")
# HTML dari repo
HTML_PATH = "/content/colab-ollama/webui-standalone.html"

def load_html():
    try:
        return open(HTML_PATH, encoding="utf-8").read()
    except Exception as e:
        return f"<h1>webui-standalone.html tak ketemu: {e}</h1>"

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def _send(self, obj, code=200, ctype="application/json"):
        body = obj.encode() if isinstance(obj, str) else obj
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        self.end_headers()

    def do_GET(self):
        u = urlparse(self.path)
        p = u.path
        if p == "/" or p == "/index.html":
            self._send(load_html(), ctype="text/html")
        elif p.startswith("/v1/"):
            sub = p[len("/v1"):]
            r = requests.get(f"{OLLAMA}/v1{sub}", params=parse_qs(u.query),
                             headers={"Authorization":"Bearer ollama"}, timeout=600)
            self._send(r.text, code=r.status_code, ctype=r.headers.get("Content-Type","application/json"))
        elif p == "/search":
            q = parse_qs(u.query)
            r = requests.get(f"{SEARCH}/search",
                             params={k:v[0] for k,v in q.items()}, timeout=40)
            self._send(r.text, code=r.status_code, ctype="application/json")
        elif p == "/fetch":
            r = requests.get(f"{SEARCH}/fetch",
                             params={k:v[0] for k,v in parse_qs(u.query).items()}, timeout=40)
            self._send(r.text, code=r.status_code, ctype="application/json")
        elif p == "/health":
            self._send(json.dumps({"ok":True,"model":MODEL,"ollama":OLLAMA}))
        else:
            self._send(json.dumps({"error":"not found"}), code=404)

    def do_POST(self):
        u = urlparse(self.path)
        p = u.path
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""
        if p.startswith("/v1/"):
            sub = p[len("/v1"):]
            r = requests.post(f"{OLLAMA}/v1{sub}", data=body,
                              headers={k:v for k,v in self.headers.items()
                                       if k.lower() in ("content-type","authorization")},
                              timeout=600)
            self._send(r.content, code=r.status_code, ctype=r.headers.get("Content-Type","application/json"))
        elif p == "/chat":
            # proxy sederhana: forward ke Ollama /v1/chat/completions
            try:
                d = json.loads(body or b"{}")
            except Exception:
                d = {}
            d["model"] = d.get("model", MODEL)
            r = requests.post(f"{OLLAMA}/v1/chat/completions",
                              headers={"Content-Type":"application/json"},
                              data=json.dumps(d), timeout=600)
            self._send(r.text, code=r.status_code, ctype="application/json")
        else:
            self._send(json.dumps({"error":"not found"}), code=404)

if __name__ == "__main__":
    print(f"colab-webui at 0.0.0.0:{PORT} (model {MODEL})")
    HTTPServer(("0.0.0.0", PORT), H).serve_forever()
PYEOF

# Jalankan webui di port 8888
OLLAMA_API="$OLLAMA_API" SEARCH_API="$SEARCH_API" MODEL="$MODEL" PORT=$PORT \
nohup python3 /tmp/colab-webui.py > /tmp/webui.log 2>&1 &

# Tunggu webui siap
READY=0
for i in $(seq 1 20); do
    if curl -s --max-time 2 "http://localhost:$PORT/health" | grep -q '"ok"'; then
        READY=1; break
    fi
    sleep 1
done
[ "$READY" = 1 ] && echo "Web UI siap di port $PORT" || {
    echo "ERROR: webui tak hidup. Cek /tmp/webui.log"; tail -20 /tmp/webui.log; exit 1;
}

# Cek status Ollama
if curl -s --max-time 5 "$OLLAMA_API/v1/models" > /dev/null 2>&1; then
    echo "Ollama HIRUP di $OLLAMA_API (chat akan jalan)"
else
    echo "PERINGATAN: Ollama TIDAK hidup di $OLLAMA_API — jalankan SEL 1 (run.sh) dulu."
    echo "Web UI tetap terserve; chat akan gagal sampai Ollama hidup."
fi

# Buka tunnel (URL sendiri, terpisah dari tunnel Ollama — pkill spesifik)
pkill -f "cloudflared tunnel --url http://localhost:$PORT" 2>/dev/null || true
sleep 1
TUNNEL_LOG=/tmp/webui-tunnel.log
rm -f "$TUNNEL_LOG"
nohup cloudflared tunnel --url "http://localhost:$PORT" > "$TUNNEL_LOG" 2>&1 &
URL=""
for i in $(seq 1 30); do
    URL=$(grep -oiE 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -1 || true)
    [ -n "$URL" ] && break
    sleep 2
done
[ -n "$URL" ] || { echo "ERROR: tunnel webui tak hidup. Cek $TUNNEL_LOG"; tail -20 "$TUNNEL_LOG"; exit 1; }

# Simpan
{
    echo "WEBUI_URL=$URL"
    echo "OLLAMA_BASE_URL=$URL/v1"
    echo "MODEL=$MODEL"
    date
} > /tmp/colab-webui.env

echo ""
echo "==============================="
echo " Web UI siap (URL sendiri)"
echo "  Buka di browser mana pun : $URL"
echo "  Ollama /v1 (via webui)   : $URL/v1"
echo "  Ollama local             : $OLLAMA_API"
echo ""
echo "  Di Web UI:  Base URL = $URL/v1"
echo "              API Key  = ollama"
echo "              Model    = $MODEL"
echo ""
echo "  Kalau Ollama belum install: jalankan SEL 1 (run.sh) dulu."
echo "  Kalau runtime mau tetap hidup: SEL 2 (keepalive.sh)."
echo "==============================="
