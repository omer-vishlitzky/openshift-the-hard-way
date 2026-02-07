#!/bin/bash
# Wait for all cluster operators to converge
#
# After the pivot, CVO starts deploying operators.
# This script monitors until all operators are:
# - Available: True
# - Progressing: False
# - Degraded: False

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/cluster-vars.sh"

export KUBECONFIG="${ASSETS_DIR}/kubeconfigs/admin.kubeconfig"

TIMEOUT=${1:-3600}  # Default 60 minutes

echo "=== Waiting for Operator Convergence ==="
echo ""
echo "Timeout: ${TIMEOUT}s ($(($TIMEOUT / 60)) minutes)"
echo ""

START=$(date +%s)

while true; do
    # Get operator status
    TOTAL=$(oc get co --no-headers 2>/dev/null | wc -l || echo 0)
    AVAILABLE=$(oc get co -o json 2>/dev/null | jq '[.items[].status.conditions[] | select(.type=="Available" and .status=="True")] | length' || echo 0)
    PROGRESSING=$(oc get co -o json 2>/dev/null | jq '[.items[].status.conditions[] | select(.type=="Progressing" and .status=="True")] | length' || echo 0)
    DEGRADED=$(oc get co -o json 2>/dev/null | jq '[.items[].status.conditions[] | select(.type=="Degraded" and .status=="True")] | length' || echo 0)

    ELAPSED=$(($(date +%s) - START))
    REMAINING=$(($TIMEOUT - $ELAPSED))

    printf "\r[%4ds] Operators: %2d/%2d Available, %2d Progressing, %2d Degraded    " \
        $ELAPSED $AVAILABLE $TOTAL $PROGRESSING $DEGRADED

    # Check if converged
    if [[ "$AVAILABLE" -eq "$TOTAL" ]] && [[ "$DEGRADED" -eq 0 ]] && [[ "$PROGRESSING" -eq 0 ]]; then
        echo ""
        echo ""
        echo "=== All Operators Converged! ==="
        break
    fi

    # Check timeout
    if [[ $ELAPSED -gt $TIMEOUT ]]; then
        echo ""
        echo ""
        echo "TIMEOUT after ${TIMEOUT}s"
        echo ""
        echo "Operators still not ready:"
        oc get co | grep -v "True.*False.*False"
        exit 1
    fi

    sleep 15
done

echo ""
oc get co
echo ""

# Show cluster version
echo ""
echo "Cluster version:"
oc get clusterversion
echo ""

# Check for any issues
DEGRADED_OPS=$(oc get co -o json | jq -r '.items[] | select(.status.conditions[] | select(.type=="Degraded" and .status=="True")) | .metadata.name')
if [[ -n "$DEGRADED_OPS" ]]; then
    echo "WARNING: Some operators are degraded:"
    echo "$DEGRADED_OPS"
fi

echo ""
echo "=== Convergence Complete ==="
echo ""
echo "All operators are Available and not Degraded."
echo "The cluster is ready for worker nodes."
echo ""
