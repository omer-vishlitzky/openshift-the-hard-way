#!/bin/bash
# Render all static pod manifests using operator containers

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/cluster-vars.sh"
source "${SCRIPT_DIR}/../04-release-image/component-images.sh" 2>/dev/null || {
    echo "ERROR: Component images not extracted. Run 04-release-image/extract.sh first."
    exit 1
}

mkdir -p "${MANIFESTS_DIR}"

echo "=== Rendering Static Pod Manifests ==="
echo "Output directory: ${MANIFESTS_DIR}"
echo ""

# Verify we have component images
if [[ -z "${CLUSTER_ETCD_OPERATOR_IMAGE}" ]]; then
    echo "ERROR: Component images not loaded. Source 04-release-image/component-images.sh"
    exit 1
fi

# Render each component
echo "--- Rendering etcd ---"
"${SCRIPT_DIR}/render-etcd.sh"
echo ""

echo "--- Rendering kube-apiserver ---"
"${SCRIPT_DIR}/render-kube-apiserver.sh"
echo ""

echo "--- Rendering kube-controller-manager ---"
"${SCRIPT_DIR}/render-kcm.sh"
echo ""

echo "--- Rendering kube-scheduler ---"
"${SCRIPT_DIR}/render-scheduler.sh"
echo ""

echo "=== Manifest Rendering Complete ==="
echo ""
echo "Static pod manifests generated in: ${MANIFESTS_DIR}"
find "${MANIFESTS_DIR}" -name "*.yaml" | head -20
