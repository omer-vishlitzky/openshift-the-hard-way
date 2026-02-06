#!/bin/bash
# Verify DNS configuration for OpenShift cluster

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../config/cluster-vars.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

errors=0

check_dns() {
    local name=$1
    local expected=$2

    result=$(dig +short "${name}" @"${DNS_SERVER}" 2>/dev/null | head -1)

    if [[ "${result}" == "${expected}" ]]; then
        echo -e "${GREEN}✓${NC} ${name} → ${result}"
    else
        echo -e "${RED}✗${NC} ${name} → got '${result}', expected '${expected}'"
        errors=$((errors + 1))
    fi
}

check_srv() {
    local name=$1
    local expected_port=$2

    result=$(dig +short SRV "${name}" @"${DNS_SERVER}" 2>/dev/null)

    if [[ -n "${result}" ]] && echo "${result}" | grep -q "${expected_port}"; then
        echo -e "${GREEN}✓${NC} ${name} → SRV records found"
        echo "${result}" | sed 's/^/    /'
    else
        echo -e "${RED}✗${NC} ${name} → SRV records not found"
        errors=$((errors + 1))
    fi
}

echo "=== DNS Verification for ${CLUSTER_DOMAIN} ==="
echo "Using DNS server: ${DNS_SERVER}"
echo ""

echo "--- API Endpoints ---"
check_dns "api.${CLUSTER_DOMAIN}" "${API_VIP}"
check_dns "api-int.${CLUSTER_DOMAIN}" "${API_VIP}"

echo ""
echo "--- Apps Wildcard ---"
check_dns "test.apps.${CLUSTER_DOMAIN}" "${INGRESS_VIP}"
check_dns "console-openshift-console.apps.${CLUSTER_DOMAIN}" "${INGRESS_VIP}"

echo ""
echo "--- Bootstrap ---"
check_dns "${BOOTSTRAP_NAME}.${CLUSTER_DOMAIN}" "${BOOTSTRAP_IP}"

echo ""
echo "--- Masters ---"
check_dns "${MASTER0_NAME}.${CLUSTER_DOMAIN}" "${MASTER0_IP}"
check_dns "${MASTER1_NAME}.${CLUSTER_DOMAIN}" "${MASTER1_IP}"
check_dns "${MASTER2_NAME}.${CLUSTER_DOMAIN}" "${MASTER2_IP}"

echo ""
echo "--- Workers ---"
check_dns "${WORKER0_NAME}.${CLUSTER_DOMAIN}" "${WORKER0_IP}"
check_dns "${WORKER1_NAME}.${CLUSTER_DOMAIN}" "${WORKER1_IP}"

echo ""
echo "--- etcd ---"
check_dns "etcd-0.${CLUSTER_DOMAIN}" "${MASTER0_IP}"
check_dns "etcd-1.${CLUSTER_DOMAIN}" "${MASTER1_IP}"
check_dns "etcd-2.${CLUSTER_DOMAIN}" "${MASTER2_IP}"

echo ""
echo "--- etcd SRV Records ---"
check_srv "_etcd-server-ssl._tcp.${CLUSTER_DOMAIN}" "2380"

echo ""
echo "=== Summary ==="
if [[ $errors -eq 0 ]]; then
    echo -e "${GREEN}All DNS checks passed!${NC}"
else
    echo -e "${RED}${errors} DNS check(s) failed${NC}"
    exit 1
fi
