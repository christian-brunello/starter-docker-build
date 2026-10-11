# Explain sidecars (Ollama, RAG, Piper)

Compose project for house LLM / RAG / TTS. The `starter-explain` **daemon** is
built into the STARTER image and started via `boot-services.conf`; these
containers are the backends it calls.

## Layout

| Path | Role |
|------|------|
| `app.py` / `Dockerfile` | RAG HTTP service (`explain_service`) |
| `docker-compose.yml` | ollama, piper_tts, explain_service |
| `home.stex.xml.example` | public default (127.0.0.1); real config in sitedir |
| `deploy.sh` | sync corpus → data disk, compose up, smoke, reindex |
| `install-systemd.sh` | `explain-stack.service` |

Site corpus and `home.stex.xml` live in `../docker-build-sitedir/explain/`.
Run `../scripts/apply-site.sh` or point `STARTER_SITE_DIR` at that tree.

## Data disk

Set `EXPLAIN_DATA_ROOT` (or `STARTER_DATA_ROOT` so data is
`$STARTER_DATA_ROOT/starter/explain`):

```text
$EXPLAIN_DATA_ROOT/
  tts/voices/          # Piper .onnx
  llm/rag_docs/        # corpus (synced from sitedir)
  llm/chroma_db/       # Chroma index
```

Compose binds those paths; there is no hard-coded host mount in the public
compose file.

## Deploy

```bash
export EXPLAIN_DATA_ROOT=/mnt/data/starter/explain
# optional: STARTER_SITE_DIR=../docker-build-sitedir
./deploy.sh
sudo ./install-systemd.sh
```

`/etc/default/explain-stack` must define `EXPLAIN_DIR` and `EXPLAIN_DATA_ROOT`
(see `systemd/explain-stack.default.example` or sitedir `host/`).

## Smoke

- Ollama: `http://127.0.0.1:11434/api/tags`
- RAG: `http://127.0.0.1:5001/openapi.json`
- Piper: TCP `:5005`
