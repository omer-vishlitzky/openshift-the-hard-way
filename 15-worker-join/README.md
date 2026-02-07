# Stage 15: Worker Join

Workers run application workloads. This stage covers adding worker nodes to the cluster.

## Worker vs Master

| Aspect | Master | Worker |
|--------|--------|--------|
| Control plane | Yes (etcd, API, etc.) | No |
| Workloads | Usually no (tainted) | Yes |
| Required | Yes (3 for HA) | Optional |
| CSR approval | Auto (bootstrap) | Manual |

## Step 1: Boot Workers

Start worker VMs:

```bash
virsh start ${CLUSTER_NAME}-worker-0
virsh start ${CLUSTER_NAME}-worker-1
```

## Step 2: Workers Boot

Workers boot with their complete ignition and:
1. Start kubelet
2. Kubelet uses bootstrap kubeconfig to register with API server
3. Kubelet creates a CSR — you approve it manually

## Step 3: Approve CSRs

Workers require Certificate Signing Request (CSR) approval.

### Why CSR approval?

Workers are not trusted by default. The CSR flow:
1. Kubelet generates a key pair
2. Kubelet submits a CSR to the API
3. Administrator approves the CSR
4. Kubelet receives signed certificate
5. Node is trusted

### View pending CSRs

```bash
oc get csr
```

Output:
```
NAME        AGE   SIGNERNAME                                    REQUESTOR                                                                   CONDITION
csr-abc12   1m    kubernetes.io/kube-apiserver-client-kubelet   system:serviceaccount:openshift-machine-config-operator:node-bootstrapper   Pending
csr-def34   1m    kubernetes.io/kube-apiserver-client-kubelet   system:serviceaccount:openshift-machine-config-operator:node-bootstrapper   Pending
```

### Approve CSRs

```bash
# Approve specific CSR
oc adm certificate approve csr-abc12

# Approve all pending CSRs
oc get csr -o name | xargs oc adm certificate approve
```

### Second wave of CSRs

After initial approval, workers submit another CSR for the node serving certificate:

```bash
# Wait and check again
sleep 30
oc get csr

# Approve again
oc get csr -o name | xargs oc adm certificate approve
```

## Step 4: Verify Workers Join

```bash
# Watch nodes
oc get nodes -w

# Should show workers:
# NAME       STATUS   ROLES    AGE
# master-0   Ready    master   1h
# master-1   Ready    master   1h
# master-2   Ready    master   1h
# worker-0   Ready    worker   5m
# worker-1   Ready    worker   4m
```

## Step 5: Verify Worker Configuration

```bash
# Check worker MachineConfigPool
oc get mcp worker

# Check workers have correct config
oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{range .items[*]}{.metadata.name}: {.metadata.annotations.machineconfiguration\.openshift\.io/state}{"\n"}{end}'
```

## Step 6: Verify Workloads Can Run

Test deploying a workload:

```bash
# Create test deployment
oc create deployment hello-world --image=nginx --replicas=2

# Check pods scheduled on workers
oc get pods -o wide

# Should show pods on worker nodes
```

## CSR Auto-Approval (Optional)

For environments where you trust all nodes, enable auto-approval:

```bash
# Check current auto-approver status
oc get clusteroperator machine-config
```

The MCO auto-approves CSRs for nodes that:
- Have valid bootstrap credentials
- Request expected node certificates

## Adding More Workers

To add additional workers later:

1. Create VM with RHCOS
2. Boot with worker ignition
3. Approve CSRs
4. Wait for node to become Ready

## Worker Node Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| vCPU | 2 | 4+ |
| RAM | 8 GB | 16+ GB |
| Disk | 100 GB | 120+ GB |
| Network | 1 Gbps | 10 Gbps |

## Verification Checklist

```bash
# All workers Ready
oc get nodes -l node-role.kubernetes.io/worker

# Worker MCP updated
oc get mcp worker

# No pending CSRs
oc get csr | grep Pending

# Ingress running on workers
oc get pods -n openshift-ingress -o wide

# Test workload
oc create deployment test --image=nginx
oc get pods -o wide
oc delete deployment test
```

## Troubleshooting

### Worker not registering

```bash
# SSH to worker
ssh core@${WORKER0_IP}

# Check kubelet
sudo journalctl -u kubelet

# Check MCS connectivity
curl -k https://api-int.${CLUSTER_DOMAIN}:22623/healthz
```

### CSR not appearing

```bash
# Check kubelet is running
ssh core@${WORKER0_IP} sudo systemctl status kubelet

# Check kubelet can reach API
ssh core@${WORKER0_IP} curl -k https://api.${CLUSTER_DOMAIN}:6443/healthz
```

### Worker stuck NotReady

```bash
# Check node conditions
oc describe node worker-0

# Check kubelet logs
oc debug node/worker-0 -- chroot /host journalctl -u kubelet
```

## What's Next

With workers running, continue to [Stage 16: Cluster Verification](../16-cluster-verification/README.md) for final checks and smoke tests.
