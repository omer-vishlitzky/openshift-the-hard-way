#!/bin/bash
# Render kube-controller-manager static pod manifest

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/cluster-vars.sh"
source "${SCRIPT_DIR}/../04-release-image/component-images.sh"

OUTPUT_DIR="${MANIFESTS_DIR}/kube-controller-manager-bootstrap"
mkdir -p "${OUTPUT_DIR}"

echo "Rendering kube-controller-manager manifests..."
echo "Operator image: ${CLUSTER_KUBE_CONTROLLER_MANAGER_OPERATOR_IMAGE}"

# Create minimal config files needed by the operator
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
  platformStatus:
    type: None
EOF

# Network config
cat > "${CONFIG_DIR}/network.yaml" <<EOF
apiVersion: config.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  clusterNetwork:
  - cidr: ${CLUSTER_NETWORK_CIDR}
    hostPrefix: ${CLUSTER_NETWORK_HOST_PREFIX}
  serviceNetwork:
  - ${SERVICE_NETWORK_CIDR}
  networkType: OVNKubernetes
EOF

# Run the kube-controller-manager operator render command
podman run --rm \
    --authfile "${PULL_SECRET_FILE}" \
    -v "${PKI_DIR}:/assets/tls:ro,z" \
    -v "${OUTPUT_DIR}:/assets/output:z" \
    -v "${CONFIG_DIR}:/assets/config:ro,z" \
    -v "${ASSETS_DIR}/kubeconfigs:/assets/kubeconfigs:ro,z" \
    "${CLUSTER_KUBE_CONTROLLER_MANAGER_OPERATOR_IMAGE}" \
    /usr/bin/cluster-kube-controller-manager-operator render \
    --asset-input-dir=/assets/tls \
    --asset-output-dir=/assets/output \
    --manifest-image="${KUBE_CONTROLLER_MANAGER_IMAGE}" \
    --cluster-config-file=/assets/config/network.yaml \
    2>&1 | sed 's/^/  /'

rm -rf "${CONFIG_DIR}"

echo ""
echo "kube-controller-manager manifests rendered to: ${OUTPUT_DIR}"
find "${OUTPUT_DIR}" -name "*.yaml" -o -name "*.json" 2>/dev/null | head -10
