#!/usr/bin/env bash
# Recreate the Grafana container (optionally with sitedir provisioning).
#
#   ./grafana/deploy.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRAFANA_DIR="${ROOT}/grafana"

echo "==> Recreating Grafana"
"${GRAFANA_DIR}/run-grafana.sh"

echo
echo "Done."
echo "  UI:  http://$(hostname -I 2>/dev/null | awk '{print $1}'):3000"
echo "  Doc: ${ROOT}/doc/grafana-starter.md"
