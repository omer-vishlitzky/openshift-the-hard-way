#!/bin/bash
# Generate all PKI for OpenShift cluster

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/cluster-vars.sh"

mkdir -p "${PKI_DIR}"
cd "${PKI_DIR}"

echo "=== Generating OpenShift PKI ==="
echo "Output directory: ${PKI_DIR}"
echo ""

# CA validity in days (10 years)
CA_DAYS=3650
# Certificate validity in days (1 year)
CERT_DAYS=365

generate_ca() {
    local name=$1
    local cn=$2
    local parent_ca=${3:-}
    local parent_key=${4:-}

    echo "Generating CA: ${name}"

    openssl genrsa -out "${name}.key" 4096 2>/dev/null

    if [[ -z "${parent_ca}" ]]; then
        # Self-signed root CA
        openssl req -x509 -new -nodes \
            -key "${name}.key" \
            -sha256 \
            -days ${CA_DAYS} \
            -out "${name}.crt" \
            -subj "/CN=${cn}" 2>/dev/null
    else
        # Intermediate CA signed by parent
        openssl req -new \
            -key "${name}.key" \
            -out "${name}.csr" \
            -subj "/CN=${cn}" 2>/dev/null

        openssl x509 -req \
            -in "${name}.csr" \
            -CA "${parent_ca}" \
            -CAkey "${parent_key}" \
            -CAcreateserial \
            -out "${name}.crt" \
            -days ${CA_DAYS} \
            -sha256 \
            -extfile <(echo "basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign") 2>/dev/null

        rm "${name}.csr"
    fi
}

