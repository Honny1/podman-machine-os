#!/bin/bash
set -euo pipefail

MACHINE_NAME="${1:-dev}"
IMAGE="quay.io/honny1/machine-os-dev:6.0"

CPUS=$(sysctl -n hw.ncpu)
MEMORY=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 2 ))
DISK="${DISK:-100}"

export CONTAINERS_MACHINE_PROVIDER=applehv

echo "==> Initializing podman dev machine '${MACHINE_NAME}' (applehv, cpus=${CPUS}, mem=${MEMORY}MB, disk=${DISK}GB)"
echo "    Image: ${IMAGE}"

podman machine init "${MACHINE_NAME}" \
    --image "${IMAGE}" \
    --cpus "${CPUS}" \
    --memory "${MEMORY}" \
    --disk-size "${DISK}" \
    -u=false \
    --now

echo "==> Waiting for machine to be ready..."
podman machine ssh "${MACHINE_NAME}" "echo ready"

echo "==> Machine '${MACHINE_NAME}' is running."
echo ""
echo "  SSH into it:   podman machine ssh ${MACHINE_NAME}"
echo "  Stop it:       podman machine stop ${MACHINE_NAME}"
echo "  Remove it:     podman machine rm -f ${MACHINE_NAME}"
