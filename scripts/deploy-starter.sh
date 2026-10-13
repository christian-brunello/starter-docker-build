#!/usr/bin/env bash
# Build/refresh the STARTER image and roll it out on this host (systemd).
#
#   ./scripts/deploy-starter.sh
#   ./scripts/deploy-starter.sh --skip-build   # only reinstall units + restart
#
# Always reinstalls libexec scripts (healthcheck, run.sh, pulse) via
# install-systemd.sh so host helpers stay in sync with this tree.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

SKIP_BUILD=0
SKIP_SITE=0
for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=1 ;;
        --skip-site) SKIP_SITE=1 ;;
        -h|--help)
            echo "Usage: $0 [--skip-build] [--skip-site]"
            exit 0
            ;;
        *)
            echo "error: unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

if [[ "$SKIP_SITE" -eq 0 ]]; then
    echo "==> apply-site"
    "${ROOT}/scripts/apply-site.sh"
fi

if [[ "$SKIP_BUILD" -eq 0 ]]; then
    echo "==> build image"
    "${ROOT}/build.sh"
fi

echo "==> install systemd helpers (run.sh, healthcheck, pulse, units)"
if [[ "$(id -u)" -eq 0 ]]; then
    "${ROOT}/scripts/install-systemd.sh"
else
    sudo "${ROOT}/scripts/install-systemd.sh"
fi

echo "==> restart starter-docker"
if [[ "$(id -u)" -eq 0 ]]; then
    systemctl restart starter-docker.service
else
    sudo systemctl restart starter-docker.service
fi

echo "==> wait for supervisord conf"
for _ in $(seq 1 30); do
    if docker exec starter test -f /run/starter/supervisord.conf 2>/dev/null; then
        break
    fi
    sleep 2
done

echo "==> healthcheck once"
if [[ "$(id -u)" -eq 0 ]]; then
    /usr/local/libexec/starter-docker/system-healthcheck.sh || true
else
    sudo /usr/local/libexec/starter-docker/system-healthcheck.sh || true
fi

echo
echo "Done."
echo "  Status: systemctl status starter-docker.service"
echo "  Progs:  docker exec starter supervisorctl -c /run/starter/supervisord.conf status"
