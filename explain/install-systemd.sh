#!/usr/bin/env bash
# Install explain-stack.service so Ollama / Piper / RAG start at boot.
#
#   sudo ./explain/install-systemd.sh
#
# Optional host daemon:
#   sudo INSTALL_STARTER_EXPLAIN=1 ./explain/install-systemd.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPLAIN_DIR="${ROOT}/explain"
DOC_DST=/usr/local/share/doc/starter-docker
UNIT_DST=/etc/systemd/system/explain-stack.service
ENV_DST=/etc/default/explain-stack
STEX_UNIT_DST=/etc/systemd/system/starter-explain.service
STEX_ENV_DST=/etc/default/starter-explain
SITE_DIR="${STARTER_SITE_DIR:-$(cd "${ROOT}/.." && pwd)/docker-build-sitedir}"
SITE_ENV="${SITE_DIR}/host/explain-stack.default"
EXAMPLE_ENV="${ROOT}/systemd/explain-stack.default.example"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: run as root (sudo $0)" >&2
  exit 1
fi

command -v docker >/dev/null 2>&1 || { echo "error: docker not found" >&2; exit 1; }
[[ -f "${EXPLAIN_DIR}/docker-compose.yml" ]] || {
  echo "error: missing ${EXPLAIN_DIR}/docker-compose.yml" >&2
  exit 1
}

install -d -m 755 "${DOC_DST}"
install -m 644 "${ROOT}/systemd/explain-stack.service" "${UNIT_DST}"
install -m 644 "${EXPLAIN_DIR}/README.md" "${DOC_DST}/explain-README.md"

if [[ ! -f "${ENV_DST}" ]]; then
  if [[ -f "${SITE_ENV}" ]]; then
    install -m 644 "${SITE_ENV}" "${ENV_DST}"
    if grep -q '^EXPLAIN_DIR=' "${ENV_DST}"; then
      sed -i "s|^EXPLAIN_DIR=.*|EXPLAIN_DIR=${EXPLAIN_DIR}|" "${ENV_DST}"
    else
      echo "EXPLAIN_DIR=${EXPLAIN_DIR}" >> "${ENV_DST}"
    fi
    echo "Installed ${ENV_DST} from ${SITE_ENV}"
  else
    sed "s|^EXPLAIN_DIR=.*|EXPLAIN_DIR=${EXPLAIN_DIR}|" "${EXAMPLE_ENV}" > "${ENV_DST}"
    chmod 644 "${ENV_DST}"
    echo "Installed ${ENV_DST} from example — set EXPLAIN_DATA_ROOT before start"
  fi
else
  echo "Keeping existing ${ENV_DST}"
fi

if ! grep -q "^EXPLAIN_DIR=${EXPLAIN_DIR}$" "${ENV_DST}" 2>/dev/null; then
  if ! grep -q '^EXPLAIN_DIR=' "${ENV_DST}" 2>/dev/null; then
    echo "EXPLAIN_DIR=${EXPLAIN_DIR}" >> "${ENV_DST}"
  fi
fi

install -m 755 "${EXPLAIN_DIR}/reindex.sh" /usr/local/bin/rag-reindex

systemctl daemon-reload
systemctl enable explain-stack.service
echo "Enabled explain-stack.service (EXPLAIN_DIR=${EXPLAIN_DIR})"

if [[ "${INSTALL_STARTER_EXPLAIN:-0}" == "1" ]]; then
  install -m 644 "${ROOT}/systemd/starter-explain.service" "${STEX_UNIT_DST}"
  if [[ ! -f "${STEX_ENV_DST}" ]]; then
    STEX_CFG="${SITE_DIR}/explain/home.stex.xml"
    [[ -f "${STEX_CFG}" ]] || STEX_CFG="${EXPLAIN_DIR}/home.stex.xml.example"
    cat > "${STEX_ENV_DST}" <<EOF
STEX_CONFIG=${STEX_CFG}
EOF
    chmod 644 "${STEX_ENV_DST}"
  fi
  systemctl daemon-reload
  if command -v starter-explain >/dev/null 2>&1; then
    systemctl enable starter-explain.service
    echo "Enabled starter-explain.service"
  else
    echo "NOTE: starter-explain binary not in PATH; unit installed but not enabled."
  fi
fi

echo
echo "Next:"
echo "  ${EXPLAIN_DIR}/deploy.sh"
echo "  sudo systemctl start explain-stack.service"
