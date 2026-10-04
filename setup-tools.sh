#!/bin/bash
# colab-ollama setup-tools.sh
# Pasang SearXNG (search engine lokal, tanpa API key) di Colab.
# Jalankan SETELAH ollama serve hidup, sebelum test web.
#
# SearXNG jalan di port 8080. Qwen panggil tool web_search -> SearXNG cari.

set -uo pipefail

SEARXNG_PORT="${SEARXNG_PORT:-8080}"
IN_COLAB=false
[ -d /content ] && IN_COLAB=true

echo "=== setup SearXNG ==="

# ---- Cek apakah sudah jalan ----
if curl -s --max-time 3 "http://localhost:$SEARXNG_PORT/search?q=test&format=json" > /dev/null 2>&1; then
    echo "SearXNG sudah jalan di port $SEARXNG_PORT"
    exit 0
fi

# ---- 1. Install SearXNG (pip, bukan Docker — Colab tak bisa pakai Docker) ----
if ! python3 -c "import searx" 2>/dev/null; then
    echo "Install SearXNG via pip..."
    pip install searxng 2>/dev/null || pip install searx 2>/dev/null || \
    pip install --upgrade pip && pip install searxng || pip install searx
fi

# SearXNG punya 2 cara jalan:
#   A. searxng run (WSGI app) — pakai `pip install searxng` lalu `python -m searx.webapp`
#   B. Manual Flask mini yang proxy ke DuckDuckGo (fallback, selalu jalan)
#
# Colab tak support `python -m searx.webapp` dengan mudah (butuh banyak dep).
# Solusi paling andal: buat SearXNG-compatible endpoint ringan pakai requests.
# Ollama tool `web_search` tak peduli backend — asalkan ada endpoint JSON
# di http://localhost:PORT/search?q=...&format=json.

# ---- 2. Buat endpoint search ringkas (Flask + DuckDuckGo/Bing HTML scrape) ----
echo "Buat endpoint search lokal..."

cat > /tmp/local-search.py << 'PYEOF'
#!/usr/bin/env python3
"""
Local search endpoint (SearXNG-compatible, tanpa API key).
Proxy ke DuckDuckGo HTML + Bing. Response JSON:
  {"results": [{"title","url","content"}, ...]}
Jalan di Colab / Linux tanpa dep berat (hanya requests).
"""
import requests, re, html, sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080

try:
    from flask import Flask, request, jsonify
    HAS_FLASK = True
except ImportError:
    HAS_FLASK = False
    from http.server import HTTPServer, BaseHTTPRequestHandler
    import json as _json
    from urllib.parse import parse_qs, urlparse

HEADERS = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"}

def ddg_search(query, max_r=8):
    """DuckDuckGo HTML endpoint (tak butuh API key)."""
    try:
        r = requests.post(
            "https://html.duckduckgo.com/html/",
            data={"q": query}, headers=HEADERS, timeout=15
        )
        r.raise_for_status()
        results = []
        # Parse: <a class="result__a" href="...">title</a> ... <a class="result__snippet">text</a>
        for m in re.finditer(
            r'<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>', r.text, re.S
        ):
            href = m.group(1)
            title = html.unescape(re.sub(r"<[^>]+>", "", m.group(2))).strip()
            # DDG href is redirect /l/?uddg=<encoded>; extract real URL
            if "uddg=" in href:
                from urllib.parse import unquote
                href = unquote(href.split("uddg=")[1].split("&")[0])
            results.append({"title": title, "url": href, "content": ""})
            if len(results) >= max_r:
                break
        # Attach snippets
        snippets = re.findall(r'<a[^>]*class="result__snippet"[^>]*>(.*?)</a>', r.text, re.S)
        for i, s in enumerate(snippets):
            if i < len(results):
                results[i]["content"] = html.unescape(re.sub(r"<[^>]+>", "", s)).strip()
        return results
    except Exception as e:
        print(f"ddg failed: {e}", file=sys.stderr)
        return []

def bing_search(query, max_r=8):
    """Bing HTML endpoint."""
    try:
        r = requests.get(
            f"https://www.bing.com/search?q={requests.utils.quote(query)}",
            headers=HEADERS, timeout=15
        )
        r.raise_for_status()
        results = []
        for m in re.finditer(r'<h2><a[^>]*href="([^"]+)"[^>]*>(.*?)</a>', r.text, re.S):
            url = m.group(1)
            title = html.unescape(re.sub(r"<[^>]+>", "", m.group(2))).strip()
            results.append({"title": title, "url": url, "content": ""})
            if len(results) >= max_r:
                break
        return results
    except Exception as e:
        print(f"bing failed: {e}", file=sys.stderr)
        return []

