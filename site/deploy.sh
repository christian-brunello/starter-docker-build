#!/usr/bin/env bash
# Import www/ then recreate the public site container.
#
#   ./site/deploy.sh
#   STARTER_WWW_DIR=/path/to/www ./site/deploy.sh
set -euo pipefail

SITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Importing www"
"${SITE_DIR}/apply-www.sh"

echo "==> Recreating starter-www"
"${SITE_DIR}/run-site.sh"

echo
echo "Done."
