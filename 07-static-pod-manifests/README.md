# Stage 07: Static Pod Manifests & Cluster Manifests

## What Are Static Pods?

Before the API server exists, there's no way to create Pods via `kubectl`. So how do you start the API server itself? The answer: **static pods**.

Kubelet watches a directory (`/etc/kubernetes/manifests/`) for YAML files. Any Pod defined there is started directly by kubelet — no API server needed. This is the only way to bootstrap a control plane from nothing.

## What We're Building

Five static pods on the bootstrap node, and one on each master:

### Bootstrap static pods

| Component | Purpose | Port |
|-----------|---------|------|
| **etcd** | Key-value store for ALL cluster state | 2379 (client), 2380 (peer) |
| **kube-apiserver** | The API that everything talks to | 6443 |
| **kube-controller-manager** | Runs control loops (reconciles desired vs actual state) | 10257 |
| **kube-scheduler** | Decides which node runs each pod | 10259 |
| **CVO** | Reads the release image, deploys all operators | - |

### Master static pods

| Component | Purpose |
|-----------|---------|
| **kube-proxy** | Translates Service ClusterIPs to real endpoint IPs |

The first four are the Kubernetes control plane — same as KTHW. CVO is where OpenShift diverges: it's the handoff point from manual to automated.

## Why masters need kube-proxy

This is a critical piece that's easy to miss.

When a pod wants to reach the Kubernetes API, it uses the `kubernetes` Service at `172.30.0.1:443`. This is a **virtual IP** — it doesn't exist on any network interface. Something needs to translate it to the real API server IP (`192.168.126.100:6443`). That something is **kube-proxy**.

kube-proxy runs on every node and programs iptables rules that intercept traffic to Service ClusterIPs and redirect it to the actual endpoints. Without it:

```
Pod → 172.30.0.1:443 → ??? → timeout
```

With kube-proxy:

```
Pod → 172.30.0.1:443 → iptables rule → 192.168.126.100:6443 → API server
```

**Every operator deployed by CVO** tries to reach the API at `172.30.0.1:443`. Without kube-proxy, they all timeout and crash. The network operator (OVN-Kubernetes) eventually replaces kube-proxy, but OVN itself is an operator that needs kube-proxy to bootstrap.

This is the chicken-and-egg: operators need ClusterIP routing → kube-proxy provides it → OVN replaces it → kube-proxy can be removed.

kube-proxy uses its own dedicated image from the release payload (not hyperkube). It needs the `system:node-proxier` ClusterRole bound to the bootstrap identity so it can watch Services and Endpoints.

## CVO: The Handoff Point

CVO (Cluster Version Operator) is the ONE operator we deploy. It:
1. Runs as a static pod using the **release image** (not the CVO operator image — because it needs `/release-manifests/` which only exists in the release image)
2. Reads 900+ manifests from `/release-manifests/` inside its container
3. Applies them to the API server in dependency order
4. Deploys all 50+ operators (etcd-operator, ingress, console, etc.)

### Why CVO needs CRDs first

CVO's informers watch OpenShift API types (ClusterVersion, ClusterOperator, Infrastructure, etc.). These types don't exist on a bare Kubernetes API server — they're Custom Resource Definitions. If CVO starts before the CRDs exist, its informers fail and it can't initialize.

Solution: we extract CRDs from the release ahead of time (Stage 04) and apply them via bootkube.sh before CVO starts reading them.

### Why CVO needs a FeatureGate

CVO detects which features are enabled by reading a FeatureGate CR. If none exists, CVO uses defaults at startup — but then detects a mismatch when it reads the actual cluster state, and shuts down thinking the feature set changed.

Solution: we create a FeatureGate CR with the default feature set (same as the real installer does).

## MCO: The Node OS Layer

We hand-write the control plane (etcd, apiserver, kcm, scheduler, CVO). But master and worker nodes also need dozens of OS-level configurations that have nothing to do with the control plane:

| File/Unit | What it does |
|-----------|-------------|
| `/usr/local/bin/configure-ovs.sh` | Creates the `br-ex` OVS bridge for OVN networking (1100+ lines) |
| `ovs-configuration.service` | Runs configure-ovs.sh at boot |
| `nodeip-configuration.service` | Determines the node's primary IP address |
| `kubelet.service` | kubelet with OpenShift-specific flags and drop-ins |
| `/etc/kubernetes/apiserver-url.env` | API server URL that operators read |
| `crio.service` drop-ins | CRI-O configuration for OpenShift |
| `machine-config-daemon-pull.service` | Pulls MCD image for node management |
| NM dispatcher scripts | NetworkManager hooks for OVN integration |
| SELinux relabeling units | Correct security contexts for OVS, kubelet paths |
| `/etc/mco/proxy.env` | Proxy configuration for node services |
| 20+ more systemd units and config files | |

MCO (Machine Config Operator) is a **template engine** that takes cluster configuration (networking CIDRs, platform type, DNS) and produces complete node ignition configs with all these files. It's the same tier as etcd — core infrastructure, not optional.

### Why we use MCO instead of hand-writing

Fixing OVN prerequisites one-by-one is whack-a-mole. `configure-ovs.sh` alone is 1100+ lines of bash that creates OVS bridges, configures NetworkManager, handles bond/VLAN interfaces, and sets up routing. The `nodeip-configuration.service` has platform-specific logic for detecting the node's primary IP. None of this teaches you about Kubernetes or OpenShift architecture — it's OS plumbing.

### The boundary

**We hand-write** (educational value — understand how the control plane works):
- etcd, kube-apiserver, kube-controller-manager, kube-scheduler
- All PKI certificates and kubeconfigs
- CVO deployment and cluster manifests
- RBAC for node bootstrapping
- kube-proxy (ClusterIP routing bootstrap)

**MCO handles** (OS plumbing — zero learning value in typing):
- OVS bridge creation and NetworkManager integration
- kubelet.service with correct OpenShift flags
- CRI-O runtime configuration
- SELinux policies and context restoration
- Node IP detection
- 30+ systemd units and config files

### How we use it

We run MCO's render commands on the host (via podman) to produce the rendered ignition configs. Then we merge our additions (static IP, kube-proxy, bootstrap kubeconfig) on top. See [Stage 04](../04-release-image/README.md) for the extraction and [Stage 08](../08-ignition/README.md) for the merge.

## How This Differs From KTHW

In KTHW, control plane components run as **systemd units** (bare processes). In OpenShift, they run as **static pods** (containers managed by kubelet).

Why containers? Because RHCOS is immutable — you can't install binaries. Everything runs in containers.

## Generate

```bash
# Static pod manifests (etcd, apiserver, kcm, scheduler, CVO)
./generate.sh
./generate-cluster-manifests.sh
```

`generate.sh` writes the 4 core Kubernetes static pods.
`generate-cluster-manifests.sh` writes the CVO static pod plus cluster manifests (namespaces, RBAC, secrets, Infrastructure/Network/DNS CRs, FeatureGate).

Read the scripts — every flag has a comment explaining what it does and why.

## What's Next

In [Stage 08](../08-ignition/README.md), these manifests are embedded into the bootstrap Ignition config alongside certificates, kubeconfigs, CRDs, and systemd units. When the bootstrap node boots, kubelet starts the control plane, bootkube.sh applies the cluster manifests, and CVO begins deploying operators.
