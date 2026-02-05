#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../config/cluster-vars.sh
source "${ROOT_DIR}/config/cluster-vars.sh"

OUT_DIR="${ROOT_DIR}/generated/kubeconfig"
PKI_DIR="${ROOT_DIR}/generated/pki"
mkdir -p "${OUT_DIR}"

API_SERVER="https://api.${CLUSTER_DOMAIN}:6443"

b64() {
  base64 -w0 < "$1"
}

make_kubeconfig() {
  local name=$1
  local user=$2
  local cert=$3
  local key=$4

  cat > "${OUT_DIR}/${name}.kubeconfig" <<EOC
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: $(b64 "${PKI_DIR}/ca.crt")
    server: ${API_SERVER}
  name: ${CLUSTER_NAME}
users:
- name: ${user}
  user:
    client-certificate-data: $(b64 "${cert}")
    client-key-data: $(b64 "${key}")
contexts:
- context:
    cluster: ${CLUSTER_NAME}
    user: ${user}
  name: ${user}@${CLUSTER_NAME}
current-context: ${user}@${CLUSTER_NAME}
EOC
}

make_kubeconfig "admin" "admin" "${PKI_DIR}/admin.crt" "${PKI_DIR}/admin.key"
make_kubeconfig "kube-controller-manager" "system:kube-controller-manager" "${PKI_DIR}/kube-controller-manager.crt" "${PKI_DIR}/kube-controller-manager.key"
make_kubeconfig "kube-scheduler" "system:kube-scheduler" "${PKI_DIR}/kube-scheduler.crt" "${PKI_DIR}/kube-scheduler.key"

for node in "${BOOTSTRAP}" "${MASTER0}" "${MASTER1}" "${MASTER2}" "${WORKER0}" "${WORKER1}"; do
  make_kubeconfig "kubelet-${node}" "system:node:${node}.${CLUSTER_DOMAIN}" "${PKI_DIR}/kubelet-${node}.crt" "${PKI_DIR}/kubelet-${node}.key"
done

echo "Kubeconfigs generated in ${OUT_DIR}"
