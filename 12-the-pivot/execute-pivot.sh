#!/bin/bash
# Execute the pivot - transition from bootstrap to production
#
# The pivot involves:
# 1. Verifying all masters are healthy
# 2. Verifying etcd has 3 members
# 3. Removing bootstrap from load balancer
# 4. Optionally shutting down bootstrap VM

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/cluster-vars.sh"

export KUBECONFIG="${ASSETS_DIR}/kubeconfigs/admin.kubeconfig"

echo "=== Pre-Pivot Verification ==="
echo ""

# Check masters
echo "1. Checking master nodes..."
READY_MASTERS=$(oc get nodes -l node-role.kubernetes.io/master --no-headers 2>/dev/null | grep -c " Ready " || echo 0)
if [[ "$READY_MASTERS" -lt 3 ]]; then
    echo "ERROR: Only ${READY_MASTERS}/3 masters are Ready"
    echo "Wait for all masters before pivoting."
    exit 1
fi
echo "   All 3 masters are Ready"
oc get nodes -l node-role.kubernetes.io/master -o wide
echo ""

# Check etcd
echo "2. Checking etcd cluster..."
ETCD_POD=$(oc get pods -n openshift-etcd -l app=etcd --no-headers 2>/dev/null | head -1 | awk '{print $1}' || echo "")
if [[ -n "$ETCD_POD" ]]; then
    MEMBER_COUNT=$(oc exec -n openshift-etcd "$ETCD_POD" -c etcd -- etcdctl member list 2>/dev/null | wc -l || echo 0)
    echo "   etcd has ${MEMBER_COUNT} members"
    if [[ "$MEMBER_COUNT" -lt 3 ]]; then
        echo "   WARNING: etcd should have 3 members for HA"
    fi
    oc exec -n openshift-etcd "$ETCD_POD" -c etcd -- etcdctl endpoint health --cluster 2>/dev/null || true
else
    echo "   WARNING: Could not check etcd (pods not found)"
fi
echo ""

# Check API availability on masters
echo "3. Checking API server on each master..."
for ip in ${MASTER0_IP} ${MASTER1_IP} ${MASTER2_IP}; do
    if curl -sk https://${ip}:6443/healthz | grep -q ok; then
        echo "   ${ip}: OK"
    else
        echo "   ${ip}: FAILED"
    fi
done
echo ""

# Check via VIP
echo "4. Checking API via VIP..."
if curl -sk https://api.${CLUSTER_DOMAIN}:6443/healthz | grep -q ok; then
    echo "   API VIP: OK"
else
    echo "   API VIP: FAILED"
fi
echo ""

echo "=== Manual Steps Required ==="
echo ""
echo "Now you need to remove bootstrap from the load balancer."
echo ""
echo "1. Edit HAProxy config:"
echo "   sudo vim /etc/haproxy/haproxy.cfg"
echo ""
echo "2. Remove or comment out bootstrap lines in:"
echo "   - 'api' backend (port 6443)"
echo "   - 'machine-config-server' backend (port 22623)"
echo ""
echo "3. Reload HAProxy:"
echo "   sudo systemctl reload haproxy"
echo ""
read -p "Press Enter after updating HAProxy..."

# Verify API still works
echo ""
echo "Verifying API access after HAProxy change..."
if curl -sk https://api.${CLUSTER_DOMAIN}:6443/healthz | grep -q ok; then
    echo "API is accessible - pivot successful!"
else
    echo "WARNING: API not accessible via VIP!"
    echo "Check HAProxy configuration."
    exit 1
fi

echo ""
echo "=== Bootstrap Shutdown ==="
echo ""
echo "Bootstrap can now be safely removed."
echo ""
echo "To shut down the bootstrap VM:"
echo "  virsh destroy ${CLUSTER_NAME}-bootstrap"
echo ""
echo "To delete it completely:"
echo "  virsh undefine ${CLUSTER_NAME}-bootstrap"
echo "  rm /var/lib/libvirt/images/${CLUSTER_NAME}-bootstrap.qcow2"
echo ""
read -p "Shut down bootstrap now? [y/N] " response
if [[ "$response" =~ ^[Yy]$ ]]; then
    virsh destroy ${CLUSTER_NAME}-bootstrap 2>/dev/null || echo "Bootstrap already stopped"
    echo "Bootstrap shut down."
fi

echo ""
echo "=== Pivot Complete ==="
echo ""
echo "The cluster is now running on the 3 master nodes."
echo "Proceed to operator convergence monitoring."
echo ""
