#!/bin/bash
# Approve pending CSRs for worker nodes
#
# When workers join, they submit CSRs (Certificate Signing Requests)
# that must be approved for them to become Ready.
#
# There are typically 2 rounds:
# 1. Node bootstrap CSR (system:node:xxx)
# 2. Kubelet serving CSR (after bootstrap approved)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/cluster-vars.sh"

export KUBECONFIG="${ASSETS_DIR}/kubeconfigs/admin.kubeconfig"

echo "=== CSR Approval ==="
echo ""

approve_pending() {
    local pending=$(oc get csr -o json 2>/dev/null | jq -r '.items[] | select(.status.conditions == null or (.status.conditions | length == 0)) | .metadata.name')

    if [[ -z "$pending" ]]; then
        echo "No pending CSRs"
        return 0
    fi

    echo "Pending CSRs:"
    echo "$pending"
    echo ""

    for csr in $pending; do
        echo "Approving: $csr"
        oc adm certificate approve "$csr"
    done

    return 1  # More CSRs may come
}

# Initial check
echo "Checking for pending CSRs..."
approve_pending

echo ""
echo "Current CSR status:"
oc get csr
echo ""

# Watch mode
if [[ "$1" == "-w" ]] || [[ "$1" == "--watch" ]]; then
    echo ""
    echo "Watching for new CSRs (Ctrl+C to stop)..."
    echo ""

    while true; do
        if approve_pending; then
            sleep 30
        else
            echo ""
            echo "Approved CSRs. Waiting for second round..."
            sleep 30
        fi
    done
else
    echo ""
    echo "Workers typically submit 2 CSRs each."
    echo "Run with -w to continuously watch and approve:"
    echo "  $0 -w"
    echo ""
    echo "Or check again in 30 seconds for second-wave CSRs."
fi

echo ""
echo "Current nodes:"
oc get nodes
echo ""
