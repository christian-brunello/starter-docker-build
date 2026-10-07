#!/usr/bin/env bash
# Seed persistent volumes, start mysqld, ensure DB/gsettings, then run CMD.
set -euo pipefail

MYSQL_DATADIR=/var/lib/mysql
MYSQL_RUNDIR=/var/run/mysqld
MYSQL_PID="${MYSQL_RUNDIR}/mysqld.pid"
MYSQL_SOCK="${MYSQL_RUNDIR}/mysqld.sock"
MYSQL_PORT="${STARTER_MYSQL_PORT:-3306}"

/usr/local/libexec/starter/seed-volumes.sh

mkdir -p "${MYSQL_RUNDIR}"
chown mysql:mysql "${MYSQL_RUNDIR}"

# Keep packaged starter.cnf in sync with runtime port
if [[ -f /etc/mysql/mysql.conf.d/starter.cnf ]]; then
    if grep -qE '^[[:space:]]*port[[:space:]]*=' /etc/mysql/mysql.conf.d/starter.cnf; then
        sed -i "s/^[[:space:]]*port[[:space:]]*=.*/port = ${MYSQL_PORT}/" \
            /etc/mysql/mysql.conf.d/starter.cnf
    else
        printf '\nport = %s\n' "${MYSQL_PORT}" >> /etc/mysql/mysql.conf.d/starter.cnf
    fi
fi

if [[ ! -d "${MYSQL_DATADIR}/mysql" ]]; then
    echo "Initializing MySQL data directory..."
    mysqld --initialize-insecure --user=mysql --datadir="${MYSQL_DATADIR}"
fi

if [[ ! -S "${MYSQL_SOCK}" ]]; then
    if command -v mysqld_safe >/dev/null 2>&1; then
        mysqld_safe --datadir="${MYSQL_DATADIR}" --pid-file="${MYSQL_PID}" \
            --bind-address=0.0.0.0 --port="${MYSQL_PORT}" &
    else
        mysqld --user=mysql --datadir="${MYSQL_DATADIR}" \
            --pid-file="${MYSQL_PID}" --socket="${MYSQL_SOCK}" \
            --bind-address=0.0.0.0 --port="${MYSQL_PORT}" \
            --daemonize
    fi
fi

# All-in-one image: gsettings db-port must match the mysqld listen port.
export STARTER_DB_PORT="${MYSQL_PORT}"

/usr/local/libexec/starter/init-starter-db.sh

echo "MySQL listening on 0.0.0.0:${MYSQL_PORT}"
exec "$@"
