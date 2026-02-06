# Stage 11: Control Plane Formation

Masters join the cluster and etcd scales from 1 to 3 members. This is a critical phase.

## What Happens

```
Time 0:  Bootstrap running, etcd=1, API=bootstrap
         ↓
         Boot masters
         ↓
Time +5m: Masters register as nodes
         ↓
Time +10m: etcd-operator adds master-0 to etcd cluster
          etcd=2 (bootstrap + master-0)
          ↓
Time +15m: etcd-operator adds master-1
          etcd=3 (bootstrap + master-0 + master-1)
          ↓
Time +20m: etcd-operator removes bootstrap
          etcd=3 (master-0 + master-1 + master-2)
          ↓
Time +25m: Control plane pods start on masters
          ↓
          Ready for pivot
```

## Step 1: Boot Masters

Start all masters:

```bash
virsh start ${CLUSTER_NAME}-master-0
virsh start ${CLUSTER_NAME}-master-1
virsh start ${CLUSTER_NAME}-master-2
```

## Step 2: Monitor Master Boot

SSH to each master after it's up:

```bash
ssh core@${MASTER0_IP}

# Watch kubelet
sudo journalctl -u kubelet -f
```

The master:
1. Boots RHCOS
2. Fetches ignition from MCS (https://api-int:22623/config/master)
3. Applies ignition
4. Starts kubelet
5. Kubelet registers with API server

## Step 3: Verify Node Registration

From your workstation:

```bash
export KUBECONFIG=${ASSETS_DIR}/kubeconfigs/admin.kubeconfig

# Watch nodes appear
watch oc get nodes

# Should eventually show:
# NAME       STATUS   ROLES    AGE
# master-0   Ready    master   5m
# master-1   Ready    master   4m
# master-2   Ready    master   3m
```

## Step 4: Watch etcd Scaling

The etcd-operator handles scaling from 1 to 3 members.

### Monitor etcd membership

From bootstrap:

```bash
sudo crictl exec -it $(sudo crictl ps -q --name etcd) \
  etcdctl member list -w table
```

Initial state (1 member):
```
+------------------+---------+-----------------+------------------------+
|        ID        | STATUS  |      NAME       |       PEER ADDRS       |
+------------------+---------+-----------------+------------------------+
| 8e9e05c52164694d | started | etcd-bootstrap  | https://192.168.126.100:2380 |
+------------------+---------+-----------------+------------------------+
```

After masters join (3-4 members):
```
+------------------+---------+-----------------+------------------------+
|        ID        | STATUS  |      NAME       |       PEER ADDRS       |
+------------------+---------+-----------------+------------------------+
| 8e9e05c52164694d | started | etcd-bootstrap  | https://192.168.126.100:2380 |
| a1b2c3d4e5f67890 | started | etcd-0          | https://192.168.126.101:2380 |
| b2c3d4e5f67890a1 | started | etcd-1          | https://192.168.126.102:2380 |
| c3d4e5f6789a1b2c | started | etcd-2          | https://192.168.126.103:2380 |
+------------------+---------+-----------------+------------------------+
```

### Check etcd health

```bash
sudo crictl exec -it $(sudo crictl ps -q --name etcd) \
  etcdctl endpoint health --cluster
```

All endpoints should report healthy.

## Step 5: Monitor etcd-operator

The etcd-operator orchestrates scaling:

```bash
oc logs -n openshift-etcd-operator deploy/etcd-operator -f
```

Key log messages:
```
Adding member etcd-0
Member etcd-0 started
Adding member etcd-1
Member etcd-1 started
Adding member etcd-2
Member etcd-2 started
Removing bootstrap member
Bootstrap member removed
```

## Step 6: Watch Static Pods on Masters

On each master:

```bash
ssh core@${MASTER0_IP}
sudo crictl pods
```

Expected pods:
```
etcd
kube-apiserver
kube-controller-manager
kube-scheduler
```

Initially pods may be in `NotReady` state while syncing.

## Step 7: Verify API Servers

Check all API server endpoints:

```bash
# Through load balancer
curl -k https://api.${CLUSTER_DOMAIN}:6443/healthz

# Direct to each master
curl -k https://${MASTER0_IP}:6443/healthz
curl -k https://${MASTER1_IP}:6443/healthz
curl -k https://${MASTER2_IP}:6443/healthz
```

All should return `ok`.

## etcd Quorum

etcd requires a quorum (majority) to operate:

| Cluster Size | Quorum | Can Lose |
|--------------|--------|----------|
| 1 | 1 | 0 |
| 2 | 2 | 0 |
| 3 | 2 | 1 |
| 4 | 3 | 1 |
| 5 | 3 | 2 |

During scaling:
- 1 → 2: Dangerous, no fault tolerance
- 2 → 3: Safe, can lose 1 member
- 3 (remove bootstrap): Safe, still have quorum

## Verification Checklist

```bash
export KUBECONFIG=${ASSETS_DIR}/kubeconfigs/admin.kubeconfig

# All masters are nodes
oc get nodes -l node-role.kubernetes.io/master

# All masters have static pods
for node in master-0 master-1 master-2; do
  echo "=== ${node} ==="
  oc get pods -A --field-selector spec.nodeName=${node}.${CLUSTER_DOMAIN} | grep -E 'etcd|apiserver|controller|scheduler'
done

# etcd has 3 members (excluding bootstrap)
oc get pods -n openshift-etcd -l app=etcd
```

## Failure Signals

### Master not registering

```bash
# On the master
sudo journalctl -u kubelet

# Common issues:
# - Can't reach API (DNS, network)
# - Certificate errors
# - MCS not serving config
```

### etcd member not joining

```bash
# Check etcd-operator logs
oc logs -n openshift-etcd-operator deploy/etcd-operator

# Check etcd pod logs on master
ssh core@master-0
sudo crictl logs $(sudo crictl ps -q --name etcd)
```

### Split brain warning

If you see "cluster ID mismatch" errors, etcd members formed separate clusters. This requires manual recovery.

## What's Next

Once all 3 masters have healthy etcd members and the API is responding from all masters, continue to [Stage 12: The Pivot](../12-the-pivot/README.md).
