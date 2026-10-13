#!/usr/bin/env bash
# Import sibling www/ sources into this packaging tree (like apply-site for overlay).
#
#   ./site/apply-www.sh
#   STARTER_WWW_DIR=/path/to/www ./site/apply-www.sh
#
# Does not modify www/. Safe to re-run before ./site/deploy.sh.
set -euo pipefail

SITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SITE_DIR}/.." && pwd)"
DEFAULT_WWW="$(cd "${ROOT}/.." && pwd)/www"
WWW_DIR="${STARTER_WWW_DIR:-${DEFAULT_WWW}}"
IMPORT_DIR="${SITE_DIR}/import"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -d "${WWW_DIR}" ]] || die "www dir not found: ${WWW_DIR} (set STARTER_WWW_DIR)"
[[ -f "${WWW_DIR}/package.json" ]] || die "missing ${WWW_DIR}/package.json"

echo "==> STARTER_WWW_DIR=${WWW_DIR}"
echo "==> Import → ${IMPORT_DIR}"

mkdir -p "${IMPORT_DIR}"
rsync -a --delete \
  --exclude='node_modules/' \
  --exclude='_site/' \
  --exclude='.cache/' \
  --exclude='.git/' \
  "${WWW_DIR}/" "${IMPORT_DIR}/"

echo "Done. Next: ./site/deploy.sh"