def search(query, max_r=8):
    """Coba DDG dulu, fallback Bing."""
    results = ddg_search(query, max_r)
    if not results:
        results = bing_search(query, max_r)
    return results

def fetch_url(url, max_chars=8000):
    """Scrape text dari URL (untuk tool web_fetch)."""
    try:
        r = requests.get(url, headers=HEADERS, timeout=15)
        r.raise_for_status()
        text = r.text
        # Strip tags
        text = re.sub(r"<script[^>]*>.*?</script>", "", text, flags=re.S)
        text = re.sub(r"<style[^>]*>.*?</style>", "", text, flags=re.S)
        text = re.sub(r"<[^>]+>", " ", text)
        text = html.unescape(text)
        text = re.sub(r"\s+", " ", text).strip()
        return text[:max_chars]
    except Exception as e:
        return f"Fetch failed: {e}"

if HAS_FLASK:
    app = Flask(__name__)

    @app.route("/search")
    def search_route():
        q = request.args.get("q", "")
        fmt = request.args.get("format", "json")
        results = search(q)
        if fmt == "json":
            return jsonify({"query": q, "results": results})
        # HTML fallback
        out = '<html><body><h1>Results for ' + html.escape(q) + '</h1><ul>'
        for r in results:
            out += f'<li><a href="{html.escape(r["url"])}">{html.escape(r["title"])}</a></li>'
        out += "</ul></body></html>"
        return out

    @app.route("/fetch")
    def fetch_route():
        url = request.args.get("url", "")
        return jsonify({"url": url, "text": fetch_url(url)})

    @app.route("/health")
    def health():
        return jsonify({"status": "ok"})

    app.run(host="0.0.0.0", port=PORT, threaded=True)
else:
    class H(BaseHTTPRequestHandler):
        def _send(self, obj, code=200):
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(_json.dumps(obj).encode())
        def do_GET(self):
            u = urlparse(self.path)
            qs = parse_qs(u.query)
            if u.path == "/search":
                q = qs.get("q", [""])[0]
                fmt = qs.get("format", ["json"])[0]
                results = search(q)
                if fmt == "json":
                    self._send({"query": q, "results": results})
                else:
                    self.send_response(200)
                    self.send_header("Content-Type", "text/html")
                    self.end_headers()
                    out = f"<h1>{q}</h1><ul>" + "".join(
                        f'<li><a href="{r["url"]}">{r["title"]}</a></li>' for r in results
                    ) + "</ul>"
                    self.wfile.write(out.encode())
            elif u.path == "/fetch":
                url = qs.get("url", [""])[0]
                self._send({"url": url, "text": fetch_url(url)})
            elif u.path == "/health":
                self._send({"status": "ok"})
            else:
                self._send({"error": "not found"}, 404)
        def log_message(self, *a):
            pass

    print(f"Search endpoint (no Flask) at port {PORT}")
    HTTPServer(("0.0.0.0", PORT), H).serve_forever()
PYEOF

# ---- 3. Pasang Flask (biar lebih stabil) ----
python3 -c "import flask" 2>/dev/null || pip install flask 2>/dev/null || pip install --quiet flask

# ---- 4. Hentikan instance lama, start baru ----
pkill -f "local-search.py" 2>/dev/null || true
sleep 1
nohup python3 /tmp/local-search.py "$SEARXNG_PORT" > /tmp/search.log 2>&1 &

# Tunggu siap
READY=0
for i in $(seq 1 20); do
    if curl -s --max-time 2 "http://localhost:$SEARXNG_PORT/health" > /dev/null 2>&1; then
        READY=1; break
    fi
    sleep 1
done

if [ "$READY" = 0 ]; then
    echo "ERROR: search endpoint tidak hidup. Cek /tmp/search.log"
    tail -20 /tmp/search.log
    exit 1
fi

# Test
echo "Test SearXNG endpoint..."
RESULT=$(curl -s --max-time 20 "http://localhost:$SEARXNG_PORT/search?q=test&format=json")
echo "$RESULT" | head -c 300
echo ""

echo "==============================="
echo " SearXNG siap di port $SEARXNG_PORT"
echo " /search?q=...&format=json  (web_search tool)"
echo " /fetch?url=...             (web_fetch tool)"
echo " /health"
echo "==============================="
