#!/usr/bin/env bash
# Deploy LLM / RAG / TTS stack from docker-build/explain.
#
#   ./explain/deploy.sh
#
# Prefers rag_docs from STARTER_SITE_DIR when present; otherwise explain/rag_docs
# (populated by scripts/apply-site.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPLAIN_DIR="${ROOT}/explain"
COMPOSE_FILE="${EXPLAIN_DIR}/docker-compose.yml"
DEFAULT_SITE="$(cd "${ROOT}/.." && pwd)/docker-build-sitedir"
SITE_DIR="${STARTER_SITE_DIR:-${DEFAULT_SITE}}"

if [[ -f /etc/default/explain-stack ]]; then
  # shellcheck disable=SC1091
  set -a; source /etc/default/explain-stack; set +a
fi

DATA_ROOT_BASE="${STARTER_DATA_ROOT:-${EXPLAIN_TOSHIBA_ROOT:-}}"
EXPLAIN_DATA="${EXPLAIN_DATA_ROOT:-}"
if [[ -z "${EXPLAIN_DATA}" && -n "${DATA_ROOT_BASE}" ]]; then
  EXPLAIN_DATA="${DATA_ROOT_BASE}/starter/explain"
fi

RAG_DOCS_HOST="${EXPLAIN_DATA:+${EXPLAIN_DATA}/llm/rag_docs}"
CHROMA_HOST="${EXPLAIN_DATA:+${EXPLAIN_DATA}/llm/chroma_db}"
VOICES_HOST="${EXPLAIN_DATA:+${EXPLAIN_DATA}/tts/voices}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "${COMPOSE_FILE}" ]] || die "missing ${COMPOSE_FILE}"
command -v docker >/dev/null 2>&1 || die "docker not found"
command -v curl >/dev/null 2>&1 || die "curl not found"
[[ -n "${EXPLAIN_DATA}" ]] || die "set EXPLAIN_DATA_ROOT (or STARTER_DATA_ROOT)"

echo "==> Checking data disk (${EXPLAIN_DATA})"
if [[ -n "${DATA_ROOT_BASE}" ]]; then
  findmnt -n "${DATA_ROOT_BASE}" >/dev/null 2>&1 \
    || findmnt -T "${EXPLAIN_DATA}" >/dev/null 2>&1 \
    || die "${DATA_ROOT_BASE} is not mounted (wait for USB / fsck)"
fi

