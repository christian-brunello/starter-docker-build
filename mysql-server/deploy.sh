#!/usr/bin/env bash
# Deploy shared MySQL (compute_rack + STARTER) on the data disk.
#
#   MYSQL_ROOT_PASSWORD=… MYSQL_DATA_DIR=… ./mysql-server/deploy.sh
#
# Or source /etc/default/mysql-server / sitedir host/mysql-server.default first.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MS_DIR="${ROOT}/mysql-server"
COMPOSE_FILE="${MS_DIR}/docker-compose.yml"

# Optional site / host defaults
if [[ -f /etc/default/mysql-server ]]; then
  # shellcheck disable=SC1091
  set -a; source /etc/default/mysql-server; set +a
fi

DATA_ROOT="${STARTER_DATA_ROOT:-${EXPLAIN_TOSHIBA_ROOT:-}}"
DATA_DIR="${MYSQL_DATA_DIR:-}"
if [[ -z "${DATA_DIR}" && -n "${DATA_ROOT}" ]]; then
  DATA_DIR="${DATA_ROOT}/mysql-server-data"
fi

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "${COMPOSE_FILE}" ]] || die "missing ${COMPOSE_FILE}"
command -v docker >/dev/null 2>&1 || die "docker not found"
[[ -n "${MYSQL_ROOT_PASSWORD:-}" ]] || die "set MYSQL_ROOT_PASSWORD"
[[ -n "${DATA_DIR}" ]] || die "set MYSQL_DATA_DIR (or STARTER_DATA_ROOT)"

if [[ -n "${DATA_ROOT}" ]]; then
  echo "==> Checking data disk mount (${DATA_ROOT})"
  findmnt -n "${DATA_ROOT}" >/dev/null 2>&1 \
    || findmnt -T "${DATA_DIR}" >/dev/null 2>&1 \
    || die "${DATA_ROOT} is not mounted"
fi

if [[ ! -d "${DATA_DIR}" ]]; then
  if [[ "$(id -u)" -eq 0 ]]; then
    mkdir -p "${DATA_DIR}"
  else
    sudo mkdir -p "${DATA_DIR}"
  fi
fi

if ! docker network inspect rack-net >/dev/null 2>&1; then
  echo "==> Creating docker network rack-net"
  docker network create rack-net
fi

echo "==> Starting mysql-server"
export MYSQL_DATA_DIR="${DATA_DIR}"
export MYSQL_ROOT_PASSWORD
export MYSQL_RACK_PASSWORD="${MYSQL_RACK_PASSWORD:-}"
docker compose -p mysql-server -f "${COMPOSE_FILE}" up -d

echo "==> Waiting for MySQL"
for _ in $(seq 1 60); do
  if docker exec mysql-server mysqladmin -uroot -p"${MYSQL_ROOT_PASSWORD}" ping --silent 2>/dev/null; then
    echo "OK: mysql-server ready"
    break
  fi
  sleep 2
done

docker exec mysql-server mysqladmin -uroot -p"${MYSQL_ROOT_PASSWORD}" ping --silent 2>/dev/null \
  || die "mysql-server not ready"

echo
echo "Done. Data: ${DATA_DIR}"
echo "  Deploy STARTER schema/users: starter container init (or migrate-from-starter.sh)"
echo "  Systemd: sudo ./mysql-server/install-systemd.sh"
