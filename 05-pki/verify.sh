#!/bin/bash
# Verify PKI certificates

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/cluster-vars.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

errors=0

echo "=== PKI Verification ==="
echo "Directory: ${PKI_DIR}"
echo ""

check_file() {
    local file=$1
    if [[ -f "${PKI_DIR}/${file}" ]]; then
        echo -e "${GREEN}✓${NC} ${file}"
    else
        echo -e "${RED}✗${NC} ${file} - NOT FOUND"
        errors=$((errors + 1))
    fi
}

check_cert_signed_by() {
    local cert=$1
    local ca=$2

    if openssl verify -CAfile "${PKI_DIR}/${ca}" "${PKI_DIR}/${cert}" &>/dev/null; then
        echo -e "${GREEN}✓${NC} ${cert} signed by ${ca}"
    else
        echo -e "${RED}✗${NC} ${cert} NOT signed by ${ca}"
        errors=$((errors + 1))
    fi
}

check_cert_san() {
    local cert=$1
    local expected_san=$2

    sans=$(openssl x509 -in "${PKI_DIR}/${cert}" -noout -text 2>/dev/null | grep -A1 "Subject Alternative Name" | tail -1)
    if echo "${sans}" | grep -q "${expected_san}"; then
        echo -e "${GREEN}✓${NC} ${cert} has SAN: ${expected_san}"
    else
        echo -e "${RED}✗${NC} ${cert} missing SAN: ${expected_san}"
        errors=$((errors + 1))
    fi
}

check_cert_not_expired() {
    local cert=$1

    if openssl x509 -in "${PKI_DIR}/${cert}" -checkend 86400 -noout &>/dev/null; then
        expiry=$(openssl x509 -in "${PKI_DIR}/${cert}" -noout -enddate 2>/dev/null | cut -d= -f2)
        echo -e "${GREEN}✓${NC} ${cert} not expired (expires: ${expiry})"
    else
        echo -e "${RED}✗${NC} ${cert} is EXPIRED"
        errors=$((errors + 1))
    fi
}

echo "--- Certificate Authorities ---"
check_file "root-ca.crt"
check_file "root-ca.key"
check_file "etcd-ca.crt"
check_file "etcd-ca.key"
check_file "kubernetes-ca.crt"
check_file "kubernetes-ca.key"
check_file "front-proxy-ca.crt"
check_file "front-proxy-ca.key"
echo ""

echo "--- Service Account Keys ---"
check_file "service-account.key"
check_file "service-account.pub"
echo ""

echo "--- etcd Certificates ---"
check_file "etcd-peer-master-0.crt"
check_file "etcd-peer-master-1.crt"
check_file "etcd-peer-master-2.crt"
check_file "etcd-server.crt"
check_file "etcd-client.crt"
echo ""

echo "--- API Server Certificates ---"
check_file "kube-apiserver.crt"
check_file "kube-apiserver-kubelet-client.crt"
check_file "kube-controller-manager.crt"
check_file "kube-scheduler.crt"
check_file "admin.crt"
echo ""

echo "--- Certificate Chain Verification ---"
check_cert_signed_by "etcd-ca.crt" "root-ca.crt"
check_cert_signed_by "kubernetes-ca.crt" "root-ca.crt"
check_cert_signed_by "etcd-peer-master-0.crt" "etcd-ca.crt"
check_cert_signed_by "kube-apiserver.crt" "kubernetes-ca.crt"
check_cert_signed_by "admin.crt" "kubernetes-ca.crt"
echo ""

echo "--- Subject Alternative Names ---"
check_cert_san "kube-apiserver.crt" "api.${CLUSTER_DOMAIN}"
check_cert_san "kube-apiserver.crt" "api-int.${CLUSTER_DOMAIN}"
check_cert_san "kube-apiserver.crt" "${API_VIP}"
check_cert_san "etcd-peer-master-0.crt" "${MASTER0_IP}"
echo ""

echo "--- Certificate Expiry ---"
check_cert_not_expired "kube-apiserver.crt"
check_cert_not_expired "etcd-ca.crt"
check_cert_not_expired "admin.crt"
echo ""

echo "=== Summary ==="
if [[ $errors -eq 0 ]]; then
    echo -e "${GREEN}All PKI verification passed!${NC}"
else
    echo -e "${RED}${errors} error(s) found${NC}"
    exit 1
fi
