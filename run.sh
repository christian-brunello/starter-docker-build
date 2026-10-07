#!/usr/bin/env bash
# Run STARTER with host networking and persistent named volumes for mutable data.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_TAG="${IMAGE_TAG:-starter:local}"
NAME="${STARTER_CONTAINER_NAME:-starter}"
VOL_PREFIX="${STARTER_VOLUME_PREFIX:-starter}"

VOL_MYSQL="${VOL_PREFIX}-mysql"
VOL_ETC="${VOL_PREFIX}-etc"
VOL_HOME="${VOL_PREFIX}-home"

ensure_volume() {
    if ! docker volume inspect "$1" >/dev/null 2>&1; then
        docker volume create "$1" >/dev/null
        echo "created volume: $1"
    fi
}

extra_args=()

# Host networking + host Avahi via system D-Bus.
# Docker's default AppArmor profile blocks D-Bus Hello → Avahi "Access denied".
# Override unless STARTER_APPARMOR is set (e.g. STARTER_APPARMOR=docker-default).
APPARMOR_PROFILE="${STARTER_APPARMOR:-unconfined}"
extra_args+=(--security-opt "apparmor=${APPARMOR_PROFILE}")

if [[ -S /var/run/dbus/system_bus_socket ]]; then
    extra_args+=(-v /var/run/dbus/system_bus_socket:/var/run/dbus/system_bus_socket)
fi
# Help D-Bus/Avahi match the host identity when using the host bus
if [[ -f /etc/machine-id ]]; then
    extra_args+=(-v /etc/machine-id:/etc/machine-id:ro)
fi

# --- persistent mutable data (survive image rebuild) ---
if [[ -n "${STARTER_MYSQL_DATA:-}" ]]; then
    mkdir -p "${STARTER_MYSQL_DATA}"
    extra_args+=(-v "${STARTER_MYSQL_DATA}:/var/lib/mysql")
    echo "MySQL data: bind ${STARTER_MYSQL_DATA}"
else
    ensure_volume "${VOL_MYSQL}"
    extra_args+=(-v "${VOL_MYSQL}:/var/lib/mysql")
    echo "MySQL data: volume ${VOL_MYSQL}"
fi

if [[ -n "${STARTER_ETC:-}" ]]; then
    mkdir -p "${STARTER_ETC}"
    extra_args+=(-v "${STARTER_ETC}:/usr/local/etc/starter")
    echo "Configs: bind ${STARTER_ETC}"
else
    ensure_volume "${VOL_ETC}"
    extra_args+=(-v "${VOL_ETC}:/usr/local/etc/starter")
    echo "Configs: volume ${VOL_ETC}"
fi

if [[ -n "${STARTER_HOME:-}" ]]; then
    mkdir -p "${STARTER_HOME}"
    extra_args+=(-v "${STARTER_HOME}:/home/starter")
    echo "Home/dconf: bind ${STARTER_HOME}"
else
    ensure_volume "${VOL_HOME}"
    extra_args+=(-v "${VOL_HOME}:/home/starter")
    echo "Home/dconf: volume ${VOL_HOME}"
fi

MYSQL_PORT="${STARTER_MYSQL_PORT:-3306}"
echo "Running ${IMAGE_TAG} as ${NAME} (--network=host, apparmor=${APPARMOR_PROFILE})"
echo "  MySQL listens on 0.0.0.0:${MYSQL_PORT}"
echo "  Tip: stop host mysqld if it owns that port, or set STARTER_MYSQL_PORT."
echo "  Rebuilds keep volumes; overlay only seeds *missing* files on first use."

tty_args=()
if [[ -t 0 && -t 1 ]]; then
    tty_args+=(-it)
else
    tty_args+=(-i)
fi

exec docker run --rm "${tty_args[@]}" \
    --name "${NAME}" \
    --network=host \
    -e "STARTER_MYSQL_PORT=${MYSQL_PORT}" \
    -e "STARTER_DB_HOST=${STARTER_DB_HOST:-127.0.0.1}" \
    -e "STARTER_DB_PORT=${MYSQL_PORT}" \
    -e "STARTER_DB_WRITER_PASS=${STARTER_DB_WRITER_PASS:-}" \
    -e "STARTER_DB_READER_PASS=${STARTER_DB_READER_PASS:-}" \
    "${extra_args[@]}" \
    "${IMAGE_TAG}" \
    "$@"
