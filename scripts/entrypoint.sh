#!/usr/bin/env bash
# Seed persistent volumes, wait for external MySQL, ensure DB/gsettings, then run CMD.
set -euo pipefail

/usr/local/libexec/starter/seed-volumes.sh

# External shared mysql-server (required). Defaults match house host networking.
export STARTER_DB_HOST="${STARTER_DB_HOST:-127.0.0.1}"
export STARTER_DB_PORT="${STARTER_DB_PORT:-3306}"
export STARTER_MYSQL_ROOT_PASSWORD="${STARTER_MYSQL_ROOT_PASSWORD:-}"

/usr/local/libexec/starter/init-starter-db.sh

echo "STARTER DB: ${STARTER_DB_HOST}:${STARTER_DB_PORT} (external mysql-server)"
exec "$@"
