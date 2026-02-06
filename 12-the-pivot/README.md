# Stage 12: The Pivot

The "pivot" is when control transfers from bootstrap to masters. After pivot, bootstrap is no longer needed.

## What is the Pivot?

The pivot is NOT a single event. It's a gradual handoff:

1. **etcd pivot**: Bootstrap etcd member removed, masters have quorum
2. **API pivot**: Load balancer routes to master API servers
3. **MCS pivot**: Machine Config Server runs on masters
4. **CVO pivot**: Cluster Version Operator runs on masters

## How to Know Pivot is Complete

### Signal 1: etcd has no bootstrap member

```bash
oc get pods -n openshift-etcd -l app=etcd

# Should show 3 pods, all on masters:
# NAME        READY   STATUS    NODE
# etcd-master-0   2/2   Running   master-0
# etcd-master-1   2/2   Running   master-1
# etcd-master-2   2/2   Running   master-2
```

### Signal 2: API servers healthy on all masters

```bash
for master in ${MASTER0_IP} ${MASTER1_IP} ${MASTER2_IP}; do
  echo -n "${master}: "
  curl -sk https://${master}:6443/healthz
  echo
done

# Should show:
# 192.168.126.101: ok
# 192.168.126.102: ok
# 192.168.126.103: ok
```

### Signal 3: Bootstrap reports complete

On bootstrap:

```bash
# Check for completion marker
ls /opt/openshift/.bootkube.done

# Check bootstrap-complete file
cat /opt/openshift/bootstrap-complete
```

Or via API:

```bash
oc get configmap -n kube-system bootstrap -o yaml
```

### Signal 4: Machine Config Server on masters

```bash
# MCS runs as part of machine-config-operator on masters
oc get pods -n openshift-machine-config-operator -l k8s-app=machine-config-server
```

## Removing Bootstrap

### Step 1: Verify it's safe

```bash
# Check all masters are Ready
oc get nodes -l node-role.kubernetes.io/master

# Check etcd is healthy with 3 members
oc get pods -n openshift-etcd -l app=etcd

# Check API responds without bootstrap
# (stop bootstrap and test)
```

### Step 2: Remove from load balancer

Edit HAProxy config to remove bootstrap from backends:

```bash
sudo vim /etc/haproxy/haproxy.cfg
```

Remove these lines from API and MCS backends:
```
server bootstrap 192.168.126.100:6443 check
server bootstrap 192.168.126.100:22623 check
```

Reload HAProxy:
```bash
sudo systemctl reload haproxy
```

### Step 3: Verify API still works

```bash
curl -k https://api.${CLUSTER_DOMAIN}:6443/healthz
oc get nodes
```

### Step 4: Shutdown bootstrap

```bash
virsh destroy ${CLUSTER_NAME}-bootstrap
```

### Step 5: (Optional) Delete bootstrap VM

```bash
virsh undefine ${CLUSTER_NAME}-bootstrap --remove-all-storage
```

## What Runs Where After Pivot

### Bootstrap (before shutdown)
- etcd (bootstrap member)
- kube-apiserver
- kube-controller-manager
- kube-scheduler
- Machine Config Server

### Masters (after pivot)
- etcd (3 members)
- kube-apiserver (3 instances)
- kube-controller-manager (leader election)
- kube-scheduler (leader election)
- Machine Config Server (DaemonSet)
- Cluster Version Operator
- All other operators

## Leader Election

After pivot, some components use leader election:

| Component | Leader Election |
|-----------|-----------------|
| etcd | Raft consensus |
| kube-apiserver | All active (stateless) |
| kube-controller-manager | Single leader |
| kube-scheduler | Single leader |

Check leader:

```bash
# Controller manager leader
oc get endpoints -n kube-system kube-controller-manager -o yaml

# Scheduler leader
oc get endpoints -n kube-system kube-scheduler -o yaml
```

## Verification Checklist

After removing bootstrap:

```bash
# API still works
oc get nodes

# All masters Ready
oc get nodes -l node-role.kubernetes.io/master -o wide

# etcd healthy
oc get pods -n openshift-etcd

# Cluster operators progressing
oc get co
```

## Failure Signals

### API unreachable after removing bootstrap

```bash
# Check HAProxy backends
curl http://localhost:9000/stats

# Check masters are responding
for ip in ${MASTER0_IP} ${MASTER1_IP} ${MASTER2_IP}; do
  curl -sk https://${ip}:6443/healthz
done

# Re-add bootstrap if needed
```

### etcd unhealthy

```bash
# Check etcd pods
oc logs -n openshift-etcd etcd-master-0 -c etcd

# Check member health
oc exec -n openshift-etcd etcd-master-0 -c etcd -- \
  etcdctl endpoint health --cluster
```

## What's Next

With bootstrap removed and control plane running on masters, continue to [Stage 13: Operator Convergence](../13-operator-convergence/README.md) to watch operators deploy.
