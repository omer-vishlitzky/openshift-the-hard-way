# Stage 00: OpenShift Fundamentals

Before diving into manual installation, you need to understand what OpenShift actually is and why it's more complex than vanilla Kubernetes.

## What is OpenShift?

OpenShift = Kubernetes + Enterprise Features + Operator Pattern

Where Kubernetes provides container orchestration, OpenShift adds:

| Layer | Kubernetes | OpenShift |
|-------|------------|-----------|
| **OS** | Any Linux | RHCOS (immutable, container-optimized) |
| **First Boot** | cloud-init, Ansible | Ignition (declarative, atomic) |
| **Config Management** | External tools | MCO (in-cluster operator) |
| **Updates** | Manual, external | CVO (orchestrated, version-aware) |
| **Authentication** | External | Built-in OAuth, kubeadmin |
| **Routing** | Ingress controller | Router (HAProxy), Routes |
| **Registry** | External | Integrated, operator-managed |

OpenShift isn't just Kubernetes with addons. It's an **opinionated, integrated platform** where the operating system, cluster, and operators form a cohesive unit.

## Why is OpenShift More Complex?

### 1. Operating System Integration

Traditional Kubernetes:
```
Boot VM → Install OS → Configure OS → Install Kubernetes → Configure Kubernetes
```

OpenShift:
```
Boot with Ignition → OS + Kubernetes configured atomically → Operators take over
```

