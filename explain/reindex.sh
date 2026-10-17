#!/bin/bash
# Reindex RAG ChromaDB only when rag_docs content changed since last success.
# Install: /usr/local/bin/rag-reindex
set -euo pipefail

DOCS_HOST="${RAG_DOCS_DIR:-}"
if [[ -z "${DOCS_HOST}" ]]; then
  echo "ERROR: set RAG_DOCS_DIR" >&2
  exit 1
fi
INDEX_URL="${RAG_INDEX_URL:-http://127.0.0.1:5001/index}"
STATE_DIR="${RAG_STATE_DIR:-/var/lib/rag-reindex}"
STATE_FILE="${STATE_DIR}/docs.state"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

docs_fingerprint() {
  if [[ ! -d "${DOCS_HOST}" ]]; then
    echo "MISSING"
    return
  fi
  # path + mtime + size — stable across runs if files unchanged
  find "${DOCS_HOST}" -type f \( -iname '*.pdf' -o -iname '*.txt' -o -iname '*.md' \) -printf '%P\t%T@\t%s\n' 2>/dev/null \
    | sort \
    | sha256sum \
    | awk '{print $1}'
}

if [[ ! -d "${DOCS_HOST}" ]]; then
  log "ERROR: docs dir not found: ${DOCS_HOST}"
  exit 1
fi

mkdir -p "${STATE_DIR}" 2>/dev/null || true
if [[ ! -d "${STATE_DIR}" ]] || [[ ! -w "${STATE_DIR}" ]]; then
  log "ERROR: state dir not writable: ${STATE_DIR}"
  exit 1
fi

count=$(find "${DOCS_HOST}" -type f \( -iname '*.pdf' -o -iname '*.txt' -o -iname '*.md' \) 2>/dev/null | wc -l | tr -d ' ')
fp=$(docs_fingerprint)

if [[ "${count}" -eq 0 ]]; then
  log "No pdf/txt/md in ${DOCS_HOST} — skip"
  exit 0
fi

if [[ -f "${STATE_FILE}" ]]; then
  prev=$(cat "${STATE_FILE}" || true)
  if [[ "${prev}" == "${fp}" ]]; then
    log "No document changes since last index (${count} files) — skip"
    exit 0
  fi
fi

log "Documents changed or first run (${count} files) — indexing…"
log "POST ${INDEX_URL}"
resp=$(curl -sS -m 600 -X POST "${INDEX_URL}") || {
  log "ERROR: curl failed"
  exit 1
}

echo "${resp}" | python3 -m json.tool 2>/dev/null || echo "${resp}"

status=$(echo "${resp}" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("status",""))' 2>/dev/null || true)
if [[ "${status}" == "success" ]]; then
  echo "${fp}" > "${STATE_FILE}"
  log "Index OK — state saved"
  exit 0
fi

log "ERROR: index status=${status:-unknown}"
exit 1
