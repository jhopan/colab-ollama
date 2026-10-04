# colab-ollama

Jalankan **Ollama** di **Google Colab** (GPU T4 gratis), expose via **Cloudflare Tunnel**, akses dari luar sebagai API **OpenAI-compatible**.

## Fitur
- Ollama install otomatis di Colab (GPU/CPU)
- Model cache ke Google Drive (tidak pull ulang tiap recycle)
- Cloudflare Tunnel → URL publik `xxx.trycloudflare.com`
- Endpoint `/v1` = OpenAI-compatible (tool calling, chat)
- Keepalive script cegah idle timeout 90m
- Print URL + config ke `/tmp/colab-ollama.env`

## Cara pakai

### 1. Buka notebook di Colab
1. Buka notebook.ipynb → File > Open notebook >
2. Pilih `colab-ollama/notebook.ipynb` dari repo ini
   (atau buka `https://colab.research.google.com/github/jhopanstore/colab-ollama/blob/main/notebook.ipynb`)
3. Runtime > Change runtime type > GPU (T4)

### 2. Jalankan semua cell
Runtime > Run all
- Cell 1: clone repo
- Cell 2: mount Drive
- Cell 3: `install.sh` → Ollama + model + tunnel
- Cell 4: start keepalive
- Cell 5: print URL + verify

Output Cell 3 akhir:
```
===============================
  colab-ollama siap
  Model      : qwen2.5:14b
  Local      : http://localhost:11434
  Akses luar : https://xxxx.trycloudflare.com
  API (OpenAI-compatible):
    https://xxxx.trycloudflare.com/v1/chat/completions
===============================
```

### 3. Akses dari luar / Panrouter
```bash
URL="https://xxxx.trycloudflare.com"
curl "$URL/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5:14b","messages":[{"role":"user","content":"halo"}]}'
```

Di Panrouter: provider `ollama`, base URL = `https://xxxx.trycloudflare.com`.

## Opsi

### Ganti model
```bash
MODEL=qwen2.5:7b bash /content/colab-ollama/install.sh
# atau MODEL=llama3.1:8b, mistral:7b, qwen2.5:3b
```

### Keepalive
Sudah di-start otomatis notebook. Manual:
```bash
nohup bash /content/colab-ollama/keepalive.sh > /tmp/keepalive.log 2>&1 &
```

## Struktur
```
install.sh        # install ollama+cloudflared, pull model, serve, tunnel, print URL
keepalive.sh      # ping /v1 tiap 30m, cegah idle timeout
notebook.ipynb    # 5 cell: clone → drive → install → keepalive → print URL
```

## Kendala
- **Colab idle timeout 90m** → keepalive jaga, tapi hard limit 12-24 jam tetap recycle
- **Recycle** = VM baru, Ollama fresh. Notebook auto-run → install.sh rerun. Model di Drive persist (cepat)
- **GPU T4 16GB**: `qwen2.5:14b` ok; 32b berat
- **CPU only**: pakai model kecil (`:3b`/`:7b`)
- **Tunnel trycloudflare** = ephemeral URL, berubah tiap recycle. Panrouter perlu update URL (bisa baca `/content/drive/MyDrive/colab-ollama/last.env`)

## Kenapa qwen2.5?
Model paling "penurut" di antara yang populer: minim sakti, patuh, tak banyak nolak. Tetap ada safety dasar bawaan (bukan nol), tapi jauh lebih sedikit dibanding cloud AI.

## Local development
Repo ini bisa jalan di Linux lokal juga (non-Colab): `bash install.sh` di server Linux. Colab-specific: Drive mount + `/content` path.
