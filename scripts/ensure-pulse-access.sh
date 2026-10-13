#!/usr/bin/env bash
# Keep host PulseAudio reachable from the starter container (uid starter=999).
#
# Pulse creates /run/user/<uid>/pulse as mode 700; container processes cannot
# traverse it even when `native` is world-writable. Cookie updates via `cp -f`
# also break Docker file bind-mounts (new inode → stale cookie → Access denied).
#
# This script:
#   1. chmod 755 the Pulse runtime dir (any caller)
#   2. refreshes a staged cookie *in place* under /run/starter-pulse/ (root only)
#
# Called from: starter-pulse-access.path (root), starter-docker ExecStartPre,
#              apply-pulse-host.sh, and run.sh before docker run.
# User pulse drop-ins only chmod — they must not invoke this for cookies.
set -euo pipefail

PULSE_UID="${STARTER_PULSE_UID:-1000}"
PULSE_RUNTIME="${STARTER_PULSE_RUNTIME:-/run/user/${PULSE_UID}/pulse}"
PULSE_HOME="$(getent passwd "${PULSE_UID}" 2>/dev/null | cut -d: -f6 || true)"
PULSE_COOKIE_HOST="${STARTER_PULSE_COOKIE:-${PULSE_HOME:+${PULSE_HOME}/.config/pulse/cookie}}"
STAGE_DIR="${STARTER_PULSE_STAGE_DIR:-/run/starter-pulse}"
STAGE_COOKIE="${STAGE_DIR}/cookie"

# Legacy single-file stage (older run.sh); keep in sync in-place when present.
LEGACY_COOKIE="${STARTER_PULSE_COOKIE_STAGE:-/run/starter-pulse-cookie}"

overwrite_in_place() {
    local src="$1" dst="$2"
    if [[ -e "${dst}" && ! -d "${dst}" ]]; then
        # Preserve inode so Docker file bind-mounts keep seeing updates.
        cat "${src}" >"${dst}"
        chmod 644 "${dst}" || true
    else
        cp -f "${src}" "${dst}"
        chmod 644 "${dst}" || true
    fi
}

if [[ -d "${PULSE_RUNTIME}" ]]; then
    chmod 755 "${PULSE_RUNTIME}" || true
fi

# Cookie stage dir is root-owned; only root can refresh without "Permesso negato".
if [[ "$(id -u)" -eq 0 ]] && [[ -n "${PULSE_COOKIE_HOST}" && -f "${PULSE_COOKIE_HOST}" ]]; then
    mkdir -p "${STAGE_DIR}"
    chmod 755 "${STAGE_DIR}" || true
    overwrite_in_place "${PULSE_COOKIE_HOST}" "${STAGE_COOKIE}"
    if [[ -e "${LEGACY_COOKIE}" || -L "${LEGACY_COOKIE}" ]]; then
        overwrite_in_place "${PULSE_COOKIE_HOST}" "${LEGACY_COOKIE}"
    fi
fi

exit 0
