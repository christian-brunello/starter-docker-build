#!/usr/bin/env bash
# Copy a host /usr/local/etc/starter tree into overlay/etc/starter for the next image build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-/usr/local/etc/starter}"
DEST="${ROOT}/overlay/etc/starter"

if [[ ! -d "${SRC}" ]]; then
    echo "error: source directory not found: ${SRC}" >&2
    exit 1
fi

mkdir -p "${DEST}"

rsync -a --delete \
    --exclude='.gitkeep' \
    --exclude='README.md' \
    --exclude='*.back' \
    --exclude='*~' \
    --exclude='*.from-*' \
    "${SRC}/" "${DEST}/"

# Keep the placeholder so an emptied tree still exists for COPY
touch "${DEST}/.gitkeep"

echo "Synced ${SRC} -> ${DEST}"
echo "Files:"
find "${DEST}" -type f ! -name '.gitkeep' | sed "s|^${ROOT}/||" | sort
echo
echo "Rebuild the image to refresh defaults (./build.sh)."
echo "Existing files on the etc volume are never overwritten at runtime."
