#!/usr/bin/env bash
# Build the STARTER Docker image using pinned commits from versions.env.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT}"

VERSIONS_FILE="${ROOT}/versions.env"
if [[ ! -f "${VERSIONS_FILE}" ]]; then
    echo "error: ${VERSIONS_FILE} not found" >&2
    exit 1
fi

# shellcheck disable=SC1090
set -a
# shellcheck source=versions.env
source "${VERSIONS_FILE}"
set +a

IMAGE_TAG="${IMAGE_TAG:-starter:local}"

required=(
    STARTER_CORE_REPO STARTER_CORE_COMMIT
    STARTER_DEBUGGER_REPO STARTER_DEBUGGER_COMMIT
    STARTER_CONFIGURABLE_SERVICE_REPO STARTER_CONFIGURABLE_SERVICE_COMMIT
    STARTER_CONFIGURABLE_ADAPTER_REPO STARTER_CONFIGURABLE_ADAPTER_COMMIT
    STARTER_ARISTON_PLUGIN_REPO STARTER_ARISTON_PLUGIN_COMMIT
    STARTER_PARAMETERS_PLUGIN_REPO STARTER_PARAMETERS_PLUGIN_COMMIT
)
for var in "${required[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "error: ${var} is empty in versions.env" >&2
        exit 1
    fi
done

echo "Building ${IMAGE_TAG}"
echo "  starter-core @ ${STARTER_CORE_COMMIT}"
echo "  starter-debugger @ ${STARTER_DEBUGGER_COMMIT}"
echo "  starter-configurable-service @ ${STARTER_CONFIGURABLE_SERVICE_COMMIT}"
echo "  starter-configurable-adapter @ ${STARTER_CONFIGURABLE_ADAPTER_COMMIT}"
echo "  ariston plugin @ ${STARTER_ARISTON_PLUGIN_COMMIT}"
echo "  parameters plugin @ ${STARTER_PARAMETERS_PLUGIN_COMMIT}"

DOCKER_BUILDKIT=1 docker build \
    -t "${IMAGE_TAG}" \
    --build-arg "STARTER_CORE_REPO=${STARTER_CORE_REPO}" \
    --build-arg "STARTER_CORE_COMMIT=${STARTER_CORE_COMMIT}" \
    --build-arg "STARTER_DEBUGGER_REPO=${STARTER_DEBUGGER_REPO}" \
    --build-arg "STARTER_DEBUGGER_COMMIT=${STARTER_DEBUGGER_COMMIT}" \
    --build-arg "STARTER_CONFIGURABLE_SERVICE_REPO=${STARTER_CONFIGURABLE_SERVICE_REPO}" \
    --build-arg "STARTER_CONFIGURABLE_SERVICE_COMMIT=${STARTER_CONFIGURABLE_SERVICE_COMMIT}" \
    --build-arg "STARTER_CONFIGURABLE_ADAPTER_REPO=${STARTER_CONFIGURABLE_ADAPTER_REPO}" \
    --build-arg "STARTER_CONFIGURABLE_ADAPTER_COMMIT=${STARTER_CONFIGURABLE_ADAPTER_COMMIT}" \
    --build-arg "STARTER_ARISTON_PLUGIN_REPO=${STARTER_ARISTON_PLUGIN_REPO}" \
    --build-arg "STARTER_ARISTON_PLUGIN_COMMIT=${STARTER_ARISTON_PLUGIN_COMMIT}" \
    --build-arg "STARTER_PARAMETERS_PLUGIN_REPO=${STARTER_PARAMETERS_PLUGIN_REPO}" \
    --build-arg "STARTER_PARAMETERS_PLUGIN_COMMIT=${STARTER_PARAMETERS_PLUGIN_COMMIT}" \
    "$@" \
    .

echo "Done: ${IMAGE_TAG}"
