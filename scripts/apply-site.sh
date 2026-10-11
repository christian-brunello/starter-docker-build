#!/usr/bin/env bash
# Apply private docker-build-sitedir into this public tree (overlay + explain config).
#
#   ./scripts/apply-site.sh
#   STARTER_SITE_DIR=/path/to/docker-build-sitedir ./scripts/apply-site.sh
#
# Does not modify the sitedir. Safe to re-run before ./build.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_SITE="$(cd "${ROOT}/.." && pwd)/docker-build-sitedir"
SITE_DIR="${STARTER_SITE_DIR:-${DEFAULT_SITE}}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -d "${SITE_DIR}" ]] || die "site dir not found: ${SITE_DIR} (set STARTER_SITE_DIR)"

echo "==> STARTER_SITE_DIR=${SITE_DIR}"

OVERLAY_SRC="${SITE_DIR}/overlay/etc/starter"
OVERLAY_DST="${ROOT}/overlay/etc/starter"
if [[ -d "${OVERLAY_SRC}" ]]; then
  echo "==> Syncing overlay → ${OVERLAY_DST}"
  mkdir -p "${OVERLAY_DST}"
  rsync -a --delete \
    --exclude='.gitkeep' \
    --exclude='README.md' \
    "${OVERLAY_SRC}/" "${OVERLAY_DST}/"
  touch "${OVERLAY_DST}/.gitkeep"
else
  echo "WARNING: no ${OVERLAY_SRC}" >&2
fi

STEX_SRC="${SITE_DIR}/explain/home.stex.xml"
STEX_DST="${OVERLAY_DST}/explain/home.stex.xml"
if [[ -f "${STEX_SRC}" ]]; then
  echo "==> Installing home.stex.xml into overlay (for image bake)"
  mkdir -p "$(dirname "${STEX_DST}")"
  install -m 644 "${STEX_SRC}" "${STEX_DST}"
else
  echo "WARNING: no ${STEX_SRC} (image will use home.stex.xml.example)" >&2
fi

RAG_SRC="${SITE_DIR}/explain/rag_docs"
RAG_DST="${ROOT}/explain/rag_docs"
if [[ -d "${RAG_SRC}" ]]; then
  echo "==> Syncing rag_docs → ${RAG_DST} (for explain/deploy.sh)"
  mkdir -p "${RAG_DST}"
  rsync -a --delete "${RAG_SRC}/" "${RAG_DST}/"
else
  echo "NOTE: no ${RAG_SRC}"
fi

echo
echo "Done. Next: ./build.sh  (and ./explain/deploy.sh for sidecars)"
echo "Grafana provisioning (if any): ${SITE_DIR}/grafana/provisioning"
