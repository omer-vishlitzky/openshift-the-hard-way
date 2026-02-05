#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../config/cluster-vars.sh
source "${ROOT_DIR}/config/cluster-vars.sh"

OUT_DIR="${ROOT_DIR}/generated/pki"
ETCD_DIR="${OUT_DIR}/etcd"
mkdir -p "${OUT_DIR}" "${ETCD_DIR}"

cert_days=3650

make_ca() {
  local name=$1
  local cn=$2
  openssl genrsa -out "${OUT_DIR}/${name}.key" 4096
  openssl req -x509 -new -nodes -key "${OUT_DIR}/${name}.key" \
    -subj "/CN=${cn}" -days "${cert_days}" -out "${OUT_DIR}/${name}.crt"
}

make_ca_dir() {
  local dir=$1
  local cn=$2
  mkdir -p "${dir}"
  openssl genrsa -out "${dir}/ca.key" 4096
  openssl req -x509 -new -nodes -key "${dir}/ca.key" \
    -subj "/CN=${cn}" -days "${cert_days}" -out "${dir}/ca.crt"
}

make_cert() {
  local name=$1
  local cn=$2
  local o=$3
  local ca_crt=$4
  local ca_key=$5
  local san=$6

  openssl genrsa -out "${OUT_DIR}/${name}.key" 2048
  openssl req -new -key "${OUT_DIR}/${name}.key" -subj "/CN=${cn}/O=${o}" -out "${OUT_DIR}/${name}.csr"

  local extfile
  extfile=$(mktemp)
  cat > "${extfile}" <<EOFEXT
[ v3_req ]
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = ${san}
EOFEXT

  openssl x509 -req -in "${OUT_DIR}/${name}.csr" -CA "${ca_crt}" -CAkey "${ca_key}" \
    -CAcreateserial -out "${OUT_DIR}/${name}.crt" -days "${cert_days}" -extensions v3_req -extfile "${extfile}"
  rm -f "${extfile}" "${OUT_DIR}/${name}.csr"
}

make_etcd_cert() {
  local name=$1
  local cn=$2
  local o=$3
  local san=$4

  openssl genrsa -out "${ETCD_DIR}/${name}.key" 2048
  openssl req -new -key "${ETCD_DIR}/${name}.key" -subj "/CN=${cn}/O=${o}" -out "${ETCD_DIR}/${name}.csr"

  local extfile
  extfile=$(mktemp)
  cat > "${extfile}" <<EOFEXT
[ v3_req ]
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = ${san}
EOFEXT

  openssl x509 -req -in "${ETCD_DIR}/${name}.csr" -CA "${ETCD_DIR}/ca.crt" -CAkey "${ETCD_DIR}/ca.key" \
    -CAcreateserial -out "${ETCD_DIR}/${name}.crt" -days "${cert_days}" -extensions v3_req -extfile "${extfile}"
  rm -f "${extfile}" "${ETCD_DIR}/${name}.csr"
}

# Cluster CA and front-proxy CA
make_ca "ca" "kubernetes"
make_ca "front-proxy-ca" "kubernetes-front-proxy"

# etcd CA
make_ca_dir "${ETCD_DIR}" "etcd-ca"

# Service account signing key
openssl genrsa -out "${OUT_DIR}/sa.key" 2048
openssl rsa -in "${OUT_DIR}/sa.key" -pubout -out "${OUT_DIR}/sa.pub"

# API server cert
APISERVER_SAN="DNS:api.${CLUSTER_DOMAIN},DNS:api-int.${CLUSTER_DOMAIN},DNS:kubernetes,DNS:kubernetes.default,DNS:kubernetes.default.svc,DNS:kubernetes.default.svc.cluster.local,IP:${API_VIP},IP:${KUBERNETES_SERVICE_IP},IP:127.0.0.1"
make_cert "apiserver" "kube-apiserver" "kubernetes" "${OUT_DIR}/ca.crt" "${OUT_DIR}/ca.key" "${APISERVER_SAN}"

# API server to kubelet client
make_cert "apiserver-kubelet-client" "kube-apiserver-kubelet-client" "system:masters" "${OUT_DIR}/ca.crt" "${OUT_DIR}/ca.key" "DNS:kube-apiserver"

# Front proxy client
make_cert "front-proxy-client" "front-proxy-client" "kubernetes" "${OUT_DIR}/front-proxy-ca.crt" "${OUT_DIR}/front-proxy-ca.key" "DNS:front-proxy-client"

# Admin, controller-manager, scheduler client certs
make_cert "admin" "system:admin" "system:masters" "${OUT_DIR}/ca.crt" "${OUT_DIR}/ca.key" "DNS:admin"
make_cert "kube-controller-manager" "system:kube-controller-manager" "system:kube-controller-manager" "${OUT_DIR}/ca.crt" "${OUT_DIR}/ca.key" "DNS:kube-controller-manager"
make_cert "kube-scheduler" "system:kube-scheduler" "system:kube-scheduler" "${OUT_DIR}/ca.crt" "${OUT_DIR}/ca.key" "DNS:kube-scheduler"

# Kubelet client certs for each node (including bootstrap)
for node in "${BOOTSTRAP}" "${MASTER0}" "${MASTER1}" "${MASTER2}" "${WORKER0}" "${WORKER1}"; do
  make_cert "kubelet-${node}" "system:node:${node}.${CLUSTER_DOMAIN}" "system:nodes" "${OUT_DIR}/ca.crt" "${OUT_DIR}/ca.key" "DNS:${node}.${CLUSTER_DOMAIN}"
done

# etcd certs per control plane node and bootstrap
for node in "${BOOTSTRAP}" "${MASTER0}" "${MASTER1}" "${MASTER2}"; do
  node_fqdn="${node}.${CLUSTER_DOMAIN}"
  node_ip_var="${node^^}_IP"
  node_ip=${!node_ip_var}
  etcd_san="DNS:${node_fqdn},IP:${node_ip},IP:127.0.0.1"
  make_etcd_cert "${node}-server" "etcd-server" "etcd" "${etcd_san}"
  make_etcd_cert "${node}-peer" "etcd-peer" "etcd" "${etcd_san}"
  make_etcd_cert "${node}-client" "etcd-client" "etcd" "${etcd_san}"
done

# API server etcd client
make_etcd_cert "apiserver-etcd-client" "kube-apiserver" "kubernetes" "DNS:apiserver-etcd-client"

echo "PKI generated in ${OUT_DIR}"
