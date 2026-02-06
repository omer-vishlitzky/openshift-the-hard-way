#!/bin/bash
# Verify all Stage 02 infrastructure

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/cluster-vars.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

errors=0
warnings=0

echo "=== Stage 02 Infrastructure Verification ==="
echo "Cluster: ${CLUSTER_DOMAIN}"
echo ""

# Check libvirt network
echo "--- libvirt Network ---"
if virsh net-info "${LIBVIRT_NETWORK}" &>/dev/null; then
    if virsh net-info "${LIBVIRT_NETWORK}" | grep -q "Active:.*yes"; then
        echo -e "${GREEN}✓${NC} Network ${LIBVIRT_NETWORK} exists and is active"
    else
        echo -e "${RED}✗${NC} Network ${LIBVIRT_NETWORK} exists but is not active"
        errors=$((errors + 1))
    fi
else
    echo -e "${RED}✗${NC} Network ${LIBVIRT_NETWORK} does not exist"
    errors=$((errors + 1))
fi

# Check libvirt pool
echo ""
echo "--- libvirt Storage Pool ---"
if virsh pool-info "${LIBVIRT_POOL}" &>/dev/null; then
    if virsh pool-info "${LIBVIRT_POOL}" | grep -q "State:.*running"; then
        echo -e "${GREEN}✓${NC} Pool ${LIBVIRT_POOL} exists and is active"
    else
        echo -e "${RED}✗${NC} Pool ${LIBVIRT_POOL} exists but is not active"
        errors=$((errors + 1))
    fi
else
    echo -e "${RED}✗${NC} Pool ${LIBVIRT_POOL} does not exist"
    errors=$((errors + 1))
fi

# Check VMs
echo ""
echo "--- Virtual Machines ---"
for vm in bootstrap master-0 master-1 master-2 worker-0 worker-1; do
    full_name="${CLUSTER_NAME}-${vm}"
    if virsh dominfo "${full_name}" &>/dev/null; then
        echo -e "${GREEN}✓${NC} VM ${full_name} exists"
    else
        echo -e "${RED}✗${NC} VM ${full_name} does not exist"
        errors=$((errors + 1))
    fi
done

# Check DNS
echo ""
echo "--- DNS Resolution ---"
dns_check() {
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

dns_check "api.${CLUSTER_DOMAIN}" "${API_VIP}"
dns_check "api-int.${CLUSTER_DOMAIN}" "${API_VIP}"
dns_check "test.apps.${CLUSTER_DOMAIN}" "${INGRESS_VIP}"

# Check SRV records
srv_result=$(dig +short SRV "_etcd-server-ssl._tcp.${CLUSTER_DOMAIN}" @"${DNS_SERVER}" 2>/dev/null)
if [[ -n "${srv_result}" ]]; then
    echo -e "${GREEN}✓${NC} etcd SRV records configured"
else
    echo -e "${RED}✗${NC} etcd SRV records not found"
    errors=$((errors + 1))
fi

# Check HAProxy
echo ""
echo "--- Load Balancer ---"
if systemctl is-active --quiet haproxy; then
    echo -e "${GREEN}✓${NC} HAProxy is running"
else
    echo -e "${RED}✗${NC} HAProxy is not running"
    errors=$((errors + 1))
fi

for port in 6443 22623; do
    if ss -tlnp | grep -q ":${port} "; then
        echo -e "${GREEN}✓${NC} Port ${port} is listening"
    else
        echo -e "${RED}✗${NC} Port ${port} is not listening"
        errors=$((errors + 1))
    fi
done

# Check RHCOS ISO
echo ""
echo "--- RHCOS Image ---"
ISO_FILE="${ASSETS_DIR}/rhcos/rhcos-live.x86_64.iso"
if [[ -f "${ISO_FILE}" ]]; then
    echo -e "${GREEN}✓${NC} RHCOS ISO downloaded: ${ISO_FILE}"
else
    echo -e "${YELLOW}!${NC} RHCOS ISO not found (run libvirt/download-rhcos.sh)"
    warnings=$((warnings + 1))
fi

echo ""
echo "=== Summary ==="
if [[ $errors -eq 0 && $warnings -eq 0 ]]; then
    echo -e "${GREEN}All infrastructure checks passed!${NC}"
    echo ""
    echo "Ready for Stage 03: Understanding the Installer"
elif [[ $errors -eq 0 ]]; then
    echo -e "${YELLOW}${warnings} warning(s), ${errors} error(s)${NC}"
    echo "Address warnings before proceeding."
else
    echo -e "${RED}${errors} error(s), ${warnings} warning(s)${NC}"
    echo "Fix errors before proceeding."
    exit 1
fi
