#!/usr/bin/env bash
# Install starter-docker.service so the container starts at boot.
# Disables host starter-core + st-* units (stack runs inside the container).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBEXEC=/usr/local/libexec/starter-docker
DOC_DST=/usr/local/share/doc/starter-docker
UNIT_DST=/etc/systemd/system/starter-docker.service
ENV_DST=/etc/default/starter-docker

if [[ "$(id -u)" -ne 0 ]]; then
    echo "error: run as root (sudo $0)" >&2
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "error: docker not found" >&2
    exit 1
fi

if ! systemctl is-active --quiet docker && ! systemctl start docker; then
    echo "error: cannot start docker.service" >&2
    exit 1
fi

install -d -m 755 "${LIBEXEC}" "${DOC_DST}"
install -m 755 "${ROOT}/run.sh" "${LIBEXEC}/run.sh"
install -m 644 "${ROOT}/systemd/starter-docker.service" "${UNIT_DST}"
install -m 644 "${ROOT}/doc/starter-docker.md" "${DOC_DST}/starter-docker.md"

if [[ ! -f "${ENV_DST}" ]]; then
    SITE_DIR="${STARTER_SITE_DIR:-$(cd "${ROOT}/.." && pwd)/docker-build-sitedir}"
    SITE_ENV="${SITE_DIR}/host/starter-docker.default"
    EXAMPLE_ENV="${ROOT}/systemd/starter-docker.default.example"
    if [[ -f "${SITE_ENV}" ]]; then
        install -m 600 "${SITE_ENV}" "${ENV_DST}"
        echo "Installed ${ENV_DST} from ${SITE_ENV}"
    elif [[ -f "${EXAMPLE_ENV}" ]]; then
        install -m 644 "${EXAMPLE_ENV}" "${ENV_DST}"
        echo "Installed ${ENV_DST} from example — set STARTER_MYSQL_ROOT_PASSWORD"
    else
        echo "error: missing ${EXAMPLE_ENV}" >&2
        exit 1
    fi
else
    echo "Keeping existing ${ENV_DST}"
fi

# Container processes run as uid/gid 999 (user starter). The host system D-Bus
# authenticates by host UID: without a matching passwd entry, Avahi clients fail
# ("unexpected D-Bus error") and services cannot publish/browse mDNS.
if ! getent passwd 999 >/dev/null 2>&1; then
    primary_gid="$(getent group docker 2>/dev/null | cut -d: -f3 || true)"
    primary_gid="${primary_gid:-999}"
    useradd --system --uid 999 --gid "${primary_gid}" --groups netdev \
        --home-dir /home/starter --no-create-home --shell /usr/sbin/nologin \
        starter-docker
    echo "Created host user starter-docker (uid=999) in group netdev for Avahi/D-Bus"
else
    existing="$(getent passwd 999 | cut -d: -f1)"
    if getent group netdev >/dev/null 2>&1; then
        usermod -aG netdev "${existing}" 2>/dev/null || true
    fi
    echo "Host uid 999 already present (${existing}); ensured netdev membership"
fi

# Host-network container would clash with native units (same ports / mDNS / core).
disable_host_unit() {
    local unit="$1"
    if systemctl list-unit-files "${unit}" 2>/dev/null | grep -qF "${unit}"; then
        if systemctl is-enabled --quiet "${unit}" 2>/dev/null \
            || systemctl is-active --quiet "${unit}" 2>/dev/null; then
            echo "Disabling host ${unit} (stack runs inside starter-docker)"
            systemctl disable --now "${unit}" 2>/dev/null || true
        fi
    fi
}

disable_host_unit starter-core.service

# All st-*.service unit files present on the host
shopt -s nullglob
for unit_path in /lib/systemd/system/st-*.service /etc/systemd/system/st-*.service; do
    [[ -f "${unit_path}" ]] || continue
    disable_host_unit "$(basename "${unit_path}")"
done
shopt -u nullglob

systemctl daemon-reload
systemctl enable starter-docker.service

echo
echo "Installed starter-docker.service (enabled at boot)."
echo "  Config:  ${ENV_DST}"
echo "  Unit:    ${UNIT_DST}"
echo "  Runner:  ${LIBEXEC}/run.sh"
echo "  Stack:   MySQL + supervisord (core, adapters, services) inside the container"
echo
echo "Ensure the image exists first:  cd ${ROOT} && ./build.sh"
echo "Refresh boot-services manifest (optional):  ./scripts/sync-boot-services.sh"
echo "Then start:  systemctl start starter-docker.service"
echo "Status:      systemctl status starter-docker.service"
