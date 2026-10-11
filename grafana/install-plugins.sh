#!/usr/bin/env bash
# Install Grafana plugins required by the STCA Parameters dashboard.
#
# Prefer GF_INSTALL_PLUGINS on container create (see run-grafana.sh).
# This script is a fallback for an already-running container / data volume.
set -euo pipefail

PLUGINS=(
  yesoreyeram-infinity-datasource
  volkovlabs-form-panel
  frser-sqlite-datasource
)

CONTAINER="${GRAFANA_CONTAINER_NAME:-grafana}"

if ! docker container inspect "${CONTAINER}" >/dev/null 2>&1; then
  echo "container ${CONTAINER} not found; use ./run-grafana.sh instead" >&2
  exit 1
fi

for p in "${PLUGINS[@]}"; do
  echo "Installing ${p} into ${CONTAINER}..."
  docker exec -u grafana "${CONTAINER}" \
    grafana cli --pluginsDir /var/lib/grafana/plugins plugins install "${p}" \
    || docker exec "${CONTAINER}" \
         grafana cli --pluginsDir /var/lib/grafana/plugins plugins install "${p}"
done

echo "Restarting ${CONTAINER}..."
docker restart "${CONTAINER}" >/dev/null
echo "Done."
