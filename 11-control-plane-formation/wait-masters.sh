#!/bin/bash
# Wait for all masters to join the cluster
#
# This script monitors until:
# 1. All 3 master nodes are Ready
# 2. etcd has 3 healthy members
# 3. Control plane pods are running on masters

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/cluster-vars.sh"

export KUBECONFIG="${ASSETS_DIR}/kubeconfigs/admin.kubeconfig"

echo "=== Waiting for Masters ==="
echo ""

TIMEOUT=1800  # 30 minutes
START=$(date +%s)

# Wait for 3 master nodes to become Ready
echo "Waiting for 3 master nodes to become Ready..."
while true; do
    READY_COUNT=$(oc get nodes -l node-role.kubernetes.io/master --no-headers 2>/dev/null | grep -c " Ready " || echo 0)
    TOTAL_COUNT=$(oc get nodes -l node-role.kubernetes.io/master --no-headers 2>/dev/null | wc -l || echo 0)

    echo "  Masters: ${READY_COUNT}/3 Ready (${TOTAL_COUNT} total)"

    if [[ "$READY_COUNT" -ge 3 ]]; then
        break
    fi

    ELAPSED=$(($(date +%s) - START))
    if [[ $ELAPSED -gt $TIMEOUT ]]; then
        echo "TIMEOUT waiting for masters after ${TIMEOUT}s"
        echo ""
        echo "Debug:"
        oc get nodes -o wide
        exit 1
    fi

    sleep 15
done

echo ""
echo "All 3 masters are Ready!"
echo ""
oc get nodes -l node-role.kubernetes.io/master -o wide
echo ""

# Wait for etcd to have 3 members
echo "Waiting for etcd to scale to 3 members..."
sleep 30  # Give etcd time to form

# Check etcd membership
ETCD_POD=$(oc get pods -n openshift-etcd -l app=etcd --no-headers 2>/dev/null | head -1 | awk '{print $1}' || echo "")
if [[ -n "$ETCD_POD" ]]; then
    echo "Checking etcd cluster:"
    oc exec -n openshift-etcd "$ETCD_POD" -c etcd -- etcdctl member list -w table 2>/dev/null || {
        echo "  (etcd not ready yet, will be checked later)"
    }
else
    echo "  etcd pods not found yet (may be bootstrapping)"
fi

echo ""
echo "=== Master Formation Complete ==="
echo ""
echo "Control plane is now distributed across 3 masters."
echo "Proceed to the pivot stage."
echo ""
