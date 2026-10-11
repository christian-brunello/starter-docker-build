#!/usr/bin/env bash
# Install mysql-server.service (compose on data disk) at boot.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MS_DIR="${ROOT}/mysql-server"
UNIT_DST=/etc/systemd/system/mysql-server.service
ENV_DST=/etc/default/mysql-server
DOC_DST=/usr/local/share/doc/starter-docker
SITE_DIR="${STARTER_SITE_DIR:-$(cd "${ROOT}/.." && pwd)/docker-build-sitedir}"
SITE_ENV="${SITE_DIR}/host/mysql-server.default"
EXAMPLE_ENV="${ROOT}/systemd/mysql-server.default.example"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: run as root (sudo $0)" >&2
  exit 1
fi

command -v docker >/dev/null 2>&1 || { echo "error: docker not found" >&2; exit 1; }
[[ -f "${MS_DIR}/docker-compose.yml" ]] || { echo "error: missing compose" >&2; exit 1; }

install -d -m 755 "${DOC_DST}"
install -m 644 "${ROOT}/systemd/mysql-server.service" "${UNIT_DST}"
if [[ -f "${MS_DIR}/README.md" ]]; then
  install -m 644 "${MS_DIR}/README.md" "${DOC_DST}/mysql-server-README.md"
fi

if [[ ! -f "${ENV_DST}" ]]; then
  if [[ -f "${SITE_ENV}" ]]; then
    install -m 600 "${SITE_ENV}" "${ENV_DST}"
    # Ensure MYSQL_SERVER_DIR points at this tree
    if grep -q '^MYSQL_SERVER_DIR=' "${ENV_DST}"; then
      sed -i "s|^MYSQL_SERVER_DIR=.*|MYSQL_SERVER_DIR=${MS_DIR}|" "${ENV_DST}"
    else
      echo "MYSQL_SERVER_DIR=${MS_DIR}" >> "${ENV_DST}"
    fi
    echo "Installed ${ENV_DST} from ${SITE_ENV}"
  elif [[ -f "${EXAMPLE_ENV}" ]]; then
    sed "s|^MYSQL_SERVER_DIR=.*|MYSQL_SERVER_DIR=${MS_DIR}|" "${EXAMPLE_ENV}" > "${ENV_DST}"
    chmod 600 "${ENV_DST}"
    echo "Installed ${ENV_DST} from example — edit passwords/paths before start"
  else
    cat > "${ENV_DST}" <<EOF
MYSQL_SERVER_DIR=${MS_DIR}
MYSQL_DATA_DIR=/mnt/data/mysql-server-data
MYSQL_ROOT_PASSWORD=CHANGE_ME
EOF
    chmod 600 "${ENV_DST}"
    echo "Installed ${ENV_DST} — edit before start"
  fi
else
  echo "Keeping existing ${ENV_DST}"
fi

systemctl daemon-reload
systemctl enable mysql-server.service
echo "Enabled mysql-server.service"
echo "  sudo systemctl start mysql-server.service"
