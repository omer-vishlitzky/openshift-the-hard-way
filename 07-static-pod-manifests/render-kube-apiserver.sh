#!/bin/bash
# Render kube-apiserver static pod manifest using cluster-kube-apiserver-operator

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/cluster-vars.sh"
source "${SCRIPT_DIR}/../04-release-image/component-images.sh"

OUTPUT_DIR="${MANIFESTS_DIR}/kube-apiserver-bootstrap"
mkdir -p "${OUTPUT_DIR}"

echo "Rendering kube-apiserver manifests..."
echo "Operator image: ${CLUSTER_KUBE_APISERVER_OPERATOR_IMAGE}"

# Build etcd servers URL
ETCD_SERVERS="https://localhost:2379"

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
  apiServerURL: ${API_URL}
  apiServerInternalURL: ${API_INT_URL}
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

# Run the kube-apiserver operator render command
podman run --rm \
    --authfile "${PULL_SECRET_FILE}" \
    -v "${PKI_DIR}:/assets/tls:ro,z" \
    -v "${OUTPUT_DIR}:/assets/output:z" \
    -v "${CONFIG_DIR}:/assets/config:ro,z" \
    "${CLUSTER_KUBE_APISERVER_OPERATOR_IMAGE}" \
    /usr/bin/cluster-kube-apiserver-operator render \
    --asset-input-dir=/assets/tls \
    --asset-output-dir=/assets/output \
    --manifest-etcd-serving-ca=/assets/tls/etcd-ca.crt \
    --manifest-etcd-server-urls="${ETCD_SERVERS}" \
    --manifest-image="${KUBE_APISERVER_IMAGE}" \
    --manifest-operator-image="${CLUSTER_KUBE_APISERVER_OPERATOR_IMAGE}" \
    2>&1 | sed 's/^/  /'

rm -rf "${CONFIG_DIR}"

echo ""
echo "kube-apiserver manifests rendered to: ${OUTPUT_DIR}"
find "${OUTPUT_DIR}" -name "*.yaml" -o -name "*.json" 2>/dev/null | head -10
