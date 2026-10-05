#!/usr/bin/env python3
"""
colab-ollama search endpoint (SearXNG-compatible, tanpa API key).
Jalan di port argumen (default 8081). Endpooints:
  /search?q=...&format=json   (DDG + Startpage + Bing)
  /fetch?url=...
  /health
"""
import requests, re, html, sys, os

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8081
try:
    from flask import Flask, request, jsonify
    HAS_FLASK = True
except ImportError:
    HAS_FLASK = False

HEADERS = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"}

def ddg_search(query, max_r=8):
    try:
        r = requests.post("https://html.duckduckgo.com/html/",
                           data={"q": query}, headers=HEADERS, timeout=20)
        r.raise_for_status()
        results = []
        for m in re.finditer(r'<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>', r.text, re.S):
            href = m.group(1)
            title = html.unescape(re.sub(r"<[^>]+>", "", m.group(2))).strip()
            if "uddg=" in href:
                from urllib.parse import unquote
                href = unquote(href.split("uddg=")[1].split("&")[0])
            results.append({"title": title, "url": href, "content": ""})
            if len(results) >= max_r:
                break
        snippets = re.findall(r'<a[^>]*class="result__snippet"[^>]*>(.*?)</a>', r.text, re.S)
        for i, s in enumerate(snippets):
            if i < len(results):
                results[i]["content"] = html.unescape(re.sub(r"<[^>]+>", "", s)).strip()
        return results
    except Exception as e:
        print(f"ddg failed: {e}", file=sys.stderr); return []

def startpage_search(query, max_r=8):
    try:
        r = requests.post("https://www.startpage.com/sp/search",
                           data={"query": query, "cat": "web"},
                           headers={**HEADERS, "Referer": "https://www.startpage.com/"}, timeout=20)
        r.raise_for_status()
        results = []
        for m in re.finditer(r'<a[^>]*class="w-gl__title[^"]*"[^>]*href="([^"]+)"[^>]*>(.*?)</a>', r.text, re.S):
            url = m.group(1); title = html.unescape(re.sub(r"<[^>]+>", "", m.group(2))).strip()
            results.append({"title": title, "url": url, "content": ""})
            if len(results) >= max_r: break
        return results
    except Exception as e:
        print(f"startpage failed: {e}", file=sys.stderr); return []

def bing_search(query, max_r=8):
    try:
        from urllib.parse import quote
        r = requests.get(f"https://www.bing.com/search?q={quote(query)}", headers=HEADERS, timeout=20)
        r.raise_for_status()
        results = []
        for m in re.finditer(r'<h2><a[^>]*href="([^"]+)"[^>]*>(.*?)</a>', r.text, re.S):
            url = m.group(1); title = html.unescape(re.sub(r"<[^>]+>", "", m.group(2))).strip()
            results.append({"title": title, "url": url, "content": ""})
            if len(results) >= max_r: break
        return results
    except Exception as e:
        print(f"bing failed: {e}", file=sys.stderr); return []

def search(query, max_r=8):
    results = ddg_search(query, max_r)
    if not results: results = startpage_search(query, max_r)
    if not results: results = bing_search(query, max_r)
    return results

def fetch_url(url, max_chars=8000):
    try:
        r = requests.get(url, headers=HEADERS, timeout=15); r.raise_for_status()
        text = r.text
        text = re.sub(r"<script[^>]*>.*?</script>", "", text, flags=re.S)
        text = re.sub(r"<style[^>]*>.*?</style>", "", text, flags=re.S)
        text = re.sub(r"<[^>]+>", " ", text)
        text = html.unescape(text)
        return re.sub(r"\s+", " ", text).strip()[:max_chars]
    except Exception as e:
        return f"Fetch failed: {e}"

if HAS_FLASK:
    app = Flask(__name__)
    @app.route("/search")
    def sr():
        q = request.args.get("q",""); fmt = request.args.get("format","json")
        results = search(q)
        if fmt == "json":
            return jsonify({"query": q, "results": results})
        return "<ul>" + "".join(f'<li><a href="{r["url"]}">{r["title"]}</a></li>' for r in results) + "</ul>"
    @app.route("/fetch")
    def fr():
        return jsonify({"url": request.args.get("url",""), "text": fetch_url(request.args.get("url",""))})
    @app.route("/health")
    def hl():
        return jsonify({"status":"ok"})
    app.run(host="0.0.0.0", port=PORT, threaded=True)
else:
    from http.server import HTTPServer, BaseHTTPRequestHandler
    import json as _json
    from urllib.parse import parse_qs, urlparse
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def do_GET(self):
            u = urlparse(self.path); qs = parse_qs(u.query)
            if u.path == "/search":
                q = qs.get("q",[""])[0]; results = search(q)
                self.send_response(200); self.send_header("Content-Type","application/json"); self.end_headers()
                self.wfile.write(_json.dumps({"query":q,"results":results}).encode())
            elif u.path == "/fetch":
                url = qs.get("url",[""])[0]
                self.send_response(200); self.send_header("Content-Type","application/json"); self.end_headers()
                self.wfile.write(_json.dumps({"url":url,"text":fetch_url(url)}).encode())
            elif u.path == "/health":
                self.send_response(200); self.send_header("Content-Type","application/json"); self.end_headers()
                self.wfile.write(b'{"status":"ok"}')
    HTTPServer(("0.0.0.0", PORT), H).serve_forever()
