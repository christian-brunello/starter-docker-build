#!/usr/bin/env bash
# Start a plain Grafana container (no baked-in dashboards/datasources).
#
# Optional site provisioning:
#   STARTER_SITE_DIR=../docker-build-sitedir ./run-grafana.sh
#   # mounts $STARTER_SITE_DIR/grafana/provisioning when present
#
# Usage:
#   ./run-grafana.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${ROOT}/.." && pwd)"
IMAGE="${GRAFANA_IMAGE:-grafana/grafana-oss:latest}"
NAME="${GRAFANA_CONTAINER_NAME:-grafana}"
DATA="${GRAFANA_DATA:-/mnt/grafana}"
NETWORK="${GRAFANA_NETWORK:-grafana_default}"
TZ_VAL="${TZ:-Europe/Rome}"
DEFAULT_SITE="$(cd "${REPO}/.." && pwd)/docker-build-sitedir"
SITE_DIR="${STARTER_SITE_DIR:-${DEFAULT_SITE}}"
PROVISIONING="${GRAFANA_PROVISIONING:-}"

PLUGINS="${GF_INSTALL_PLUGINS:-}"
UNSIGNED="${GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS:-}"

if [[ -z "${PROVISIONING}" && -d "${SITE_DIR}/grafana/provisioning" ]]; then
  PROVISIONING="${SITE_DIR}/grafana/provisioning"
fi

if [[ ! -d "${DATA}" ]]; then
  echo "Grafana data path ${DATA} does not exist" >&2
  exit 1
fi

docker network inspect "${NETWORK}" >/dev/null 2>&1 || docker network create "${NETWORK}"

if docker container inspect "${NAME}" >/dev/null 2>&1; then
  echo "Removing existing container ${NAME}"
  docker rm -f "${NAME}" >/dev/null
fi

run_args=(
  -d
  --name "${NAME}"
  --restart unless-stopped
  --network "${NETWORK}"
  --add-host=host.docker.internal:host-gateway
  -p 3000:3000
  -e "TZ=${TZ_VAL}"
  -v "${DATA}:/var/lib/grafana"
)

if [[ -n "${PLUGINS}" ]]; then
  run_args+=(-e "GF_INSTALL_PLUGINS=${PLUGINS}")
fi
if [[ -n "${UNSIGNED}" ]]; then
  run_args+=(-e "GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS=${UNSIGNED}")
fi

if [[ -n "${PROVISIONING}" && -d "${PROVISIONING}" ]]; then
  echo "  provisioning: ${PROVISIONING}"
  run_args+=(
    -e "GF_PATHS_PROVISIONING=/etc/grafana/provisioning"
    -v "${PROVISIONING}:/etc/grafana/provisioning:ro"
  )
  HOME_DASH="${PROVISIONING}/dashboards/json/house/system-status.json"
  if [[ -f "${HOME_DASH}" ]]; then
    echo "  home dashboard: system-status.json"
    run_args+=(
      -e "GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/etc/grafana/provisioning/dashboards/json/house/system-status.json"
    )
  fi
  # Optional MySQL passwords for site mysql.yaml env substitution
  if [[ -z "${GRAFANA_STREADER_PASSWORD:-}" ]]; then
    if docker exec starter test -f /usr/local/etc/starter/db-credentials 2>/dev/null; then
      GRAFANA_STREADER_PASSWORD="$(docker exec starter sed -n 's/^DB_READER_PASS=//p' /usr/local/etc/starter/db-credentials || true)"
    fi
  fi
  if [[ -n "${GRAFANA_STREADER_PASSWORD:-}" ]]; then
    run_args+=(-e "GRAFANA_STREADER_PASSWORD=${GRAFANA_STREADER_PASSWORD}")
  fi
  if [[ -n "${GRAFANA_RACK_PASSWORD:-}" ]]; then
    run_args+=(-e "GRAFANA_RACK_PASSWORD=${GRAFANA_RACK_PASSWORD}")
  fi
else
  echo "  provisioning: (none — empty Grafana; see doc/grafana-starter.md)"
fi

echo "Starting ${NAME} (${IMAGE})"
echo "  data:         ${DATA}"
echo "  network:      ${NETWORK} + host.docker.internal + mysql-server nets"

docker run "${run_args[@]}" "${IMAGE}"

for net in mysql-server_default rack-net; do
  if docker network inspect "${net}" >/dev/null 2>&1; then
    docker network connect "${net}" "${NAME}" 2>/dev/null \
      && echo "  connected:   ${net}" \
      || echo "  already on:  ${net}"
  else
    echo "NOTE: docker network ${net} missing (start mysql-server first)" >&2
  fi
done

echo "Waiting for Grafana..."
for i in $(seq 1 60); do
  if curl -sf "http://127.0.0.1:3000/api/health" >/dev/null 2>&1; then
    echo "Grafana is up: http://127.0.0.1:3000"
    exit 0
  fi
  sleep 2
done

echo "Grafana did not become healthy in time; check: docker logs ${NAME}" >&2
exit 1
