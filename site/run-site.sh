#!/usr/bin/env bash
# Build image from imported www/ and (re)create the starter-www container.
#
#   ./site/apply-www.sh && ./site/run-site.sh
#   STARTER_WWW_PORT=8090 ./site/run-site.sh
#
# Publishes on all interfaces by default so the LAN can reach it before
# cloudflared is wired (bind STARTER_WWW_BIND=127.0.0.1 for tunnel-only later).
set -euo pipefail

SITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${STARTER_WWW_IMAGE:-starter-www:local}"
NAME="${STARTER_WWW_CONTAINER_NAME:-starter-www}"
PORT="${STARTER_WWW_PORT:-8090}"
BIND="${STARTER_WWW_BIND:-0.0.0.0}"
IMPORT_DIR="${SITE_DIR}/import"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "${IMPORT_DIR}/package.json" ]] || die "missing import/ — run ./site/apply-www.sh first"

echo "==> Building ${IMAGE}"
DOCKER_BUILDKIT=1 docker build -t "${IMAGE}" "${SITE_DIR}"

if docker container inspect "${NAME}" >/dev/null 2>&1; then
  echo "==> Removing existing ${NAME}"
  docker rm -f "${NAME}" >/dev/null
fi

echo "==> Starting ${NAME} on ${BIND}:${PORT}->80"
docker run -d \
  --name "${NAME}" \
  --restart unless-stopped \
  -p "${BIND}:${PORT}:80" \
  "${IMAGE}" >/dev/null

echo
echo "Done."
echo "  Local/LAN: http://$(hostname -I 2>/dev/null | awk '{print $1}'):${PORT}/"
echo "  Direct:    http://127.0.0.1:${PORT}/"
echo "  Cloudflare ingress (later): hostname -> http://127.0.0.1:${PORT}"
