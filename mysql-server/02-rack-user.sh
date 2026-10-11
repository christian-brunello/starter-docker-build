#!/bin/bash
# Optional first-init helper: create compute_rack rack-user from MYSQL_RACK_PASSWORD.
set -euo pipefail

if [[ -z "${MYSQL_RACK_PASSWORD:-}" ]]; then
  echo "02-rack-user: MYSQL_RACK_PASSWORD unset; skipping rack-user creation"
  exit 0
fi

mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" <<EOF
CREATE USER IF NOT EXISTS 'rack-user'@'%' IDENTIFIED WITH mysql_native_password BY '${MYSQL_RACK_PASSWORD}';
ALTER USER 'rack-user'@'%' IDENTIFIED WITH mysql_native_password BY '${MYSQL_RACK_PASSWORD}';
GRANT ALL PRIVILEGES ON compute_rack.* TO 'rack-user'@'%';
FLUSH PRIVILEGES;
EOF

echo "02-rack-user: rack-user ready"
