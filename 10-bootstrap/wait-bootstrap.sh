#!/bin/bash
# Wait for bootstrap to complete initial setup
#
# Monitors the bootstrap node until:
# 1. API server is responding
# 2. Bootstrap is ready for masters to join

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/cluster-vars.sh"

echo "=== Waiting for Bootstrap ==="
echo ""
echo "Bootstrap IP: ${BOOTSTRAP_IP}"
echo ""

wait_for() {
    local name=$1
    local cmd=$2
    local timeout=${3:-300}

    echo -n "Waiting for ${name}..."
    local start=$(date +%s)
    until eval "$cmd" &>/dev/null; do
        local elapsed=$(($(date +%s) - start))
        if [[ $elapsed -gt $timeout ]]; then
            echo " TIMEOUT after ${timeout}s"
            return 1
        fi
        echo -n "."
        sleep 5
    done
    echo " OK"
}

# Wait for SSH
wait_for "SSH" "ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no core@${BOOTSTRAP_IP} true" 300

echo ""
echo "Bootstrap is accessible via SSH"
echo ""

# Wait for API server
echo "Waiting for API server..."
wait_for "API server" "curl -sk https://${BOOTSTRAP_IP}:6443/healthz | grep -q ok" 600

echo ""
echo "API server is healthy!"
echo ""

# Show status
echo "=== Bootstrap Status ==="
echo ""
echo "SSH:  ssh core@${BOOTSTRAP_IP}"
echo ""
echo "Logs:"
echo "  sudo journalctl -u bootkube -f"
echo "  sudo journalctl -u kubelet -f"
echo ""
echo "Static pods:"
ssh core@${BOOTSTRAP_IP} "sudo crictl pods" 2>/dev/null || echo "(SSH failed)"
echo ""

# Check if we can use the API
export KUBECONFIG="${ASSETS_DIR}/kubeconfigs/admin.kubeconfig"
if oc get nodes &>/dev/null; then
    echo "=== Cluster Status ==="
    oc get nodes
    echo ""
    oc get co 2>/dev/null || true
fi

echo ""
echo "=== Bootstrap Ready ==="
echo ""
echo "Bootstrap is ready for masters to join."
echo "Boot the master nodes now."
echo ""
echo "Monitor with:"
echo "  oc get nodes -w"
echo ""