run_priv() {
  if [[ -w "${EXPLAIN_DATA}" ]] || [[ "$(id -u)" -eq 0 ]] || [[ -w "$(dirname "${EXPLAIN_DATA}")" ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    die "cannot write ${EXPLAIN_DATA} (need root or sudo)"
  fi
}

run_priv mkdir -p "${RAG_DOCS_HOST}" "${CHROMA_HOST}" "${VOICES_HOST}"

RAG_SRC=""
if [[ -d "${SITE_DIR}/explain/rag_docs" ]]; then
  RAG_SRC="${SITE_DIR}/explain/rag_docs"
elif [[ -d "${EXPLAIN_DIR}/rag_docs" ]]; then
  RAG_SRC="${EXPLAIN_DIR}/rag_docs"
else
  die "missing rag_docs (run ./scripts/apply-site.sh or set STARTER_SITE_DIR)"
fi

echo "==> Syncing rag_docs from ${RAG_SRC} → ${RAG_DOCS_HOST}"
if command -v rsync >/dev/null 2>&1; then
  run_priv rsync -a --delete "${RAG_SRC}/" "${RAG_DOCS_HOST}/"
else
  run_priv bash -c "find '${RAG_DOCS_HOST}' -mindepth 1 -delete && cp -a '${RAG_SRC}/.' '${RAG_DOCS_HOST}/'"
fi

if [[ ! -f "${VOICES_HOST}/it_IT-serena-high.onnx" ]] \
   && [[ ! -f "${VOICES_HOST}/it_IT-paola-medium.onnx" ]]; then
  echo "WARNING: no Piper .onnx under ${VOICES_HOST}" >&2
fi

echo "==> Ensuring docker volume ollama_data"
docker volume create ollama_data >/dev/null

echo "==> Starting explain stack (compose)"
for c in ollama piper_tts explain_service; do
  if docker container inspect "${c}" >/dev/null 2>&1; then
    proj="$(docker inspect "${c}" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null || true)"
    if [[ "${proj}" != "explain" ]]; then
      echo "    Removing leftover container ${c} (project=${proj:-none})"
      docker rm -f "${c}" >/dev/null
    fi
  fi
done

export EXPLAIN_DATA_ROOT="${EXPLAIN_DATA}"
docker compose -p explain -f "${COMPOSE_FILE}" up -d --build

echo "==> Waiting for services"
ready_ollama=0
ready_rag=0
for _ in $(seq 1 60); do
  if curl -sf "http://127.0.0.1:11434/api/tags" >/dev/null 2>&1; then
    ready_ollama=1
  fi
  if curl -sf "http://127.0.0.1:5001/openapi.json" >/dev/null 2>&1; then
    ready_rag=1
  fi
  if [[ "${ready_ollama}" -eq 1 && "${ready_rag}" -eq 1 ]]; then
    break
  fi
  sleep 2
done

echo "==> Smoke tests"
[[ "${ready_ollama}" -eq 1 ]] || die "Ollama not reachable at http://127.0.0.1:11434"
echo "OK: Ollama :11434"
[[ "${ready_rag}" -eq 1 ]] || die "explain_service not reachable at http://127.0.0.1:5001"
echo "OK: RAG openapi :5001"

if ss -ltn 2>/dev/null | grep -qE '[:.]5005'; then
  echo "OK: Piper/Wyoming listening on :5005"
else
  die "Piper/Wyoming not listening on :5005"
fi

echo "==> Reindex if docs changed"
STATE_DIR="${RAG_STATE_DIR:-/var/lib/rag-reindex}"
run_priv mkdir -p "${STATE_DIR}"
RAG_DOCS_DIR="${RAG_DOCS_HOST}" \
  RAG_INDEX_URL="${RAG_INDEX_URL:-http://127.0.0.1:5001/index}" \
  RAG_STATE_DIR="${STATE_DIR}" \
  bash -c '
    if [[ -w "${RAG_STATE_DIR}" ]]; then
      exec "'"${EXPLAIN_DIR}"'/reindex.sh"
    elif command -v sudo >/dev/null 2>&1; then
      exec sudo env RAG_DOCS_DIR="${RAG_DOCS_DIR}" RAG_INDEX_URL="${RAG_INDEX_URL}" RAG_STATE_DIR="${RAG_STATE_DIR}" "'"${EXPLAIN_DIR}"'/reindex.sh"
    else
      exec "'"${EXPLAIN_DIR}"'/reindex.sh"
    fi
  ' || {
    echo "WARNING: reindex failed (stack is up; fix index manually)" >&2
  }

echo "==> Installing /usr/local/bin/rag-reindex"
if [[ "$(id -u)" -eq 0 ]]; then
  install -m 755 "${EXPLAIN_DIR}/reindex.sh" /usr/local/bin/rag-reindex
elif command -v sudo >/dev/null 2>&1; then
  sudo install -m 755 "${EXPLAIN_DIR}/reindex.sh" /usr/local/bin/rag-reindex
fi

echo
echo "Done."
echo "  Compose:  docker compose -p explain -f ${COMPOSE_FILE} ps"
echo "  RAG:      http://127.0.0.1:5001/explain"
echo "  Ollama:   http://127.0.0.1:11434"
echo "  Piper:    tcp://127.0.0.1:5005"
echo "  Systemd:  sudo ./explain/install-systemd.sh"
