# Stage 10: Bootstrap

The bootstrap node orchestrates cluster initialization. This stage explains what happens during bootstrap and how to monitor it.

## Bootstrap Overview

The bootstrap process:

```
┌─────────────────────────────────────────────────────────────────────┐
│                         BOOTSTRAP NODE                              │
├─────────────────────────────────────────────────────────────────────┤
│  1. RHCOS boots with bootstrap.ign                                  │
│  2. kubelet starts                                                  │
│  3. bootkube.sh runs                                                │
│     a. Renders manifests using operators                           │
│     b. Writes static pod manifests                                 │
│     c. kubelet starts static pods                                  │
│  4. etcd starts (single member)                                     │
│  5. kube-apiserver starts                                           │
│  6. kube-controller-manager starts                                  │
│  7. kube-scheduler starts                                           │
│  8. Machine Config Server starts                                    │
│  9. Cluster manifests applied                                       │
│ 10. Waits for masters to join                                       │
│ 11. etcd scales to 3 members                                        │
│ 12. Control plane pivots to masters                                 │
│ 13. Bootstrap complete                                              │
└─────────────────────────────────────────────────────────────────────┘
```

## Step 1: Boot Bootstrap

Start the bootstrap VM:

```bash
virsh start ${CLUSTER_NAME}-bootstrap
```

## Step 2: Monitor Bootstrap Progress

### SSH to bootstrap

```bash
ssh core@${BOOTSTRAP_IP}
```

### Watch bootkube

```bash
sudo journalctl -u bootkube -f
```

Key log messages:
```
Starting bootkube.sh...
Rendering etcd manifests...
Rendering kube-apiserver manifests...
Starting cluster-bootstrap...
Waiting for API server to come up...
API server is up
Applying cluster manifests...
Waiting for bootstrap to complete...
```

### Watch kubelet

```bash
sudo journalctl -u kubelet -f
```

### Check static pods

```bash
sudo crictl pods
```

Expected pods on bootstrap:
```
POD ID      NAME                      STATE
abc123...   etcd-bootstrap            Running
def456...   kube-apiserver-bootstrap  Running
ghi789...   kube-controller-manager   Running
jkl012...   kube-scheduler            Running
```

## Step 3: Verify API Server

From your workstation:

```bash
# Check API is responding
curl -k https://api.${CLUSTER_DOMAIN}:6443/healthz

# Should return: ok
```

Or from bootstrap:

```bash
curl -k https://localhost:6443/healthz
```

## Step 4: Monitor Cluster Status

Once API is up, use kubectl/oc:

```bash
export KUBECONFIG=${ASSETS_DIR}/kubeconfigs/admin.kubeconfig

# Check nodes (initially just bootstrap)
oc get nodes

# Check pods
oc get pods -A

# Check cluster operators (will be degraded initially)
oc get co
```

## Bootstrap Stages Detail

### Stage 1-2: OS Boot

RHCOS boots and applies ignition:
- Creates users
- Writes certificates
- Writes manifests
- Enables systemd units

### Stage 3: bootkube.sh starts

The bootkube service runs `/opt/openshift/bootkube.sh`.

Key operations:
1. Sources environment variables (image references)
2. Runs operator render commands
3. Writes rendered manifests to `/etc/kubernetes/manifests/`

### Stage 4: etcd starts

Kubelet sees `/etc/kubernetes/manifests/etcd-pod.yaml` and starts etcd.

Initially a single-member cluster:
```bash
sudo crictl logs $(sudo crictl ps -q --name etcd)
# Look for "etcd cluster is healthy"
```

Verify:
```bash
sudo crictl exec -it $(sudo crictl ps -q --name etcd) \
  etcdctl endpoint health --cluster
```

### Stage 5-7: Control plane starts

After etcd is healthy, kube-apiserver starts.

Then kube-controller-manager and kube-scheduler start and connect to the API server.

### Stage 8: Machine Config Server

The MCS starts serving ignition configs:

```bash
# From bootstrap
curl -k https://localhost:22623/config/master
```

This is what masters fetch when they boot.

### Stage 9: Cluster manifests

bootkube.sh applies manifests to seed the cluster:
- CVO deployment
- MCO deployment
- Core cluster resources

### Stage 10-12: Masters join

This happens after you boot the masters (Stage 11).

## Verification Checklist

Run on bootstrap:

```bash
# Static pods running
sudo crictl pods | grep -c Running  # Should be 4+

# etcd healthy
sudo crictl exec -it $(sudo crictl ps -q --name etcd) \
  etcdctl endpoint health

# API responding
curl -k https://localhost:6443/healthz

# MCS serving
curl -k https://localhost:22623/healthz
```

## Failure Signals

### bootkube.sh fails

```bash
sudo journalctl -u bootkube --no-pager
```

Common causes:
- Image pull failures (check pull secret)
- Network issues (can't reach registry)
- Certificate errors

### etcd won't start

```bash
sudo crictl logs $(sudo crictl ps -a -q --name etcd)
```

Common causes:
- Disk too slow (etcd needs fast storage)
- Certificate mismatch
- Wrong IP configuration

### API server won't start

```bash
sudo crictl logs $(sudo crictl ps -a -q --name kube-apiserver)
```

Common causes:
- etcd not ready
- Certificate errors
- Port conflicts

## What's Next

Once bootstrap API is healthy:
1. Boot masters (next section)
2. Monitor etcd scaling
3. Verify control plane formation

Continue to [Stage 11](../11-control-plane-formation/README.md).
