#!/bin/bash
# Render etcd static pod manifest using cluster-etcd-operator

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/cluster-vars.sh"
source "${SCRIPT_DIR}/../04-release-image/component-images.sh"

OUTPUT_DIR="${MANIFESTS_DIR}/etcd-bootstrap"
mkdir -p "${OUTPUT_DIR}"

echo "Rendering etcd manifests..."
echo "Operator image: ${CLUSTER_ETCD_OPERATOR_IMAGE}"

# Build etcd endpoints
ETCD_ENDPOINTS="https://etcd-0.${CLUSTER_DOMAIN}:2379,https://etcd-1.${CLUSTER_DOMAIN}:2379,https://etcd-2.${CLUSTER_DOMAIN}:2379"

# Run the etcd operator render command
podman run --rm \
    --authfile "${PULL_SECRET_FILE}" \
    -v "${PKI_DIR}:/assets/tls:ro,z" \
    -v "${OUTPUT_DIR}:/assets/output:z" \
    "${CLUSTER_ETCD_OPERATOR_IMAGE}" \
    /usr/bin/cluster-etcd-operator render \
    --asset-input-dir=/assets/tls \
    --asset-output-dir=/assets/output \
    --etcd-image="${ETCD_IMAGE}" \
    --cluster-config-file="" \
    --infra-config-file="" \
    --network-config-file="" \
    --bootstrap-ip="${BOOTSTRAP_IP}" \
    2>&1 | sed 's/^/  /'

echo ""
echo "etcd manifests rendered to: ${OUTPUT_DIR}"
ls -la "${OUTPUT_DIR}" 2>/dev/null || echo "  (checking subdirectories...)"
find "${OUTPUT_DIR}" -name "*.yaml" -o -name "*.json" 2>/dev/null | head -10
