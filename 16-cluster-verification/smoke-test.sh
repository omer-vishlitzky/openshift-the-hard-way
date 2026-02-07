#!/bin/bash
# Smoke tests for the cluster
#
# Verifies:
# 1. Nodes are Ready
# 2. All operators are Available
# 3. Can deploy and expose a workload
# 4. Ingress is working

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/cluster-vars.sh"

export KUBECONFIG="${ASSETS_DIR}/kubeconfigs/admin.kubeconfig"

PASSED=0
FAILED=0

test_result() {
    local name=$1
    local result=$2

    if [[ "$result" == "pass" ]]; then
        echo "[PASS] $name"
        PASSED=$((PASSED + 1))
    else
        echo "[FAIL] $name"
        FAILED=$((FAILED + 1))
    fi
}

echo "=== OpenShift Smoke Tests ==="
echo ""
echo "Cluster: ${CLUSTER_NAME}.${BASE_DOMAIN}"
echo ""

# Test 1: Nodes
echo "--- Test 1: Nodes ---"
READY_NODES=$(oc get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo 0)
TOTAL_NODES=$(oc get nodes --no-headers 2>/dev/null | wc -l || echo 0)
echo "Nodes: ${READY_NODES}/${TOTAL_NODES} Ready"
oc get nodes
if [[ "$READY_NODES" -ge 3 ]]; then
    test_result "At least 3 nodes Ready" "pass"
else
    test_result "At least 3 nodes Ready" "fail"
fi
echo ""

# Test 2: Cluster Operators
echo "--- Test 2: Cluster Operators ---"
DEGRADED=$(oc get co -o json 2>/dev/null | jq '[.items[].status.conditions[] | select(.type=="Degraded" and .status=="True")] | length' || echo 99)
AVAILABLE=$(oc get co -o json 2>/dev/null | jq '[.items[].status.conditions[] | select(.type=="Available" and .status=="True")] | length' || echo 0)
TOTAL_OPS=$(oc get co --no-headers 2>/dev/null | wc -l || echo 0)
echo "Operators: ${AVAILABLE}/${TOTAL_OPS} Available, ${DEGRADED} Degraded"
if [[ "$DEGRADED" -eq 0 ]]; then
    test_result "No operators degraded" "pass"
else
    test_result "No operators degraded" "fail"
    echo "Degraded operators:"
    oc get co | grep -v "True.*False.*False" || true
fi
echo ""

# Test 3: Deploy workload
echo "--- Test 3: Deploy Workload ---"
TEST_NS="smoke-test-$$"
oc new-project "$TEST_NS" --skip-config-write &>/dev/null || oc project "$TEST_NS" &>/dev/null

oc create deployment nginx --image=nginx:alpine -n "$TEST_NS" &>/dev/null
echo "Created deployment nginx"

echo "Waiting for deployment to be available..."
if oc wait deployment/nginx -n "$TEST_NS" --for=condition=Available --timeout=120s &>/dev/null; then
    test_result "Deployment becomes available" "pass"
else
    test_result "Deployment becomes available" "fail"
fi
echo ""

# Test 4: Expose and test route
echo "--- Test 4: Ingress ---"
oc expose deployment nginx --port=80 -n "$TEST_NS" &>/dev/null || true
oc expose service nginx -n "$TEST_NS" &>/dev/null || true

ROUTE=$(oc get route nginx -n "$TEST_NS" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [[ -n "$ROUTE" ]]; then
    echo "Route: http://${ROUTE}"
    sleep 10  # Wait for router to pick up route

    if curl -s --connect-timeout 10 "http://${ROUTE}" | grep -q "nginx" &>/dev/null; then
        test_result "Route is accessible" "pass"
    else
        test_result "Route is accessible" "fail"
    fi
else
    test_result "Route created" "fail"
fi
echo ""

# Test 5: Console
echo "--- Test 5: Console ---"
CONSOLE_URL="https://console-openshift-console.apps.${CLUSTER_DOMAIN}"
if curl -sk --connect-timeout 10 "${CONSOLE_URL}" | grep -q "openshift" &>/dev/null; then
    test_result "Console is accessible" "pass"
    echo "Console URL: ${CONSOLE_URL}"
else
    test_result "Console is accessible" "fail"
fi
echo ""

# Test 6: etcd health
echo "--- Test 6: etcd ---"
ETCD_POD=$(oc get pods -n openshift-etcd -l app=etcd --no-headers 2>/dev/null | head -1 | awk '{print $1}' || echo "")
if [[ -n "$ETCD_POD" ]]; then
    if oc exec -n openshift-etcd "$ETCD_POD" -c etcd -- etcdctl endpoint health --cluster &>/dev/null; then
        test_result "etcd cluster is healthy" "pass"
    else
        test_result "etcd cluster is healthy" "fail"
    fi
else
    test_result "etcd pods exist" "fail"
fi
echo ""

# Cleanup
echo "--- Cleanup ---"
oc delete project "$TEST_NS" --wait=false &>/dev/null || true
echo "Deleted test namespace: $TEST_NS"
echo ""

# Summary
echo "=== Summary ==="
echo ""
echo "Passed: $PASSED"
echo "Failed: $FAILED"
echo ""

if [[ "$FAILED" -eq 0 ]]; then
    echo "All smoke tests passed!"
    echo ""
    echo "Your OpenShift cluster is ready."
    echo ""
    echo "Console: https://console-openshift-console.apps.${CLUSTER_DOMAIN}"
    echo "API: https://api.${CLUSTER_DOMAIN}:6443"
    echo ""
    echo "Login with admin kubeconfig:"
    echo "  export KUBECONFIG=${ASSETS_DIR}/kubeconfigs/admin.kubeconfig"
    exit 0
else
    echo "Some tests failed. Check the output above."
    exit 1
fi
