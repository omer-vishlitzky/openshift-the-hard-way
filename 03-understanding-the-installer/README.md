# Stage 03: Understanding What We're Building

Before we build anything, we need to understand the full picture. This stage is a map of the territory — it explains every concept you'll encounter in later stages.

## OpenShift vs Kubernetes: The 30-Second Version

Kubernetes gives you an API server, a scheduler, a controller manager, and etcd. You bring everything else: networking, storage, ingress, authentication, monitoring, node OS management.

OpenShift is Kubernetes plus ~50 operators that provide all of those things. The operators are deployed by a single meta-operator called CVO (Cluster Version Operator), which reads a "release image" containing all the operator manifests.

The entire OpenShift install process is:
1. Start the Kubernetes control plane (etcd, apiserver, kcm, scheduler)
2. Start CVO
3. CVO deploys everything else

That's it. Everything in this guide is in service of those three steps.

## install-config.yaml: The Single Source of Truth

Every OpenShift cluster starts with one file. The installer reads it, generates hundreds of manifests from it, and deletes it (it's consumed). Here's the full file:

```yaml
apiVersion: v1
baseDomain: example.com
metadata:
  name: ocp4
networking:
  networkType: OVNKubernetes
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  serviceNetwork:
  - 172.30.0.0/16
  machineNetwork:
  - cidr: 192.168.126.0/24
platform:
  none: {}
controlPlane:
  replicas: 3
compute:
- replicas: 2
pullSecret: '<your-pull-secret>'
sshKey: '<your-ssh-key>'
```

Let's break it down section by section.

```yaml
apiVersion: v1
baseDomain: example.com
metadata:
  name: ocp4
```

**baseDomain + metadata.name** form the cluster domain: `ocp4.example.com`. Every DNS record, every certificate SAN, every URL in the cluster derives from this. The API server lives at `api.ocp4.example.com:6443`. Apps live at `*.apps.ocp4.example.com`.

```yaml
networking:
  networkType: OVNKubernetes
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  serviceNetwork:
  - 172.30.0.0/16
  machineNetwork:
  - cidr: 192.168.126.0/24
```

Three separate networks, each with a different purpose:

**machineNetwork** (`192.168.126.0/24`) — the physical (or virtual) network your nodes are on. Their real IPs. This is the network you built in Stage 02.

**clusterNetwork** (`10.128.0.0/14`) — the overlay network for pods. Every pod gets an IP from this range. Nodes don't see these IPs on any physical interface — OVN-Kubernetes creates virtual tunnels between nodes. When pod A on node 1 sends a packet to pod B on node 2, OVN wraps it in a Geneve tunnel header, sends it over the machine network, and unwraps it on the other side. The pods don't know any of this — they just see their own IP. `hostPrefix: 23` controls how many pod IPs each node gets.

**serviceNetwork** (`172.30.0.0/16`) — virtual IPs for Services. When you create a Kubernetes Service, it gets a ClusterIP from this range (e.g., `172.30.0.1` for the `kubernetes` service). These IPs don't exist on any interface either — kube-proxy (or OVN) programs iptables rules to translate them to real pod IPs.

```yaml
platform:
  none: {}
```

**platform** tells the installer what infrastructure you're running on. `none` means "I'm managing my own infrastructure" — no cloud provider integration, no automatic load balancers, no machine provisioning. Other options: `aws`, `gcp`, `azure`, `vsphere`, `baremetal`. The platform choice affects which operators are deployed and how they behave (e.g., `baremetal` platform deploys keepalived and HAProxy for VIP management, `aws` provisions NLBs).

```yaml
controlPlane:
  replicas: 3
compute:
- replicas: 2
```

**replicas** determine cluster topology. 3 control plane nodes = HighlyAvailable. 1 = SingleNode (SNO). This affects etcd quorum, operator expectations, and scheduling policies.

## What the Installer Generates

The installer takes this single file and produces hundreds of artifacts. Here's what they are and why each exists.

### OpenShift Config CRs (config.openshift.io/v1)

OpenShift has its own configuration API. These are Custom Resources that operators watch to know how to configure themselves. Think of them as the cluster's control knobs — each one configures a different aspect of the cluster.

The installer generates these from `install-config.yaml`:

#### Infrastructure CR

```yaml
apiVersion: config.openshift.io/v1
kind: Infrastructure
metadata:
  name: cluster
spec:
  platformSpec:
    type: None
status:
  apiServerURL: https://api.ocp4.example.com:6443
  apiServerInternalURL: https://api-int.ocp4.example.com:6443
  infrastructureName: ocp4-abc123
  platform: None
  controlPlaneTopology: HighlyAvailable
  infrastructureTopology: HighlyAvailable
```

**What it does**: Tells every operator about the cluster's infrastructure. "What platform am I on? Where's the API server? What's my cluster ID? Am I HA or single-node?"

**Who reads it**: Almost every operator. The network operator uses it to decide whether to deploy keepalived. The machine-config-operator uses it to determine platform-specific node configurations. The ingress operator uses it to decide how to expose routes.

**Why it matters**: If `controlPlaneTopology` is wrong, operators make wrong assumptions about scheduling. If `apiServerURL` is wrong, nothing can find the API server.

#### Network CR

```yaml
apiVersion: config.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  serviceNetwork:
  - 172.30.0.0/16
  networkType: OVNKubernetes
```

**What it does**: Tells the network operator what CIDRs to use and which network plugin to deploy.

**Who reads it**: The cluster-network-operator. It reads this CR and deploys OVN-Kubernetes (or OpenShiftSDN) with the specified CIDRs.

**Why it matters**: The network operator won't start without this. It needs to know the CIDRs before it can configure OVN. Wrong CIDRs = pods can't communicate.

There's also a separate `operator.openshift.io/v1 Network` CR that the network operator uses for its operational config (as opposed to the cluster-level config above). Both must exist.

#### DNS CR

```yaml
apiVersion: config.openshift.io/v1
kind: DNS
metadata:
  name: cluster
spec:
  baseDomain: example.com
```

**What it does**: Tells the DNS operator what base domain the cluster uses.

**Who reads it**: The cluster-dns-operator, which deploys CoreDNS pods to handle in-cluster DNS resolution.

#### Proxy CR

```yaml
apiVersion: config.openshift.io/v1
kind: Proxy
metadata:
  name: cluster
spec: {}
```

**What it does**: Configures HTTP/HTTPS proxy settings for the cluster. Empty spec means no proxy.

**Who reads it**: Every operator that makes outbound HTTP requests. MCO bakes proxy settings into node configuration.

#### FeatureGate CR

```yaml
apiVersion: config.openshift.io/v1
kind: FeatureGate
metadata:
  name: cluster
spec:
  featureSet: ""
```

**What it does**: Controls which OpenShift features are enabled. Empty string means the default feature set.

**Who reads it**: CVO reads it at startup. If this CR doesn't exist or doesn't match what CVO expects, CVO shuts down thinking the feature set changed mid-upgrade.

### cluster-config-v1 ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-config-v1
  namespace: kube-system
data:
  install-config: |
    <the install-config.yaml content>
```

**What it does**: Preserves the install-config so operators can reference it. The network operator reads this to configure OVN. Without it: `configmaps cluster-config-v1 not found` and the network operator can't start.

### Certificates (PKI)

The installer generates ~20 certificates and keys:

| Certificate | Purpose |
|------------|---------|
| Root CA | Trust anchor for everything |
| etcd CA + certs | etcd peer and client communication |
| Kubernetes CA + certs | API server, kubelet, controller-manager |
| Front-proxy CA + cert | API server → extension APIs (e.g., metrics-server) |
| Service account keypair | Signing and verifying ServiceAccount tokens |
| Admin cert | Cluster admin client certificate |

Every component authenticates via mTLS (mutual TLS). The API server presents its cert to clients, clients present their certs to the API server. etcd only accepts connections from certs signed by the etcd CA. This is why getting certificates right is critical — a wrong SAN or missing CA causes cryptic TLS handshake failures.

### Kubeconfigs

A kubeconfig is a YAML file that says "connect to this API server, authenticate with this certificate, and trust this CA." The installer generates several:

| Kubeconfig | User Identity | Purpose |
|-----------|--------------|---------|
| admin.kubeconfig | system:admin | Full cluster admin access |
| kubelet-bootstrap.kubeconfig | system:bootstrapper | Kubelet uses this to request a real certificate |
| controller-manager.kubeconfig | system:kube-controller-manager | KCM connecting to API server |
| scheduler.kubeconfig | system:kube-scheduler | Scheduler connecting to API server |
| localhost.kubeconfig | system:admin | Connects to API server at 127.0.0.1 (for bootstrap) |

### Static Pod Manifests

The control plane runs as static pods. Normal pods are created via the API server, but you can't use the API server to start the API server — chicken-and-egg. Static pods solve this: kubelet watches a directory (`/etc/kubernetes/manifests/`) and starts any pod YAML it finds there, no API server involved. The installer generates:

- **etcd** — the key-value store that holds ALL cluster state
- **kube-apiserver** — the REST API everything talks to
- **kube-controller-manager** — runs reconciliation loops (desired state → actual state)
- **kube-scheduler** — decides which node runs each pod

These are standard Kubernetes components, same as standard Kubernetes. The difference: standard Kubernetes runs them as systemd services, OpenShift runs them as containers (because RHCOS is immutable — you can't install binaries).

### Ignition Configs

The installer produces three ignition files:

**bootstrap.ign** (~280KB) — contains EVERYTHING: all certs, all kubeconfigs, all static pod manifests, bootkube.sh, cluster manifests. The bootstrap node is self-contained.

**master.ign** (~1.7KB) — just a pointer: `"source": "https://api-int:22623/config/master"`. At boot, RHCOS fetches the real config from the Machine Config Server (MCS) running on the bootstrap node. The real config contains MCO-rendered ignition with all the OS-level configuration (OVS bridges, kubelet.service, etc.).

**worker.ign** (~1.7KB) — same pattern, fetches from MCS at `/config/worker`.

In KTHW's spirit, we skip MCS. We run MCO's render on the host to produce the full ignition, then give each node its complete ignition file directly via `coreos-installer`. No MCS running, no fetch at boot.

## The Bootstrap Flow

### 1. Bootstrap node boots

The user boots the bootstrap VM from the RHCOS live ISO. RHCOS (Red Hat Enterprise Linux CoreOS) is an immutable OS image that ships with kubelet, CRI-O, and all the binaries pre-installed — you can't install new packages, everything is already there.

During installation, `coreos-installer` writes RHCOS to disk and embeds the ignition config. On first boot, Ignition runs before anything else and writes all the files from the ignition config to disk: certificates, kubeconfigs, static pod manifests, bootkube.sh, cluster manifests. These files don't come from RHCOS — they come from the ignition config we built.

Once Ignition finishes, kubelet starts (it's a systemd service baked into RHCOS). Kubelet watches `/etc/kubernetes/manifests/` and starts the static pods that Ignition placed there: etcd, then the API server (which connects to etcd), then KCM and scheduler (which connect to the API server).

### 2. bootkube.sh runs

bootkube.sh is a shell script embedded in the bootstrap ignition config. It runs as a systemd unit after kubelet starts.

It waits for etcd and the API server to become healthy, then applies the cluster manifests to the API server — these are the config CRs we covered above (Infrastructure, Network, DNS, FeatureGate, etc.), plus namespaces, RBAC rules, and CRDs that define the OpenShift API types.

CVO also starts as a static pod on the bootstrap node. It reads the [release image](../04-release-image/README.md) (a container that contains manifests for all 50+ operators) and begins deploying them to the API server.

### 3. Masters boot

Same process as bootstrap: boot from RHCOS ISO, install with ignition, reboot. In a standard installation, the master ignition is a tiny pointer that fetches the real config from MCS on the bootstrap node. In our approach, each master gets a complete ignition file directly.

When kubelet starts on a master, it needs to register itself as a node with the API server. But it doesn't have a certificate yet — it only has a bootstrap kubeconfig with a temporary identity. So kubelet sends a **CSR (Certificate Signing Request)** to the API server: "I'm master-0, please give me a certificate so I can identify myself."

Someone needs to approve that CSR. In a standard OpenShift installation, the `machine-approver` operator handles this automatically. In our approach, we approve CSRs manually — you run `oc certificate approve <csr-name>`. Once approved, the API server signs a certificate for the kubelet, and the node becomes Ready.

### 4. Operators converge

With masters registered, operators start doing their work:

- **etcd-operator** scales etcd from 1 member (bootstrap) to 3 members (one per master)
- **kube-apiserver-operator** deploys API server instances on each master
- **network-operator** deploys OVN-Kubernetes (the pod network)
- **ingress-operator** deploys routers for incoming traffic
- 50+ more operators deploying their components

### 5. Bootstrap complete

Once the control plane is running on all 3 masters, the bootstrap node is no longer needed. Remove the bootstrap server from the HAProxy config and shut it down.

### 6. Workers boot

Same process as masters — boot, install, register, approve CSRs. Workers get the worker role instead of master, and operators schedule workloads on them (ingress routers, monitoring, application workloads).

## The Real bootkube.sh vs Ours

The real `bootkube.sh` (~656 lines) uses **operator render commands** to generate manifests. Each operator has a `render` subcommand that produces version-appropriate manifests:

```bash
# Real bootkube.sh runs containers like:
podman run ${KUBE_APISERVER_OPERATOR_IMAGE} render --asset-input-dir=...
podman run ${ETCD_OPERATOR_IMAGE} render --asset-input-dir=...
podman run ${MACHINE_CONFIG_OPERATOR_IMAGE} bootstrap --dest-dir=...
```

This is how the real installer ensures manifests match the OpenShift version — operators generate their own manifests.

Our approach: we **hand-write** the control plane manifests (etcd, apiserver, kcm, scheduler) because that's where the learning is. We use **MCO render** for node OS configuration because typing 1100 lines of OVS bridge setup teaches nothing. And we let **CVO deploy** everything else (50+ operators).

```
What we hand-write (understand every flag):
  etcd, apiserver, kcm, scheduler, CVO, RBAC, cluster CRs

What we render via MCO (OS plumbing, no learning value):
  kubelet.service, OVS bridges, SELinux, CRI-O, 30+ files

What CVO deploys (too many to hand-write):
  50+ operators: networking, ingress, monitoring, console, etc.
```

## The Operator Pattern

OpenShift uses the operator pattern for everything. An operator is a controller that:
1. Watches a Custom Resource (CR) for desired state
2. Reconciles the cluster toward that state
3. Reports its status back to the CR

Example: the cluster-network-operator watches the `Network` CR. When it sees `networkType: OVNKubernetes`, it deploys OVN pods, configures routing, sets up the overlay network. It reports progress to `ClusterOperator/network`.

CVO watches ALL operators via `ClusterOperator` resources. If any operator reports Degraded, CVO reports the cluster as degraded.

This is why we need all those config CRs before CVO starts — operators immediately try to read their configuration CRs. Missing CR = operator crash = CVO reports degraded.

## What's Next

In [Stage 04](../04-release-image/README.md), we extract component images from the OpenShift release image and run MCO to render node configuration.