**RHCOS (Red Hat CoreOS)** is an immutable, minimal OS designed specifically for running containers:
- No package manager (`yum`/`dnf` don't work)
- Updates via `rpm-ostree` (atomic, rollback-able)
- Configured entirely at first boot via Ignition
- Changes after boot come through MachineConfigs

You can't SSH in and `apt install` things. This is intentional - it ensures nodes are reproducible.

### 2. The Bootstrap Pattern

Unlike `kubeadm init`, which initializes the control plane directly on the first master, OpenShift uses a **temporary bootstrap node**:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          PHASE 1: BOOTSTRAP                              │
│                                                                          │
│    Bootstrap Node              Master Nodes                              │
│    ┌─────────────┐             ┌─────────────┐                          │
│    │ etcd (1)    │             │  (waiting)  │                          │
│    │ API server  │   ─────►    │             │                          │
│    │ KCM + sched │             │             │                          │
│    └─────────────┘             └─────────────┘                          │
│                                                                          │
│    Bootstrap has the initial cluster. Masters boot and fetch config.    │
└─────────────────────────────────────────────────────────────────────────┘

                                    │
                                    ▼

┌─────────────────────────────────────────────────────────────────────────┐
│                          PHASE 2: PIVOT                                  │
│                                                                          │
│    Bootstrap Node              Master Nodes                              │
│    ┌─────────────┐             ┌─────────────┐                          │
│    │  (removed)  │   ◄─────    │ etcd (3)    │                          │
│    │             │             │ API server  │                          │
│    │             │             │ All operators│                          │
│    └─────────────┘             └─────────────┘                          │
│                                                                          │
│    Masters have taken over. Bootstrap is no longer needed.              │
└─────────────────────────────────────────────────────────────────────────┘
```

**Why a separate bootstrap node?**

Chicken-and-egg problem:
- To join a Kubernetes cluster, a node needs credentials from the API server
- To have an API server, you need nodes running it
- Solution: temporary bootstrap provides the initial API server

The bootstrap node:
1. Boots with embedded credentials (no API server needed)
2. Starts single-node etcd + API server
3. Masters boot with their own ignition, join the cluster
5. etcd scales from 1 to 3 members
6. Control plane replicates to masters
7. Bootstrap becomes unnecessary and is removed

### 3. Operator-Driven Architecture

In vanilla Kubernetes, you deploy components with manifests. In OpenShift, **everything is an operator**:

```
┌────────────────────────────────────────────────────────────────┐
│                  Cluster Version Operator (CVO)                 │
│                                                                 │
│  Reads release image, applies operators in order, ensures      │
│  cluster matches desired version                                │
└────────────────────────────────────────────────────────────────┘
                              │
                              │ manages
                              ▼
    ┌──────────────────┬──────────────────┬──────────────────┐
    │                  │                  │                  │
    ▼                  ▼                  ▼                  ▼
┌────────┐       ┌────────┐        ┌────────┐        ┌────────┐
│  etcd  │       │  API   │        │  MCO   │        │  ...   │
│operator│       │operator│        │        │        │ (50+)  │
└────────┘       └────────┘        └────────┘        └────────┘
    │                 │                 │
    ▼                 ▼                 ▼
  etcd            API server        MachineConfigs
  members         deployment        node configs
```

Operators:
- **Render** manifests based on cluster configuration
- **Monitor** their resources continuously
- **Reconcile** when reality drifts from desired state
- **Report** status to CVO

You don't write API server manifests by hand - the `cluster-kube-apiserver-operator` does it. This encoding of operational knowledge is why OpenShift installation is more complex but operation is more automated.

### 4. The Release Image

OpenShift versions are defined by a **release image** - a container that contains:
- References to all component images (50+)
- Operator manifests
- Update graph metadata

```bash
# Inspect what's in a release
oc adm release info quay.io/openshift-release-dev/ocp-release:4.14.0-x86_64

# Extract component images
oc adm release info --image-for=etcd
oc adm release info --image-for=cluster-kube-apiserver-operator
```

This is why you need a `RELEASE_IMAGE` for installation - it defines the complete set of components.

## Key Concepts You Must Understand

### Ignition

Ignition is a declarative configuration language for first boot.

**What problem does it solve?**

Traditional approach:
1. Boot generic image
2. SSH in and configure
3. Run Ansible/Puppet/Chef
4. Hope nothing drifts

Ignition approach:
1. Boot with configuration baked in
2. Configuration applied at first boot (atomically)
3. System is ready when it boots
4. No post-boot configuration step

**Key characteristics:**
- JSON format (typically generated, not hand-written)
- Runs once, at first boot, before services start
- All-or-nothing (fails boot if config fails)
- Can partition disks, write files, create users, enable systemd units

**Example ignition snippet:**
```json
{
  "ignition": { "version": "3.2.0" },
  "storage": {
    "files": [{
      "path": "/etc/myconfig",
      "contents": { "source": "data:,hello%20world" },
      "mode": 420
    }]
  },
  "systemd": {
    "units": [{
      "name": "myservice.service",
      "enabled": true,
      "contents": "[Unit]\nDescription=My Service\n..."
    }]
  }
}
```

**Why not cloud-init?**

| Aspect | cloud-init | Ignition |
|--------|------------|----------|
| When runs | After boot, can run multiple times | First boot only, before services |
| Format | YAML | JSON |
| Disk config | Limited | Full disk partitioning |
| Atomicity | Can partially fail | All-or-nothing |
| Designed for | General Linux | Container-optimized OS |

### RHCOS (Red Hat CoreOS)

RHCOS is the OS OpenShift runs on. It's:
- **Immutable**: No package manager, no SSH configuration changes
- **Container-optimized**: Minimal footprint, designed to run containers
- **Atomic updates**: Via rpm-ostree, with rollback capability
- **Ignition-configured**: All configuration via ignition at first boot

After first boot, OS changes come through **MachineConfigs** applied by the MCO.

### Static Pods

Static pods are pods managed directly by kubelet, not the API server.

**Why do they exist?**

Chicken-and-egg again:
- API server runs as a pod
- Pods need an API server to be scheduled
- Solution: kubelet can run "static pods" from local manifests

Static pods:
- Defined in `/etc/kubernetes/manifests/`
- Kubelet watches this directory
- Created/deleted when files are added/removed
- No scheduler involved
- Used for bootstrap control plane components

During bootstrap:
```
kubelet reads /etc/kubernetes/manifests/
    ├── etcd-pod.yaml           → starts etcd
    ├── kube-apiserver-pod.yaml → starts API server
    ├── kube-controller-manager-pod.yaml
    └── kube-scheduler-pod.yaml
```

### The Pivot

The pivot is the transition from bootstrap to production:

1. Bootstrap has single-node control plane
2. Masters boot, join cluster, start their control plane pods
3. etcd membership expands from 1 to 3
4. API server becomes highly available across masters
5. Bootstrap control plane is no longer needed
6. Bootstrap node removed from load balancer

**When is pivot complete?**
- 3 etcd members healthy
- API servers running on all masters
- CVO running and operators deploying
- Bootstrap can be safely shut down

### CVO (Cluster Version Operator)

The CVO is the meta-operator that manages all other operators.

It:
1. Reads the release image
2. Extracts operator manifests
3. Applies them in dependency order
4. Monitors operator health
5. Reports cluster version status
6. Handles upgrades

```bash
# Check CVO status
oc get clusterversion

# See what operators CVO manages
oc get co
```

### MCO (Machine Config Operator)

The MCO manages OS-level configuration on nodes.

It:
1. Watches MachineConfig and MachineConfigPool resources
2. Calculates rendered config for each pool
3. Coordinates node updates (drain, update, reboot)
4. Takes over from Ignition after bootstrap

```bash
# See current machine configs
oc get machineconfigs

# See machine config pools
oc get machineconfigpools
```

**The handoff**: During bootstrap, Ignition configures nodes. After bootstrap, MCO manages ongoing configuration.

## The Bootstrap Timeline

Understanding timing helps debugging:

| Time | Event | What's Happening |
|------|-------|------------------|
| 0-2 min | **Boot** | RHCOS boots, Ignition runs, files written |
| 2-5 min | **Static Pods** | kubelet starts, reads manifests, starts etcd/apiserver |
| 5-10 min | **Manifests Applied** | bootkube.sh applies cluster resources |
| 10-15 min | **Masters Join** | Masters boot, kubelet + kube-proxy start, CSRs approved |
| 15-25 min | **Operators Deploy** | kube-proxy enables ClusterIP routing, CVO deploys operators on masters, etcd scales |
| 25-30 min | **Pivot** | Bootstrap control plane no longer primary |
| 30-45 min | **Convergence** | CVO deploying operators, operators becoming Available |
| 45-60 min | **Workers** | Workers join, CSRs approved, workloads schedulable |

## What You'll Build

By the end of this guide:

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Your OpenShift Cluster                        │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│    Bootstrap Node (temporary)                                        │
│    └── Used during installation, removed after pivot                 │
│                                                                      │
│    Master Nodes (x3)                                                 │
│    ├── etcd cluster (3 members, HA)                                  │
│    ├── kube-apiserver (3 replicas behind VIP)                        │
│    ├── kube-controller-manager (leader election)                     │
│    ├── kube-scheduler (leader election)                              │
│    └── All cluster operators                                         │
│                                                                      │
│    Worker Nodes (x2)                                                 │
│    └── Run your workloads                                            │
│                                                                      │
│    Infrastructure                                                    │
│    ├── DNS (api.cluster, *.apps.cluster)                             │
│    ├── HAProxy (load balancer for API and apps)                      │
│    └── HTTP server (serve ignition files)                            │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

## Prerequisites Knowledge

Before continuing, you should understand:

- [ ] **Kubernetes basics**: pods, deployments, services, namespaces
- [ ] **TLS/PKI**: certificates, CAs, certificate signing
- [ ] **systemd**: units, services, targets
- [ ] **Linux networking**: bridges, DNS, DHCP, load balancers
- [ ] **Containers**: images, registries, runtimes (CRI-O, containerd)

If any of these are unfamiliar, spend time learning them first. This guide assumes Kubernetes competency.

## Philosophy Recap

This guide exists because:

1. **`openshift-install` is a black box.** It does 1000 things. We do each one manually to understand them.

2. **Day 2 requires Day 1 knowledge.** When operators fail, when nodes won't join, when upgrades break - you need to understand how the cluster was built.

3. **Understanding beats automation.** Ansible can reinstall a cluster, but it can't debug why certificates expired or why etcd won't form quorum.

Every manifest is hand-written with explanations. No black-box operator containers — you understand every field because you wrote it, just like Kubernetes the Hard Way.

## What's Next

In [Stage 01](../01-prerequisites/README.md), we set up the required tools, accounts, and host machine.
