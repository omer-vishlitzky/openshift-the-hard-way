# Stage 11: Control Plane Formation

Masters join the cluster, kube-proxy enables Service routing, operators begin deploying, and etcd scales from 1 to 3 members. This is the most complex phase.

## What Happens

```
Time 0:  Bootstrap running, etcd=1, API=bootstrap
         ↓
         Boot masters (each has: kubelet, kube-proxy, CRI-O config, apiserver-url.env)
         ↓
Time +5m: Masters register as nodes (CSRs approved)
         kube-proxy starts on masters → ClusterIP routing works
         ↓
         CVO deploys operators → operators can reach API via 172.30.0.1
         ↓
Time +10m: etcd-operator adds master-0 to etcd cluster
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
1. Boots RHCOS with its complete ignition config
2. Starts kubelet
3. Kubelet uses bootstrap kubeconfig (CN=`system:bootstrapper`) to connect to the API
4. Kubelet creates a CSR asking for a client certificate
5. You approve the CSR manually
6. Kubelet gets its client cert, registers as a node
7. Kubelet creates a SECOND CSR for its serving certificate
8. You approve that too

**Why two CSRs?** The first CSR (`kube-apiserver-client-kubelet`) is the kubelet's identity — how it authenticates TO the API server. The second CSR (`kubelet-serving`) is the kubelet's TLS cert — how other components (like the API server doing `kubectl logs`) connect TO the kubelet.

## Step 3: Approve CSRs and verify nodes

```bash
export KUBECONFIG=${ASSETS_DIR}/kubeconfigs/admin.kubeconfig

# Check for pending CSRs
oc get csr

# Approve all pending CSRs (first wave — client certs)
oc get csr -o name | xargs oc adm certificate approve

# Wait 15 seconds, then approve second wave (serving certs)
sleep 15
oc get csr -o name | xargs oc adm certificate approve

# Verify nodes registered
oc get nodes
```

Nodes will show `NotReady` initially — that's normal until the network operator deploys a CNI plugin.

## DO NOT shut down the bootstrap yet

bootkube.sh will print "Bootstrap Complete" when it sees 3/3 masters registered. **This does NOT mean the bootstrap is safe to remove.**

The bootstrap is still running:
- **The only etcd** — masters don't have etcd yet
- **The only API server** — masters don't have API server pods yet
- **CVO** — still deploying operators as a static pod

What needs to happen before you can remove the bootstrap:
1. CVO (on bootstrap) deploys operator Deployments → scheduler places them on masters
2. etcd-operator deploys etcd pods on each master → etcd scales 1 → 3
3. kube-apiserver-operator deploys API server pods on masters
4. Once etcd has 3 members on masters and API servers are running there, the bootstrap becomes redundant
5. **Then** you remove bootstrap from HAProxy and shut it down (Stage 12)

**Where is CVO running?** On the bootstrap, as a static pod. It talks to the API server on localhost and applies manifests from the release image. Those manifests create Deployments that the scheduler places on masters. CVO runs on bootstrap, but the operators it deploys run on masters.

## Step 4: Watch etcd Scaling

The etcd-operator (deployed by CVO) handles scaling from 1 to 3 members.

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
# - Bootstrap kubeconfig invalid
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
