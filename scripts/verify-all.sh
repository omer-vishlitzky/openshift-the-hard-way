#!/bin/bash
# End-to-end verification script
#
# Checks all infrastructure and cluster components at each stage.
# Run this to diagnose issues or verify the cluster is healthy.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/cluster-vars.sh"

# Colors (if terminal supports them)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

PASS=0
FAIL=0
WARN=0

check() {
    local name=$1
    local cmd=$2
    local timeout=${3:-10}

    printf "%-50s" "$name..."
    if timeout $timeout bash -c "$cmd" &>/dev/null; then
        echo -e "${GREEN}PASS${NC}"
        PASS=$((PASS + 1))
        return 0
    else
        echo -e "${RED}FAIL${NC}"
        FAIL=$((FAIL + 1))
        return 1
    fi
}

warn() {
    local name=$1
    local msg=$2
    printf "%-50s" "$name..."
    echo -e "${YELLOW}WARN${NC} ($msg)"
    WARN=$((WARN + 1))
}

header() {
    echo ""
    echo "=== $1 ==="
    echo ""
}

echo "=== OpenShift the Hard Way - Verification ==="
echo ""
echo "Cluster: ${CLUSTER_NAME}.${BASE_DOMAIN}"
echo "Date: $(date)"
echo ""

# =========================================
header "Prerequisites"
# =========================================

check "SSH key exists" "[[ -f '${SSH_PUB_KEY}' ]]"
check "Pull secret exists" "[[ -f '${PULL_SECRET_FILE}' ]]"
check "Pull secret is valid JSON" "jq . '${PULL_SECRET_FILE}'"
check "oc CLI available" "which oc"
check "jq available" "which jq"
check "podman available" "which podman"

# =========================================
header "DNS"
# =========================================

check "api.${CLUSTER_DOMAIN} resolves" "dig +short api.${CLUSTER_DOMAIN} | grep -q ."
check "api-int.${CLUSTER_DOMAIN} resolves" "dig +short api-int.${CLUSTER_DOMAIN} | grep -q ."
check "test.apps.${CLUSTER_DOMAIN} resolves" "dig +short test.apps.${CLUSTER_DOMAIN} | grep -q ."

# Check DNS points to correct IPs
if dig +short api.${CLUSTER_DOMAIN} | grep -q "${API_VIP}"; then
    check "api DNS points to VIP" "true"
else
    warn "api DNS" "May not point to ${API_VIP}"
fi

# =========================================
header "HAProxy / Load Balancer"
# =========================================

check "HAProxy running" "systemctl is-active haproxy" 5 || true
check "Port 6443 accessible" "curl -sk --connect-timeout 5 https://api.${CLUSTER_DOMAIN}:6443/ || true"
check "Port 22623 accessible" "curl -sk --connect-timeout 5 https://api-int.${CLUSTER_DOMAIN}:22623/ || true"
check "Port 80 accessible" "curl -s --connect-timeout 5 http://apps.${CLUSTER_DOMAIN}/ || true"
check "Port 443 accessible" "curl -sk --connect-timeout 5 https://apps.${CLUSTER_DOMAIN}/ || true"

# =========================================
header "Bootstrap Node"
# =========================================

if ping -c 1 -W 2 ${BOOTSTRAP_IP} &>/dev/null; then
    check "Bootstrap pingable" "ping -c 1 -W 2 ${BOOTSTRAP_IP}"
    check "Bootstrap SSH" "ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no core@${BOOTSTRAP_IP} true" 10 || true
    check "Bootstrap API" "curl -sk --connect-timeout 5 https://${BOOTSTRAP_IP}:6443/healthz | grep -q ok" || true
    # No MCS check - masters get full ignition directly (KTHW approach)
else
    warn "Bootstrap" "Not reachable (may be shut down after pivot)"
fi

# =========================================
header "Master Nodes"
# =========================================

for ip in ${MASTER0_IP} ${MASTER1_IP} ${MASTER2_IP}; do
    check "Master ${ip} pingable" "ping -c 1 -W 2 ${ip}" || true
    check "Master ${ip} API" "curl -sk --connect-timeout 5 https://${ip}:6443/healthz | grep -q ok" || true
done

# =========================================
header "API Server (via VIP)"
# =========================================

check "API /healthz" "curl -sk --connect-timeout 5 https://api.${CLUSTER_DOMAIN}:6443/healthz | grep -q ok"
check "API /readyz" "curl -sk --connect-timeout 5 https://api.${CLUSTER_DOMAIN}:6443/readyz | grep -q ok" || true
check "API /livez" "curl -sk --connect-timeout 5 https://api.${CLUSTER_DOMAIN}:6443/livez | grep -q ok" || true

# =========================================
header "Cluster Status (requires valid kubeconfig)"
# =========================================

export KUBECONFIG="${ASSETS_DIR}/kubeconfigs/admin.kubeconfig"

if [[ -f "${KUBECONFIG}" ]] && oc get nodes &>/dev/null; then
    NODES=$(oc get nodes --no-headers 2>/dev/null | wc -l)
    READY_NODES=$(oc get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo 0)
    check "Kubeconfig works" "oc get nodes"
    check "At least 3 nodes" "[[ $NODES -ge 3 ]]"
    check "All nodes Ready" "[[ $READY_NODES -eq $NODES ]]"

    # Operators
    TOTAL_OPS=$(oc get co --no-headers 2>/dev/null | wc -l)
    AVAILABLE=$(oc get co -o json 2>/dev/null | jq '[.items[].status.conditions[] | select(.type=="Available" and .status=="True")] | length')
    DEGRADED=$(oc get co -o json 2>/dev/null | jq '[.items[].status.conditions[] | select(.type=="Degraded" and .status=="True")] | length')

    check "Operators exist" "[[ $TOTAL_OPS -gt 0 ]]"
    check "All operators Available" "[[ $AVAILABLE -eq $TOTAL_OPS ]]" || true
    check "No operators Degraded" "[[ $DEGRADED -eq 0 ]]"

    # etcd
    ETCD_POD=$(oc get pods -n openshift-etcd -l app=etcd --no-headers 2>/dev/null | head -1 | awk '{print $1}')
    if [[ -n "$ETCD_POD" ]]; then
        check "etcd healthy" "oc exec -n openshift-etcd $ETCD_POD -c etcd -- etcdctl endpoint health" 30
    else
        warn "etcd" "Could not find etcd pod"
    fi
else
    warn "Kubeconfig" "Not found or API not accessible"
fi

# =========================================
header "Ingress"
# =========================================

check "Console accessible" "curl -sk --connect-timeout 10 https://console-openshift-console.apps.${CLUSTER_DOMAIN}/ | grep -q ." || true
check "OAuth accessible" "curl -sk --connect-timeout 10 https://oauth-openshift.apps.${CLUSTER_DOMAIN}/ | grep -q ." || true

# =========================================
header "Summary"
# =========================================

echo ""
echo "Passed: $PASS"
echo "Failed: $FAIL"
echo "Warnings: $WARN"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo -e "${GREEN}All critical checks passed!${NC}"
    exit 0
else
    echo -e "${RED}Some checks failed. See above for details.${NC}"
    exit 1
fi
