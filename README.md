# colab-ollama

Jalankan **Ollama** di **Google Colab** (GPU T4 gratis), expose via **Cloudflare Tunnel**, akses dari luar sebagai API **OpenAI-compatible**.

## Fitur
- Ollama install otomatis di Colab (GPU/CPU)
- Model cache ke Google Drive (tidak pull ulang tiap recycle)
- Cloudflare Tunnel → URL publik `xxx.trycloudflare.com`
- Endpoint `/v1` = OpenAI-compatible (tool calling, chat)
- Keepalive script cegah idle timeout 90m
- Print URL + config ke `/tmp/colab-ollama.env`

## Cara pakai (satu perintah)

1. Buka [notebook](https://colab.research.google.com/github/jhopan/colab-ollama/blob/main/notebook.ipynb) di Colab
2. Runtime > Change runtime type > **GPU**
3. Di cell, jalankan:
   ```
   !curl -fsSL https://raw.githubusercontent.com/jhopan/colab-ollama/main/run.sh | bash
   ```
4. Output print URL `https://xxxx.trycloudflare.com`. Selesai.

### Akses dari luar / Panrouter
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
MODEL=qwen2.5:7b curl -fsSL https://raw.githubusercontent.com/jhopan/colab-ollama/main/run.sh | bash
```

### CPU only
Non-GPU pakai model kecil (`qwen2.5:3b` / `:7b`).

## Struktur
```
run.sh          # SATU PERINTAH: clone + install + serve + tunnel + keepalive + print URL
install.sh      # install ollama+cloudflared, pull model, serve, tunnel
keepalive.sh    # ping /v1 tiap 30m, cegah idle timeout 90m
notebook.ipynb  # cell curl run.sh
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
