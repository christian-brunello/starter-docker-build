#!/usr/bin/env bash
# Run STARTER with host networking and persistent named volumes for mutable data.
# MySQL is external (mysql-server on 127.0.0.1:3306); no starter-mysql volume.
#
# Usage:
#   ./run.sh                         # interactive bash (default CMD)
#   ./run.sh bash -lc '...'          # custom command
#   ./run.sh --service               # foreground supervisord stack (for systemd)
#   ./run.sh --detach                # background container running the same stack
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_TAG="${IMAGE_TAG:-starter:local}"
NAME="${STARTER_CONTAINER_NAME:-starter}"
VOL_PREFIX="${STARTER_VOLUME_PREFIX:-starter}"

VOL_ETC="${VOL_PREFIX}-etc"
VOL_HOME="${VOL_PREFIX}-home"

MODE=interactive
if [[ "${1:-}" == "--service" ]]; then
    MODE=service
    shift
elif [[ "${1:-}" == "--detach" || "${1:-}" == "-d" ]]; then
    MODE=detach
    shift
fi

ensure_volume() {
    if ! docker volume inspect "$1" >/dev/null 2>&1; then
        docker volume create "$1" >/dev/null
        echo "created volume: $1"
    fi
}

extra_args=()

# Host networking + host Avahi via system D-Bus.
APPARMOR_PROFILE="${STARTER_APPARMOR:-unconfined}"
extra_args+=(--security-opt "apparmor=${APPARMOR_PROFILE}")

if [[ -S /var/run/dbus/system_bus_socket ]]; then
    extra_args+=(-v /var/run/dbus/system_bus_socket:/var/run/dbus/system_bus_socket)
fi
if [[ -f /etc/machine-id ]]; then
    extra_args+=(-v /etc/machine-id:/etc/machine-id:ro)
fi

# PulseAudio for starter-explain (paplay) — desktop user session.
# Mount the whole runtime dir (not only the socket file): when Pulse recreates
# `native`, the container sees the new inode without a starter restart.
# Host dir is often mode 700 → ensure-pulse-access.sh keeps it 755.
# Cookie is staged under /run/starter-pulse/ (directory mount) so Pulse restarts
# can refresh the cookie in-place without stale Docker file-bind inodes.
PULSE_UID="${STARTER_PULSE_UID:-1000}"
PULSE_RUNTIME="${STARTER_PULSE_RUNTIME:-/run/user/${PULSE_UID}/pulse}"
PULSE_SOCKET="${PULSE_RUNTIME}/native"
PULSE_STAGE_DIR="${STARTER_PULSE_STAGE_DIR:-/run/starter-pulse}"
ENSURE_PULSE="${ROOT}/scripts/ensure-pulse-access.sh"
if [[ ! -x "${ENSURE_PULSE}" ]]; then
    ENSURE_PULSE=/usr/local/libexec/starter-docker/ensure-pulse-access.sh
fi
if [[ -x "${ENSURE_PULSE}" ]]; then
    STARTER_PULSE_UID="${PULSE_UID}" STARTER_PULSE_STAGE_DIR="${PULSE_STAGE_DIR}" \
        "${ENSURE_PULSE}" || true
elif [[ -d "${PULSE_RUNTIME}" ]]; then
    chmod 755 "${PULSE_RUNTIME}" 2>/dev/null || true
fi
if [[ -d "${PULSE_RUNTIME}" ]]; then
    extra_args+=(-v "${PULSE_RUNTIME}:/run/pulse")
    extra_args+=(-e "PULSE_SERVER=unix:/run/pulse/native")
    if [[ -f "${PULSE_STAGE_DIR}/cookie" ]]; then
        extra_args+=(-v "${PULSE_STAGE_DIR}:/run/pulse-auth:ro")
        extra_args+=(-e "PULSE_COOKIE=/run/pulse-auth/cookie")
        echo "PulseAudio: ${PULSE_RUNTIME} → /run/pulse (cookie dir ${PULSE_STAGE_DIR})"
    else
        echo "PulseAudio: ${PULSE_RUNTIME} → /run/pulse (no cookie — paplay may get Access denied)"
    fi
    if [[ ! -S "${PULSE_SOCKET}" ]]; then
        echo "PulseAudio: warning — ${PULSE_SOCKET} missing now (will appear after Pulse starts)"
    fi
else
    echo "PulseAudio: ${PULSE_RUNTIME} not present (explain TTS play may fail)"
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

DB_HOST="${STARTER_DB_HOST:-127.0.0.1}"
DB_PORT="${STARTER_DB_PORT:-3306}"
echo "Running ${IMAGE_TAG} as ${NAME} (mode=${MODE}, --network=host, apparmor=${APPARMOR_PROFILE})"
echo "  External MySQL: ${DB_HOST}:${DB_PORT}"

if docker container inspect "${NAME}" >/dev/null 2>&1; then
    echo "Removing existing container ${NAME}"
    docker rm -f "${NAME}" >/dev/null
fi

env_args=(
    -e "STARTER_DB_HOST=${DB_HOST}"
    -e "STARTER_DB_PORT=${DB_PORT}"
    -e "STARTER_MYSQL_ROOT_PASSWORD=${STARTER_MYSQL_ROOT_PASSWORD:-}"
    -e "STARTER_DB_WRITER_PASS=${STARTER_DB_WRITER_PASS:-}"
    -e "STARTER_DB_READER_PASS=${STARTER_DB_READER_PASS:-}"
    -e "STARTER_RULES_FILE=${STARTER_RULES_FILE:-/usr/local/etc/starter/rules.conf}"
    -e "STARTER_SERVICE_MATCH=${STARTER_SERVICE_MATCH:-}"
)

case "${MODE}" in
    service)
        exec docker run \
            --name "${NAME}" \
            --network=host \
            "${env_args[@]}" \
            "${extra_args[@]}" \
            "${IMAGE_TAG}" \
            /usr/local/libexec/starter/container-main.sh
        ;;
    detach)
        cid="$(docker run -d \
            --name "${NAME}" \
            --network=host \
            --restart unless-stopped \
            "${env_args[@]}" \
            "${extra_args[@]}" \
            "${IMAGE_TAG}" \
            /usr/local/libexec/starter/container-main.sh)"
        echo "Started ${NAME} (${cid})"
        ;;
    interactive)
        tty_args=()
        if [[ -t 0 && -t 1 ]]; then
            tty_args+=(-it)
        else
            tty_args+=(-i)
        fi
        exec docker run --rm "${tty_args[@]}" \
            --name "${NAME}" \
            --network=host \
            "${env_args[@]}" \
            "${extra_args[@]}" \
            "${IMAGE_TAG}" \
            "$@"
        ;;
esac