generate_cert() {
    local name=$1
    local cn=$2
    local ca_name=$3
    local usage=$4
    shift 4
    local sans=("$@")

    echo "Generating certificate: ${name}"

    openssl genrsa -out "${name}.key" 4096 2>/dev/null

    openssl req -new \
        -key "${name}.key" \
        -out "${name}.csr" \
        -subj "/CN=${cn}" 2>/dev/null

    # Build extension file
    local ext_file=$(mktemp)
    echo "basicConstraints = CA:FALSE" > "${ext_file}"
    echo "keyUsage = critical, digitalSignature, keyEncipherment" >> "${ext_file}"

    case "${usage}" in
        server)
            echo "extendedKeyUsage = serverAuth" >> "${ext_file}"
            ;;
        client)
            echo "extendedKeyUsage = clientAuth" >> "${ext_file}"
            ;;
        both)
            echo "extendedKeyUsage = serverAuth, clientAuth" >> "${ext_file}"
            ;;
    esac

    if [[ ${#sans[@]} -gt 0 ]]; then
        echo "subjectAltName = @alt_names" >> "${ext_file}"
        echo "" >> "${ext_file}"
        echo "[alt_names]" >> "${ext_file}"

        local dns_idx=1
        local ip_idx=1
        for san in "${sans[@]}"; do
            if [[ "${san}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo "IP.${ip_idx} = ${san}" >> "${ext_file}"
                ip_idx=$((ip_idx + 1))
            else
                echo "DNS.${dns_idx} = ${san}" >> "${ext_file}"
                dns_idx=$((dns_idx + 1))
            fi
        done
    fi

    openssl x509 -req \
        -in "${name}.csr" \
        -CA "${ca_name}.crt" \
        -CAkey "${ca_name}.key" \
        -CAcreateserial \
        -out "${name}.crt" \
        -days ${CERT_DAYS} \
        -sha256 \
        -extfile "${ext_file}" 2>/dev/null

    rm "${name}.csr" "${ext_file}"
}

# Generate CAs
echo "--- Certificate Authorities ---"
generate_ca "root-ca" "root-ca"
generate_ca "etcd-ca" "etcd-ca" "root-ca.crt" "root-ca.key"
generate_ca "kubernetes-ca" "kubernetes-ca" "root-ca.crt" "root-ca.key"
generate_ca "front-proxy-ca" "front-proxy-ca" "root-ca.crt" "root-ca.key"
generate_ca "kubelet-ca" "kubelet-ca" "kubernetes-ca.crt" "kubernetes-ca.key"
echo ""

# Service account key pair
echo "--- Service Account Keys ---"
echo "Generating service account key pair"
openssl genrsa -out service-account.key 4096 2>/dev/null
openssl rsa -in service-account.key -pubout -out service-account.pub 2>/dev/null
echo ""

# etcd certificates
echo "--- etcd Certificates ---"

# Bootstrap etcd peer certificate
generate_cert "etcd-peer-bootstrap" "etcd-peer-bootstrap" "etcd-ca" "both" \
    "bootstrap.${CLUSTER_DOMAIN}" \
    "localhost" \
    "${BOOTSTRAP_IP}" \
    "127.0.0.1"

# Master etcd peer certificates
for i in 0 1 2; do
    node_name="master-${i}"
    node_ip_var="MASTER${i}_IP"
    node_ip="${!node_ip_var}"

    generate_cert "etcd-peer-${node_name}" "etcd-peer-${node_name}" "etcd-ca" "both" \
        "${node_name}.${CLUSTER_DOMAIN}" \
        "etcd-${i}.${CLUSTER_DOMAIN}" \
        "localhost" \
        "${node_ip}" \
        "127.0.0.1"
done

generate_cert "etcd-server" "etcd-server" "etcd-ca" "both" \
    "localhost" \
    "etcd.${CLUSTER_DOMAIN}" \
    "${BOOTSTRAP_IP}" \
    "${MASTER0_IP}" \
    "${MASTER1_IP}" \
    "${MASTER2_IP}" \
    "127.0.0.1"

generate_cert "etcd-client" "system:etcd-client" "etcd-ca" "client"
echo ""

# API server certificates
echo "--- API Server Certificates ---"
generate_cert "kube-apiserver" "kube-apiserver" "kubernetes-ca" "both" \
    "kubernetes" \
    "kubernetes.default" \
    "kubernetes.default.svc" \
    "kubernetes.default.svc.cluster.local" \
    "api.${CLUSTER_DOMAIN}" \
    "api-int.${CLUSTER_DOMAIN}" \
    "localhost" \
    "${API_VIP}" \
    "${BOOTSTRAP_IP}" \
    "${MASTER0_IP}" \
    "${MASTER1_IP}" \
    "${MASTER2_IP}" \
    "127.0.0.1" \
    "172.30.0.1"

generate_cert "kube-apiserver-kubelet-client" "system:kube-apiserver" "kubernetes-ca" "client"
echo ""

# Controller manager certificate
echo "--- Controller Manager Certificate ---"
generate_cert "kube-controller-manager" "system:kube-controller-manager" "kubernetes-ca" "client"
echo ""

# Scheduler certificate
echo "--- Scheduler Certificate ---"
generate_cert "kube-scheduler" "system:kube-scheduler" "kubernetes-ca" "client"
echo ""

# Front proxy certificate
echo "--- Front Proxy Certificate ---"
generate_cert "front-proxy-client" "front-proxy-client" "front-proxy-ca" "client"
echo ""

# Admin certificate
echo "--- Admin Certificate ---"
openssl genrsa -out admin.key 4096 2>/dev/null
openssl req -new \
    -key admin.key \
    -out admin.csr \
    -subj "/CN=system:admin/O=system:masters" 2>/dev/null
openssl x509 -req \
    -in admin.csr \
    -CA kubernetes-ca.crt \
    -CAkey kubernetes-ca.key \
    -CAcreateserial \
    -out admin.crt \
    -days ${CERT_DAYS} \
    -sha256 \
    -extfile <(echo "basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth") 2>/dev/null
rm admin.csr
echo "Generating certificate: admin"
echo ""

# Bootstrap token certificate
echo "--- Bootstrap Certificate ---"
generate_cert "kubelet-bootstrap" "system:bootstrapper" "kubernetes-ca" "client"
echo ""

echo "=== PKI Generation Complete ==="
echo ""
echo "Files generated in: ${PKI_DIR}"
ls -la "${PKI_DIR}"/*.crt | wc -l | xargs echo "Certificates:"
ls -la "${PKI_DIR}"/*.key | wc -l | xargs echo "Private keys:"
