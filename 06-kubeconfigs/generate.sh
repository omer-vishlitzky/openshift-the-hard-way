#!/bin/bash
# Generate kubeconfigs for OpenShift cluster

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/cluster-vars.sh"

KUBECONFIG_DIR="${ASSETS_DIR}/kubeconfigs"
mkdir -p "${KUBECONFIG_DIR}"

echo "=== Generating Kubeconfigs ==="
echo "Output directory: ${KUBECONFIG_DIR}"
echo ""

generate_kubeconfig() {
    local name=$1
    local user=$2
    local cert_name=$3
    local server=$4
    local cluster_name=${5:-${CLUSTER_NAME}}

    echo "Generating kubeconfig: ${name}"

    # Base64 encode certificates
    local ca_data=$(base64 -w0 "${PKI_DIR}/kubernetes-ca.crt")
    local cert_data=$(base64 -w0 "${PKI_DIR}/${cert_name}.crt")
    local key_data=$(base64 -w0 "${PKI_DIR}/${cert_name}.key")

    cat > "${KUBECONFIG_DIR}/${name}.kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${ca_data}
    server: ${server}
  name: ${cluster_name}
users:
- name: ${user}
  user:
    client-certificate-data: ${cert_data}
    client-key-data: ${key_data}
contexts:
- context:
    cluster: ${cluster_name}
    user: ${user}
  name: ${user}
current-context: ${user}
EOF
}

# Admin kubeconfig (external API URL)
generate_kubeconfig "admin" "admin" "admin" "${API_URL}"

# Controller Manager kubeconfig (internal API URL)
generate_kubeconfig "kube-controller-manager" "system:kube-controller-manager" "kube-controller-manager" "${API_INT_URL}"

# Scheduler kubeconfig (internal API URL)
generate_kubeconfig "kube-scheduler" "system:kube-scheduler" "kube-scheduler" "${API_INT_URL}"

# Kubelet bootstrap kubeconfig (internal API URL)
generate_kubeconfig "kubelet-bootstrap" "system:bootstrapper" "kubelet-bootstrap" "${API_INT_URL}"

# Localhost kubeconfig (for operators on control plane nodes)
generate_kubeconfig "localhost" "admin" "admin" "https://localhost:6443" "localhost"

# Localhost recovery kubeconfig (same as localhost, for recovery operations)
generate_kubeconfig "localhost-recovery" "admin" "admin" "https://localhost:6443" "localhost-recovery"

# Internal LB kubeconfig (using api-int)
generate_kubeconfig "lb-int" "admin" "admin" "${API_INT_URL}" "lb-int"

# External LB kubeconfig (using api)
generate_kubeconfig "lb-ext" "admin" "admin" "${API_URL}" "lb-ext"

echo ""
echo "=== Kubeconfig Generation Complete ==="
echo ""
echo "Files generated:"
ls -la "${KUBECONFIG_DIR}"/*.kubeconfig

echo ""
echo "To use admin kubeconfig:"
echo "  export KUBECONFIG=${KUBECONFIG_DIR}/admin.kubeconfig"
