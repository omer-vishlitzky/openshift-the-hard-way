# Stage 16: Cluster Verification

Final verification that the cluster is healthy and functional.

## Verification Checklist

### 1. Nodes

```bash
# All nodes Ready
oc get nodes

# Expected output:
# NAME       STATUS   ROLES    AGE    VERSION
# master-0   Ready    master   1h     v1.27.x
# master-1   Ready    master   1h     v1.27.x
# master-2   Ready    master   1h     v1.27.x
# worker-0   Ready    worker   30m    v1.27.x
# worker-1   Ready    worker   30m    v1.27.x
```

### 2. Cluster Operators

```bash
# All operators Available=True, Progressing=False, Degraded=False
oc get co

# Check for any issues
oc get co -o json | jq '.items[] | select(.status.conditions[] | select(.type=="Degraded" and .status=="True")) | .metadata.name'
```

### 3. Cluster Version

```bash
# Cluster version available
oc get clusterversion

# Check version details
oc describe clusterversion version
```

### 4. etcd Health

```bash
# All etcd pods running
oc get pods -n openshift-etcd -l app=etcd

# Check etcd health
oc exec -n openshift-etcd etcd-master-0 -c etcd -- \
  etcdctl endpoint health --cluster
```

### 5. API Server Health

```bash
# API health
curl -k https://api.${CLUSTER_DOMAIN}:6443/healthz

# API server pods
oc get pods -n openshift-kube-apiserver -l app=openshift-kube-apiserver
```

### 6. Core Services

```bash
# DNS
oc get pods -n openshift-dns

# Ingress
oc get pods -n openshift-ingress

# Console
oc get pods -n openshift-console
```

## Smoke Tests

### Test 1: Deploy Application

```bash
# Create test namespace
oc new-project smoke-test

# Deploy nginx
oc create deployment nginx --image=nginx

# Expose as service
oc expose deployment nginx --port=80

# Create route
oc expose service nginx

# Get route URL
ROUTE_URL=$(oc get route nginx -o jsonpath='{.spec.host}')
echo "Route: http://${ROUTE_URL}"

# Test (may take a moment for DNS)
curl -s http://${ROUTE_URL} | head -5
```

### Test 2: Pod-to-Pod Communication

```bash
# Create two pods
oc run client --image=busybox --restart=Never -- sleep 3600
oc run server --image=nginx --restart=Never

# Wait for pods
oc wait pod/client --for=condition=Ready --timeout=60s
oc wait pod/server --for=condition=Ready --timeout=60s

# Get server IP
SERVER_IP=$(oc get pod server -o jsonpath='{.status.podIP}')

# Test connectivity
oc exec client -- wget -O- http://${SERVER_IP} 2>/dev/null | head -5
```

### Test 3: Service Discovery

```bash
# Create service for server
oc expose pod server --port=80 --name=test-service

# Test service DNS
oc exec client -- wget -O- http://test-service 2>/dev/null | head -5
```

### Test 4: Persistent Storage (if CSI installed)

```bash
# Create PVC
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF

# Check PVC status
oc get pvc test-pvc
```

### Test 5: External Access

```bash
# Test ingress from outside
curl -k https://console-openshift-console.apps.${CLUSTER_DOMAIN}
```

## Console Access

### Get Console URL

```bash
oc whoami --show-console
```

### Get kubeadmin Password

```bash
# From auth directory (if using openshift-install)
cat ${ASSETS_DIR}/auth/kubeadmin-password

# Or from secret
oc get secret -n kube-system kubeadmin -o jsonpath='{.data.password}' | base64 -d
```

### Access Console

1. Open: `https://console-openshift-console.apps.${CLUSTER_DOMAIN}`
2. Login as: `kubeadmin`
3. Password: (from above)

## Cleanup Smoke Tests

```bash
oc delete project smoke-test
```

## Final Verification Script

```bash
#!/bin/bash
# final-check.sh

echo "=== OpenShift Cluster Verification ==="
echo ""

echo "--- Nodes ---"
oc get nodes
echo ""

echo "--- Cluster Operators ---"
AVAIL=$(oc get co -o json | jq '[.items[].status.conditions[] | select(.type=="Available" and .status=="True")] | length')
TOTAL=$(oc get co -o json | jq '.items | length')
echo "Available: ${AVAIL}/${TOTAL}"
echo ""

echo "--- Cluster Version ---"
oc get clusterversion
echo ""

echo "--- etcd ---"
oc get pods -n openshift-etcd -l app=etcd --no-headers | wc -l | xargs echo "etcd pods:"
echo ""

echo "--- Critical Pods ---"
for ns in openshift-kube-apiserver openshift-kube-controller-manager openshift-kube-scheduler openshift-etcd; do
  count=$(oc get pods -n $ns --no-headers 2>/dev/null | grep Running | wc -l)
  echo "$ns: $count running"
done
echo ""

echo "--- Console ---"
oc whoami --show-console
echo ""

if [[ "${AVAIL}" == "${TOTAL}" ]]; then
  echo "=== CLUSTER HEALTHY ==="
else
  echo "=== CLUSTER NOT FULLY CONVERGED ==="
  echo "Check: oc get co | grep -v 'True.*False.*False'"
fi
```

## Success Criteria

The cluster is fully operational when:

- [ ] All nodes are Ready
- [ ] All cluster operators are Available
- [ ] ClusterVersion shows Available
- [ ] etcd has 3 healthy members
- [ ] API server responds on all masters
- [ ] Console is accessible
- [ ] Workloads can be deployed
- [ ] Pod networking works
- [ ] Ingress routes traffic

## Congratulations!

You've manually installed an OpenShift cluster. You now understand:

- How certificates flow through the cluster
- What bootkube.sh does
- How etcd bootstraps and scales
- The pivot from bootstrap to masters
- How operators converge
- How MCO manages nodes
- How workers join

## What's Next

- [Appendix: Troubleshooting](../appendix/troubleshooting.md)
- [Appendix: SNO Differences](../appendix/sno-differences.md)
- [Appendix: Disconnected Install](../appendix/disconnected.md)
