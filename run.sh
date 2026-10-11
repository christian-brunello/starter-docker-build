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
# Mount the socket at /run/pulse-native (not under /run/user/<uid>): that dir is
# mode 700, so container user "starter" cannot traverse it. Auth needs the cookie.
PULSE_UID="${STARTER_PULSE_UID:-1000}"
PULSE_RUNTIME="${STARTER_PULSE_RUNTIME:-/run/user/${PULSE_UID}/pulse}"
PULSE_SOCKET="${PULSE_RUNTIME}/native"
PULSE_HOME="$(getent passwd "${PULSE_UID}" 2>/dev/null | cut -d: -f6 || true)"
PULSE_COOKIE_HOST="${STARTER_PULSE_COOKIE:-${PULSE_HOME:+${PULSE_HOME}/.config/pulse/cookie}}"
if [[ -S "${PULSE_SOCKET}" ]]; then
    extra_args+=(-v "${PULSE_SOCKET}:/run/pulse-native")
    extra_args+=(-e "PULSE_SERVER=unix:/run/pulse-native")
    if [[ -n "${PULSE_COOKIE_HOST}" && -f "${PULSE_COOKIE_HOST}" ]]; then
        # Stage a world-readable copy: container uid starter ≠ desktop uid
        PULSE_COOKIE_STAGE="${STARTER_PULSE_COOKIE_STAGE:-/run/starter-pulse-cookie}"
        cp -f "${PULSE_COOKIE_HOST}" "${PULSE_COOKIE_STAGE}"
        chmod 644 "${PULSE_COOKIE_STAGE}"
        extra_args+=(-v "${PULSE_COOKIE_STAGE}:/run/pulse-cookie:ro")
        extra_args+=(-e "PULSE_COOKIE=/run/pulse-cookie")
        echo "PulseAudio: ${PULSE_SOCKET} (cookie ${PULSE_COOKIE_HOST})"
    else
        echo "PulseAudio: ${PULSE_SOCKET} (no cookie — paplay may get Access denied)"
    fi
else
    echo "PulseAudio: ${PULSE_SOCKET} not present (explain TTS play may fail)"
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
