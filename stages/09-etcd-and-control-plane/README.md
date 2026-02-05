# Stage 09: etcd and the Control Plane

This stage drills into the control plane and etcd once bootstrap has started. The focus is on quorum, health, and how the control plane becomes stable.

**Sources used in this stage**
- `../pdfs/openshift/Architecture.pdf`
- `../pdfs/openshift/Installing_on_bare_metal.pdf`
- `../pdfs/openshift/Installation_overview.pdf`

## etcd fundamentals

- etcd is the source of truth for cluster state.
- It uses the Raft consensus algorithm.
- It requires quorum, which means a majority of members must be healthy.

For HA, this is why three control plane nodes are the minimum. Two is not enough to tolerate failure.

## Control plane pods

During bootstrap and early control plane formation, the core components run as static pods:
- etcd
- kube-apiserver
- kube-controller-manager
- kube-scheduler

Static pods are defined in `/etc/kubernetes/manifests` and are launched by the kubelet directly.

## Health signals to watch

Once the control plane is forming, these signals tell you if etcd and the API are healthy:

- API server is reachable at the API VIP on port 6443.
- etcd ports 2379-2380 are reachable between control plane nodes.
- `oc get nodes` shows control plane nodes as `Ready`.
- `oc -n openshift-etcd get pods` shows all etcd pods running.

## Hands-on: check etcd health from a running cluster

These commands are safe and help you validate quorum and health.

```bash
oc -n openshift-etcd get pods
oc -n openshift-etcd rsh <etcd_pod>
```

Inside the pod:

```bash
export ETCDCTL_API=3
etcdctl endpoint health
etcdctl member list
```

## Verification checks

- All etcd pods are running and healthy.
- The member list shows all control plane nodes.
- `oc get nodes` shows all control plane nodes as `Ready`.

**Deliverables for this stage**
- A working understanding of etcd quorum and health.
- A repeatable checklist for control plane readiness.
