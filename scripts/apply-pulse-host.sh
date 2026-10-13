#!/usr/bin/env bash
# Install Pulse/PipeWire user drop-ins + system path unit so
# /run/user/<uid>/pulse stays mode 755 and the staged cookie stays fresh
# for the starter container (explain TTS / paplay).
#
# Also sets exit-idle-time = -1 for the desktop Pulse user so the daemon
# does not socket-activate / exit every ~20s (breaks container TTS).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PULSE_UID="${STARTER_PULSE_UID:-1000}"
LIBEXEC="${STARTER_DOCKER_LIBEXEC:-/usr/local/libexec/starter-docker}"
ENSURE_SRC="${ROOT}/scripts/ensure-pulse-access.sh"
ENSURE_DST="${LIBEXEC}/ensure-pulse-access.sh"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "error: run as root (sudo $0)" >&2
    exit 1
fi

[[ -f "${ENSURE_SRC}" ]] || {
    echo "error: missing ${ENSURE_SRC}" >&2
    exit 1
}

install -d -m 755 "${LIBEXEC}"
install -m 755 "${ENSURE_SRC}" "${ENSURE_DST}"
echo "Installed ${ENSURE_DST}"

install_user_dropin() {
    local src="$1" dst_dir="$2" dst="$3"
    if [[ ! -f "${src}" ]]; then
        echo "warning: missing ${src}" >&2
        return 0
    fi
    install -d -m 755 "${dst_dir}"
    install -m 644 "${src}" "${dst}"
    echo "Installed ${dst}"
}

install_user_dropin \
    "${ROOT}/systemd/user/pulseaudio.service.d/90-starter-pulse-access.conf" \
    /etc/systemd/user/pulseaudio.service.d \
    /etc/systemd/user/pulseaudio.service.d/90-starter-pulse-access.conf

install_user_dropin \
    "${ROOT}/systemd/user/pipewire-pulse.service.d/90-starter-pulse-access.conf" \
    /etc/systemd/user/pipewire-pulse.service.d \
    /etc/systemd/user/pipewire-pulse.service.d/90-starter-pulse-access.conf

# System path watcher (re-applies chmod/cookie when Pulse recreates sockets).
PATH_UNIT_SRC="${ROOT}/systemd/starter-pulse-access.path"
SVC_UNIT_SRC="${ROOT}/systemd/starter-pulse-access.service"
PATH_UNIT_DST=/etc/systemd/system/starter-pulse-access.path
SVC_UNIT_DST=/etc/systemd/system/starter-pulse-access.service

# Rewrite PathExists/PathChanged for the configured desktop uid.
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
sed -e "s|/run/user/1000/pulse|/run/user/${PULSE_UID}/pulse|g" \
    -e "s|/run/user/1000/pulse/native|/run/user/${PULSE_UID}/pulse/native|g" \
    "${PATH_UNIT_SRC}" >"${tmpdir}/starter-pulse-access.path"
install -m 644 "${tmpdir}/starter-pulse-access.path" "${PATH_UNIT_DST}"
install -m 644 "${SVC_UNIT_SRC}" "${SVC_UNIT_DST}"
echo "Installed ${PATH_UNIT_DST} + ${SVC_UNIT_DST}"

# Keep Pulse up on headless hosts (default exit-idle-time=20 causes stop/start loops).
ensure_exit_idle_never() {
    local home conf marker begin end
    home="$(getent passwd "${PULSE_UID}" | cut -d: -f6 || true)"
    [[ -n "${home}" ]] || return 0
    conf="${home}/.config/pulse/daemon.conf"
    marker="starter-docker exit-idle-time"
    begin="# BEGIN ${marker}"
    end="# END ${marker}"
    install -d -m 755 -o "${PULSE_UID}" -g "$(id -g "${PULSE_UID}" 2>/dev/null || echo "${PULSE_UID}")" \
        "${home}/.config" "${home}/.config/pulse"
    if [[ -f "${conf}" ]] && grep -qF "${begin}" "${conf}"; then
        # Replace managed block in place.
        awk -v b="${begin}" -v e="${end}" '
            $0 == b {print; print "exit-idle-time = -1"; skip=1; next}
            $0 == e {skip=0; print; next}
            skip {next}
            {print}
        ' "${conf}" >"${tmpdir}/daemon.conf"
        install -m 644 -o "${PULSE_UID}" -g "$(id -g "${PULSE_UID}" 2>/dev/null || echo "${PULSE_UID}")" \
            "${tmpdir}/daemon.conf" "${conf}"
    elif [[ -f "${conf}" ]] && grep -qE '^[[:space:]]*exit-idle-time[[:space:]]*=' "${conf}"; then
        sed -E 's/^[[:space:]]*exit-idle-time[[:space:]]*=.*/exit-idle-time = -1/' \
            "${conf}" >"${tmpdir}/daemon.conf"
        install -m 644 -o "${PULSE_UID}" -g "$(id -g "${PULSE_UID}" 2>/dev/null || echo "${PULSE_UID}")" \
            "${tmpdir}/daemon.conf" "${conf}"
    else
        {
            [[ -f "${conf}" ]] && cat "${conf}"
            echo ""
            echo "${begin}"
            echo "exit-idle-time = -1"
            echo "${end}"
        } >"${tmpdir}/daemon.conf"
        install -m 644 -o "${PULSE_UID}" -g "$(id -g "${PULSE_UID}" 2>/dev/null || echo "${PULSE_UID}")" \
            "${tmpdir}/daemon.conf" "${conf}"
    fi
    echo "Installed exit-idle-time = -1 in ${conf}"
}

ensure_exit_idle_never

systemctl daemon-reload
systemctl enable --now starter-pulse-access.path
systemctl start starter-pulse-access.service || true

# Apply for the desktop user session (linger helps headless boots).
PULSE_USER="$(getent passwd "${PULSE_UID}" | cut -d: -f1 || true)"
if [[ -n "${PULSE_USER}" ]]; then
    loginctl enable-linger "${PULSE_USER}" 2>/dev/null || true
    if systemctl --user -M "${PULSE_USER}@" daemon-reload 2>/dev/null; then
        systemctl --user -M "${PULSE_USER}@" try-restart pulseaudio.service 2>/dev/null || true
        systemctl --user -M "${PULSE_USER}@" try-restart pipewire-pulse.service 2>/dev/null || true
    else
        sudo -u "${PULSE_USER}" XDG_RUNTIME_DIR="/run/user/${PULSE_UID}" \
            systemctl --user daemon-reload 2>/dev/null || true
        sudo -u "${PULSE_USER}" XDG_RUNTIME_DIR="/run/user/${PULSE_UID}" \
            systemctl --user try-restart pulseaudio.service 2>/dev/null || true
        sudo -u "${PULSE_USER}" XDG_RUNTIME_DIR="/run/user/${PULSE_UID}" \
            systemctl --user try-restart pipewire-pulse.service 2>/dev/null || true
    fi
fi

STARTER_PULSE_UID="${PULSE_UID}" "${ENSURE_DST}"
echo
echo "Pulse host access installed (drop-ins + path unit + ensure script + exit-idle=-1)."
echo "  Ensure starter mounts pulse dir + /run/starter-pulse (updated run.sh)."
echo "  Then: systemctl restart starter-docker.service"
