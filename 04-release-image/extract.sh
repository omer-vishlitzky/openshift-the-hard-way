#!/bin/bash
# Extract component images from the release image

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/cluster-vars.sh"

OUTPUT_FILE="${SCRIPT_DIR}/component-images.sh"

echo "Extracting component images from: ${OCP_RELEASE_IMAGE}"
echo ""

# Check authentication
if [[ ! -f "${PULL_SECRET_FILE}" ]]; then
    echo "ERROR: Pull secret not found: ${PULL_SECRET_FILE}"
    exit 1
fi

# Get release info as JSON
echo "Fetching release info..."
RELEASE_JSON=$(oc adm release info "${OCP_RELEASE_IMAGE}" \
    --registry-config="${PULL_SECRET_FILE}" \
    -o json)

# Extract digest
RELEASE_DIGEST=$(echo "${RELEASE_JSON}" | jq -r '.digest')
echo "Release digest: ${RELEASE_DIGEST}"

# Function to get image for a component
get_image() {
    local component=$1
    echo "${RELEASE_JSON}" | jq -r ".references.spec.tags[] | select(.name == \"${component}\") | .from.name"
}

# Extract key component images
cat > "${OUTPUT_FILE}" <<EOF
#!/bin/bash
# Component images for OpenShift ${OCP_VERSION}
# Generated from: ${OCP_RELEASE_IMAGE}
# Generated at: $(date -Iseconds)

# Release Image
export RELEASE_IMAGE="${OCP_RELEASE_IMAGE}"
export RELEASE_DIGEST="${RELEASE_DIGEST}"

# Control Plane Components
export ETCD_IMAGE="$(get_image etcd)"
export HYPERKUBE_IMAGE="$(get_image hyperkube)"
# In OpenShift, apiserver/kcm/scheduler all come from the hyperkube image.
# There are no separate kube-apiserver, kube-controller-manager, or kube-scheduler
# image tags in the release — hyperkube contains all three binaries.
export KUBE_APISERVER_IMAGE="${HYPERKUBE_IMAGE}"
export KUBE_CONTROLLER_MANAGER_IMAGE="${HYPERKUBE_IMAGE}"
export KUBE_SCHEDULER_IMAGE="${HYPERKUBE_IMAGE}"

# Operator Images (manage components day 2, referenced in cluster manifests)
export CLUSTER_ETCD_OPERATOR_IMAGE="$(get_image cluster-etcd-operator)"
export CLUSTER_KUBE_APISERVER_OPERATOR_IMAGE="$(get_image cluster-kube-apiserver-operator)"
export CLUSTER_KUBE_CONTROLLER_MANAGER_OPERATOR_IMAGE="$(get_image cluster-kube-controller-manager-operator)"
export CLUSTER_KUBE_SCHEDULER_OPERATOR_IMAGE="$(get_image cluster-kube-scheduler-operator)"
export CLUSTER_CONFIG_OPERATOR_IMAGE="$(get_image cluster-config-operator)"
export CLUSTER_NETWORK_OPERATOR_IMAGE="$(get_image cluster-network-operator)"
export CLUSTER_INGRESS_OPERATOR_IMAGE="$(get_image cluster-ingress-operator)"
export MACHINE_CONFIG_OPERATOR_IMAGE="$(get_image machine-config-operator)"
export CLUSTER_VERSION_OPERATOR_IMAGE="$(get_image cluster-version-operator)"
export CLUSTER_BOOTSTRAP_IMAGE="$(get_image cluster-bootstrap)"
export AUTHENTICATION_OPERATOR_IMAGE="$(get_image cluster-authentication-operator)"

# Infrastructure Components
export MACHINE_CONFIG_SERVER_IMAGE="$(get_image machine-config-server)"
export HAPROXY_ROUTER_IMAGE="$(get_image haproxy-router)"
export COREDNS_IMAGE="$(get_image coredns)"
export CLUSTER_DNS_OPERATOR_IMAGE="$(get_image cluster-dns-operator)"
export KEEPALIVED_IPFAILOVER_IMAGE="$(get_image keepalived-ipfailover)"

# Additional Components
export CLI_IMAGE="$(get_image cli)"
export POD_IMAGE="$(get_image pod)"
export OAUTH_PROXY_IMAGE="$(get_image oauth-proxy)"
export OAUTH_SERVER_IMAGE="$(get_image oauth-server)"
export OAUTH_APISERVER_IMAGE="$(get_image oauth-apiserver)"

# Kubernetes Components
export KUBE_PROXY_IMAGE="$(get_image kube-proxy)"
export COREDNS_IMAGE="$(get_image coredns)"

# Container Runtime (for reference)
export MACHINE_OS_CONTENT_IMAGE="$(get_image machine-os-content)"
EOF

chmod +x "${OUTPUT_FILE}"

echo ""
echo "Component images extracted to: ${OUTPUT_FILE}"
echo ""
echo "Key images:"
echo "  etcd:                $(get_image etcd | cut -d@ -f1)@sha256:..."
echo "  kube-apiserver:      $(get_image kube-apiserver | cut -d@ -f1)@sha256:..."
echo "  machine-config-op:   $(get_image machine-config-operator | cut -d@ -f1)@sha256:..."
echo "  cluster-bootstrap:   $(get_image cluster-bootstrap | cut -d@ -f1)@sha256:..."
echo ""
echo "Source this file to use: source ${OUTPUT_FILE}"
