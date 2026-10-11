#!/usr/bin/env bash
# One-shot: copy STARTER schema+data from in-container mysqld (:3307) into mysql-server (:3306).
# Preserves STWriter/STReader passwords from starter db-credentials and points starter at :3306.
#
#   ./mysql-server/migrate-from-starter.sh
set -euo pipefail

STARTER_NAME="${STARTER_CONTAINER_NAME:-starter}"
MYSQL_SERVER="${MYSQL_SERVER_CONTAINER:-mysql-server}"
ROOT_PASS="${MYSQL_ROOT_PASSWORD:-}"
DUMP="${DUMP_FILE:-/tmp/starter-db-migrate-$$.sql}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -n "${ROOT_PASS}" ]] || die "set MYSQL_ROOT_PASSWORD"
command -v docker >/dev/null 2>&1 || die "docker not found"
docker container inspect "${STARTER_NAME}" >/dev/null 2>&1 || die "container ${STARTER_NAME} not running"
docker container inspect "${MYSQL_SERVER}" >/dev/null 2>&1 || die "container ${MYSQL_SERVER} not running"

echo "==> Reading credentials from ${STARTER_NAME}"
CRED="$(docker exec "${STARTER_NAME}" cat /usr/local/etc/starter/db-credentials)"
WRITER_USER="$(echo "${CRED}" | sed -n 's/^DB_WRITER_USER=//p')"
WRITER_PASS="$(echo "${CRED}" | sed -n 's/^DB_WRITER_PASS=//p')"
READER_USER="$(echo "${CRED}" | sed -n 's/^DB_READER_USER=//p')"
READER_PASS="$(echo "${CRED}" | sed -n 's/^DB_READER_PASS=//p')"
[[ -n "${WRITER_USER}" && -n "${WRITER_PASS}" ]] || die "missing writer credentials"

echo "==> Pre-migration counts (source :3307 / socket)"
docker exec "${STARTER_NAME}" mysql --protocol=socket -uroot -N -e \
  "SELECT CONCAT('labels=',COUNT(*)) FROM STARTER.labels;
   SELECT CONCAT('history=',COUNT(*)) FROM STARTER.history;
   SELECT CONCAT('stats=',COUNT(*)) FROM STARTER.stats;"

echo "==> Dumping STARTER from ${STARTER_NAME}"
docker exec "${STARTER_NAME}" mysqldump --protocol=socket -uroot \
  --databases STARTER --single-transaction --routines --triggers \
  > "${DUMP}"
[[ -s "${DUMP}" ]] || die "empty dump"
echo "    dump size: $(wc -c < "${DUMP}") bytes"

echo "==> Importing into ${MYSQL_SERVER}"
docker exec -i "${MYSQL_SERVER}" mysql -uroot -p"${ROOT_PASS}" < "${DUMP}"

echo "==> Creating/aligning STARTER users (same passwords)"
docker exec "${MYSQL_SERVER}" mysql -uroot -p"${ROOT_PASS}" <<EOF
CREATE DATABASE IF NOT EXISTS STARTER
  CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE USER IF NOT EXISTS '${WRITER_USER}'@'%' IDENTIFIED WITH mysql_native_password BY '${WRITER_PASS}';
CREATE USER IF NOT EXISTS '${READER_USER}'@'%' IDENTIFIED WITH mysql_native_password BY '${READER_PASS}';
ALTER USER '${WRITER_USER}'@'%' IDENTIFIED WITH mysql_native_password BY '${WRITER_PASS}';
ALTER USER '${READER_USER}'@'%' IDENTIFIED WITH mysql_native_password BY '${READER_PASS}';
GRANT SELECT, INSERT, UPDATE, DELETE ON STARTER.* TO '${WRITER_USER}'@'%';
GRANT SELECT ON STARTER.* TO '${READER_USER}'@'%';
FLUSH PRIVILEGES;
EOF

echo "==> Post-migration counts (mysql-server)"
docker exec "${MYSQL_SERVER}" mysql -uroot -p"${ROOT_PASS}" -N -e \
  "SELECT CONCAT('labels=',COUNT(*)) FROM STARTER.labels;
   SELECT CONCAT('history=',COUNT(*)) FROM STARTER.history;
   SELECT CONCAT('stats=',COUNT(*)) FROM STARTER.stats;"

echo "==> Pointing starter db-credentials + gsettings at 127.0.0.1:3306"
docker exec "${STARTER_NAME}" bash -c "
set -euo pipefail
CRED=/usr/local/etc/starter/db-credentials
umask 077
cat > \"\${CRED}\" <<EOF
# Migrated to external mysql-server — $(date -Iseconds)
DB_HOST=127.0.0.1
DB_PORT=3306
DB_WRITER_USER=${WRITER_USER}
DB_WRITER_PASS=${WRITER_PASS}
DB_READER_USER=${READER_USER}
DB_READER_PASS=${READER_PASS}
EOF
chown root:starter \"\${CRED}\"
chmod 640 \"\${CRED}\"
touch /usr/local/etc/starter/.starter-db-initialized

# gschema override for next boot / new processes
for dir in /usr/local/share/glib-2.0/schemas /usr/share/glib-2.0/schemas; do
  mkdir -p \"\${dir}\"
  cat > \"\${dir}/99_starter-docker.gschema.override\" <<GSEOF
[org.starter.core]
db-host='127.0.0.1'
db-port=3306
db-user='${WRITER_USER}'
db-pass='${WRITER_PASS}'
rules-preprocessor='m4 {F}'
GSEOF
  glib-compile-schemas \"\${dir}\" || true
done

# Live dconf for user starter
install -d -o starter -g starter -m 700 /home/starter/.config/dconf /home/starter/.cache/dconf || true
gset() {
  runuser -u starter -- env \
    XDG_DATA_DIRS=/usr/local/share:/usr/share \
    GSETTINGS_SCHEMA_DIR=/usr/share/glib-2.0/schemas \
    HOME=/home/starter \
    dbus-run-session -- gsettings set org.starter.core \"\$1\" \"\$2\" || true
}
gset db-host '127.0.0.1'
gset db-port 3306
gset db-user '${WRITER_USER}'
gset db-pass '${WRITER_PASS}'
"

rm -f "${DUMP}"

echo
echo "Done. STARTER now lives on ${MYSQL_SERVER}:3306."
echo "  Restart starter so all processes pick up gsettings:"
echo "    sudo systemctl restart starter-docker.service"
echo "  Keep volume starter-mysql as backup until verified."
echo "  After image rebuild (no in-container mysqld), redeploy with STARTER_EXTERNAL_MYSQL=1."
