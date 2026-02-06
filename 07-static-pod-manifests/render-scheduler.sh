#!/bin/bash
# Render kube-scheduler static pod manifest

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/cluster-vars.sh"
source "${SCRIPT_DIR}/../04-release-image/component-images.sh"

OUTPUT_DIR="${MANIFESTS_DIR}/kube-scheduler-bootstrap"
mkdir -p "${OUTPUT_DIR}"

echo "Rendering kube-scheduler manifests..."
echo "Operator image: ${CLUSTER_KUBE_SCHEDULER_OPERATOR_IMAGE}"

# Create minimal config files
CONFIG_DIR=$(mktemp -d)

# Infrastructure config
cat > "${CONFIG_DIR}/infrastructure.yaml" <<EOF
apiVersion: config.openshift.io/v1
kind: Infrastructure
metadata:
  name: cluster
spec:
  platformSpec:
    type: None
status:
  platform: None
EOF

# Run the kube-scheduler operator render command
podman run --rm \
    --authfile "${PULL_SECRET_FILE}" \
    -v "${PKI_DIR}:/assets/tls:ro,z" \
    -v "${OUTPUT_DIR}:/assets/output:z" \
    -v "${CONFIG_DIR}:/assets/config:ro,z" \
    "${CLUSTER_KUBE_SCHEDULER_OPERATOR_IMAGE}" \
    /usr/bin/cluster-kube-scheduler-operator render \
    --asset-input-dir=/assets/tls \
    --asset-output-dir=/assets/output \
    --manifest-image="${KUBE_SCHEDULER_IMAGE}" \
    2>&1 | sed 's/^/  /'

rm -rf "${CONFIG_DIR}"

echo ""
echo "kube-scheduler manifests rendered to: ${OUTPUT_DIR}"
find "${OUTPUT_DIR}" -name "*.yaml" -o -name "*.json" 2>/dev/null | head -10
