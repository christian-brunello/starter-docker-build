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
  # Kiosk / long-lived browser sessions: default 10m rotation causes 401
  # "token needs to be rotated" when the client misses Set-Cookie (Firefox
  # private window, flaky reverse-proxy). 12h is enough for the house display.
  -e "GF_AUTH_TOKEN_ROTATION_INTERVAL_MINUTES=${GF_AUTH_TOKEN_ROTATION_INTERVAL_MINUTES:-720}"
  -e "GF_AUTH_LOGIN_MAXIMUM_INACTIVE_LIFETIME_DURATION=${GF_AUTH_LOGIN_MAXIMUM_INACTIVE_LIFETIME_DURATION:-30d}"
  -e "GF_AUTH_LOGIN_MAXIMUM_LIFETIME_DURATION=${GF_AUTH_LOGIN_MAXIMUM_LIFETIME_DURATION:-30d}"
  # House wall display: allow unauthenticated Viewer (login form still works for admin).
  -e "GF_AUTH_ANONYMOUS_ENABLED=${GF_AUTH_ANONYMOUS_ENABLED:-true}"
  -e "GF_AUTH_ANONYMOUS_ORG_ROLE=${GF_AUTH_ANONYMOUS_ORG_ROLE:-Viewer}"
  # Allow iframe embeds from web-ui (:18767) and other LAN origins.
  -e "GF_SECURITY_ALLOW_EMBEDDING=${GF_SECURITY_ALLOW_EMBEDDING:-true}"
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
  else
    echo "NOTE: GRAFANA_STREADER_PASSWORD unset — STARTER mysql datasource may fail" >&2
  fi
  # rack-user password: env, else MYSQL_RACK_PASSWORD from site/host defaults
  if [[ -z "${GRAFANA_RACK_PASSWORD:-}" ]]; then
    for envf in \
      "${SITE_DIR}/host/mysql-server.default" \
      "/etc/default/mysql-server"; do
      if [[ -r "${envf}" ]]; then
        GRAFANA_RACK_PASSWORD="$(sed -n 's/^MYSQL_RACK_PASSWORD=//p' "${envf}" | head -n1)"
        [[ -n "${GRAFANA_RACK_PASSWORD:-}" ]] && break
      fi
    done
  fi
  if [[ -n "${GRAFANA_RACK_PASSWORD:-}" ]]; then
    run_args+=(-e "GRAFANA_RACK_PASSWORD=${GRAFANA_RACK_PASSWORD}")
  else
    echo "NOTE: GRAFANA_RACK_PASSWORD unset — compute_rack (mysql-1) datasource will fail" >&2
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
