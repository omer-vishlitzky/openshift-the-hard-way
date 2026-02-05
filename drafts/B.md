# OpenShift Installation Deep Dive: From Ignition to Running Cluster

## Document Purpose

This document explains what *actually happens* when you install an OpenShift cluster. It covers the foundational concepts (CoreOS, Ignition, bootstrap), the different installation methods (IPI, UPI, Agent-based, Assisted), and goes deep into the Assisted Installer flow specifically.

By the end, you should understand what every component does, why it exists, and how the pieces fit together.

---

# Part 1: Foundational Concepts

Before understanding any installation method, you need to understand what makes OpenShift fundamentally different from vanilla Kubernetes, and the primitives that all installation methods rely on.

## 1.1 Red Hat CoreOS (RHCOS)

### What It Is

RHCOS is an immutable, container-optimized Linux distribution. It's not "Linux with some packages" — it's a fundamentally different operational model.

**Key characteristics:**

- **Immutable root filesystem**: The OS is delivered as an OSTree image. You don't `yum install` packages. The root filesystem is read-only (with some exceptions for `/etc` and `/var`).
- **Atomic updates**: OS updates are delivered as complete images. You boot into the new image or roll back to the old one. No partial update states.
- **Ignition-configured**: The OS is configured at first boot via Ignition. After that, the Machine Config Operator manages configuration.
- **Container-native**: The OS is designed to run containers. Kubernetes components (kubelet, CRI-O) are part of the base image.

### The OSTree Model

RHCOS uses rpm-ostree, which combines RPM packaging with OSTree:

```
/
├── ostree/          # OSTree repository containing OS images
│   ├── repo/        # The actual image store
│   └── deploy/      # Currently deployed images
├── etc/             # Writable configuration (3-way merge on upgrades)
├── var/             # Writable persistent data
├── usr/             # Read-only (from OSTree image)
├── bin -> usr/bin   # Symlinks into read-only /usr
└── sbin -> usr/sbin
```

When you "upgrade" the OS:
1. A new OSTree commit is downloaded
2. A new deployment is staged alongside the current one
3. The node reboots into the new deployment
4. If something fails, you can roll back to the previous deployment

This is why the Machine Config Operator *reboots nodes* to apply changes — it's not patching files, it's potentially switching to a different OS image or applying Ignition-style changes that require a fresh boot.

### What's Actually Running on a CoreOS Node

Out of the box, RHCOS has:

- **systemd**: Init system and service manager
- **CRI-O**: Container runtime (not Docker)
- **kubelet**: Runs as a systemd service
- **Ignition**: Runs once at first boot to configure the system
- **rpm-ostree**: For OS image management
- **podman**: For running non-Kubernetes containers (used during bootstrap)
- **NetworkManager**: Network configuration
- **chrony**: Time synchronization

The kubelet is pre-installed but not pre-configured. Ignition provides the kubelet configuration, certificates, and tells it how to join the cluster.

## 1.2 Ignition

### What Ignition Is

Ignition is a provisioning utility that runs exactly once, at first boot, before the system is fully operational. It configures:

- Disk partitions and filesystems
- Files and directories
- systemd units
- Users and groups
- Network configuration (via NetworkManager keyfiles)

Ignition runs in the initramfs, before the real root filesystem is even mounted. This is important — it means Ignition can partition disks and set up the root filesystem itself.

### Ignition Config Structure

An Ignition config is JSON (with a spec version). Here's a simplified example:

```json
{
  "ignition": {
    "version": "3.2.0"
  },
  "storage": {
    "files": [
      {
        "path": "/etc/hostname",
        "contents": {
          "source": "data:,my-hostname"
        },
        "mode": 420
      },
      {
        "path": "/etc/kubernetes/kubelet.conf",
        "contents": {
          "source": "data:text/plain;base64,BASE64_ENCODED_CONTENT"
        },
        "mode": 420
      }
    ],
    "filesystems": [
      {
        "device": "/dev/disk/by-partlabel/root",
        "format": "xfs",
        "path": "/",
        "wipeFilesystem": true
      }
    ]
  },
  "systemd": {
    "units": [
      {
        "name": "kubelet.service",
        "enabled": true,
        "contents": "[Unit]\nDescription=Kubelet\n..."
      }
    ]
  },
  "passwd": {
    "users": [
      {
        "name": "core",
        "sshAuthorizedKeys": ["ssh-rsa AAAA..."]
      }
    ]
  }
}
```

### Why Ignition Instead of Cloud-Init?

Cloud-init is "run these scripts at boot." Ignition is "declaratively configure this machine exactly once."

Key differences:
- Ignition runs **before** systemd, in the initramfs
- Ignition is **declarative**, not imperative (no scripts, just state)
- Ignition runs **exactly once** — it configures the machine, then it's done
- Ignition can handle **disk configuration** that cloud-init can't

For OpenShift, this matters because:
1. You want deterministic machine configuration (not "run this script and hope")
2. You need to configure things before the OS is fully booted
3. The configuration needs to be auditable and reproducible

### Ignition Config Merging and Pointers

Ignition configs can include pointers to other configs via `config.merge` or `config.replace`:

```json
{
  "ignition": {
    "version": "3.2.0",
    "config": {
      "merge": [
        {
          "source": "https://api.example.com/ignition/worker"
        }
      ]
    }
  }
}
```

This is how OpenShift delivers machine configuration:
1. The ISO/PXE contains a "pointer" Ignition config
2. That config fetches the real config from the Machine Config Server
3. The real config contains everything needed to join the cluster

## 1.3 The Machine Config Operator (MCO)

### What It Does

The MCO manages the operating system configuration of all nodes in the cluster. It's responsible for:

- Applying OS-level configuration changes
- Rolling out OS updates
- Managing certificates
- Handling kernel arguments, kernel modules
- Applying systemd units
- Managing files on disk

### MachineConfig and MachineConfigPool

**MachineConfig** is a CRD that represents a specific OS configuration:

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-worker-custom-config
  labels:
    machineconfiguration.openshift.io/role: worker
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
        - path: /etc/my-custom-file
          contents:
            source: data:,hello
          mode: 0644
    systemd:
      units:
        - name: my-custom-service.service
          enabled: true
          contents: |
            [Unit]
            Description=My Custom Service
            [Service]
            ExecStart=/usr/bin/true
            [Install]
            WantedBy=multi-user.target
  kernelArguments:
    - nosmt
```

**MachineConfigPool** groups nodes that should receive the same configuration:

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfigPool
metadata:
  name: worker
spec:
  machineConfigSelector:
    matchLabels:
      machineconfiguration.openshift.io/role: worker
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/worker: ""
```

The MCO:
1. Watches MachineConfigs for the pools
2. Renders all matching MachineConfigs into a single "rendered" config
3. Compares nodes' current config to the rendered config
4. Cordons, drains, and reboots nodes that need updates

### The Machine Config Server

During installation, nodes need to get their initial configuration. They can't query the Kubernetes API yet (chicken-and-egg). The Machine Config Server solves this:

- Runs on control plane nodes (and bootstrap)
- Serves Ignition configs over HTTPS on port 22623
- Serves different configs based on the client certificate
- The pointer Ignition config in the ISO/PXE tells nodes where to fetch their real config

URL pattern: `https://api-int.<cluster>.<domain>:22623/config/<role>`

The Machine Config Server inspects the client certificate to determine the node's role and returns the appropriate rendered Ignition config.

## 1.4 The Release Image and Cluster Version Operator

### What's in a Release Image?

An OpenShift release is a single container image that contains:

- References to all component images (operators, operands, etc.)
- Metadata about the release (version, upgrade paths)
- The manifests for all core operators

The release image is *not* a bundle of tarballs — it's metadata. When you do `oc adm release info quay.io/openshift-release-dev/ocp-release:4.14.0-x86_64`, you're inspecting this metadata.

Example content:

```
$ oc adm release info quay.io/openshift-release-dev/ocp-release:4.14.0-x86_64 --commits
Name:      4.14.0
Digest:    sha256:...
Created:   2023-10-27T12:34:56Z

Images:
  NAME                                          DIGEST
  aws-ebs-csi-driver                           sha256:...
  aws-ebs-csi-driver-operator                  sha256:...
  ...
  cluster-version-operator                      sha256:...
  etcd                                          sha256:...
  machine-config-operator                       sha256:...
  ...
```

### Cluster Version Operator (CVO)

The CVO is the "God operator" — it manages all other operators. Its job:

1. Read the release image metadata
2. Apply the manifests for all operators from the release image
3. Monitor operator health
4. Coordinate upgrades

The CVO applies manifests in order, respecting dependencies. It understands that some things need to exist before others.

During installation:
- The CVO is one of the first things that runs
- It reads the release image
- It creates all the operators and their operands
- It monitors progress

The ClusterVersion resource represents the cluster's current and desired version:

```yaml
apiVersion: config.openshift.io/v1
kind: ClusterVersion
metadata:
  name: version
spec:
  channel: stable-4.14
  clusterID: <uuid>
  desiredUpdate:
    version: 4.14.1
    image: quay.io/openshift-release-dev/ocp-release:4.14.1-x86_64
status:
  availableUpdates: [...]
  conditions: [...]
  desired:
    version: 4.14.0
  history:
    - version: 4.14.0
      state: Completed
```

### How CVO Applies Manifests

The release image contains a directory of manifests, ordered by numeric prefix:

```
/release-manifests/
  0000_00_cluster-version-operator_...
  0000_03_authorization-openshift_...
  0000_10_config-operator_...
  0000_50_machine-config_...
  ...
```

The CVO applies these in order. Lower numbers go first. This ensures dependencies are met (can't create a Deployment before the namespace exists).

Each manifest can also have annotations that tell the CVO:
- Whether to wait for the resource to be "ready"
- Whether the resource should be garbage collected if removed from the release
- Capability gates (feature flags)

## 1.5 Bootstrap: The Chicken and Egg Problem

### The Core Problem

To have a Kubernetes cluster, you need:
- An API server (runs in a pod)
- etcd (runs in a pod)
- Controllers (run in pods)

To have pods, you need:
- A scheduler
- A controller-manager
- An API server to submit them to

This is circular. You can't start a cluster from nothing.

### The Bootstrap Node Solution

OpenShift solves this with a temporary bootstrap node that:

1. Runs a temporary control plane (API server, etcd, controllers)
2. These run as *static pods* or *podman containers*, not through Kubernetes
3. The real control plane nodes boot and join this temporary cluster
4. The real control plane takes over
5. The bootstrap node is destroyed

The bootstrap node is disposable infrastructure. Its only job is to get the real cluster running.

### What Runs on Bootstrap

The bootstrap node runs (via podman, not Kubernetes):

- **etcd**: Single-node etcd (will be replaced by real etcd)
- **kube-apiserver**: Temporary API server
- **machine-config-server**: Serves Ignition configs to other nodes
- **cluster-bootstrap**: Orchestrates the bootstrap process

These are started by systemd units that Ignition configures.

### Bootstrap Process Overview

1. Bootstrap node boots from ISO/PXE
2. Ignition runs, configures the node, starts services
3. Bootstrap etcd and API server start
4. Bootstrap cluster-bootstrap starts applying manifests
5. Control plane nodes boot, fetch Ignition from bootstrap's MCS
6. Control plane nodes join the cluster
7. etcd operators migrates from bootstrap etcd to control plane etcd
8. Control plane components move from bootstrap to control plane
9. Bootstrap complete signal
10. Bootstrap node can be removed

We'll go deeper into this in Part 2.

## 1.6 etcd in OpenShift

### Why etcd Matters

etcd is the brain of Kubernetes. Every piece of cluster state lives there:
- All resources (Pods, Deployments, Secrets, etc.)
- All configuration
- All operator state

If etcd is unhealthy, your cluster is unhealthy. If etcd is lost, your cluster is lost.

### etcd Quorum

etcd uses Raft consensus. For a write to be committed, a majority of members must acknowledge it.

- 1 member: Quorum = 1 (no fault tolerance)
- 3 members: Quorum = 2 (can lose 1 member)
- 5 members: Quorum = 3 (can lose 2 members)

This is why OpenShift typically runs 3 control plane nodes — it gives you fault tolerance.

### etcd in OpenShift vs. Vanilla Kubernetes

In vanilla Kubernetes, you might run etcd:
- Externally (separate VMs/bare-metal)
- Statically (static pod manifests)
- Manually managed

In OpenShift, etcd is:
- Managed by the **etcd operator**
- Runs as static pods on control plane nodes
- Has automatic backup, restore, and scaling capabilities
- Certificate rotation is handled automatically

### The etcd Operator

The etcd operator manages:
- etcd cluster membership
- Scaling (adding/removing members)
- Certificate management
- Backups (when configured)
- Health monitoring

During installation, the etcd operator is responsible for transitioning from the bootstrap single-node etcd to the production multi-node etcd cluster.

## 1.7 Certificates and PKI

### Why So Many Certificates?

OpenShift has *a lot* of certificates. Every component needs to:
- Prove its identity (client certs)
- Verify other components' identities (CA certs)
- Encrypt traffic (TLS)

Components include:
- API server (serving cert, client certs for etcd, kubelet, etc.)
- etcd (peer certs, server certs, client certs)
- kubelet (server cert, client cert for API)
- All operators
- Ingress controller
- Service mesh (if present)

### Certificate Hierarchy

OpenShift maintains several CA hierarchies:

```
Root CAs
├── kube-apiserver-serving-ca
│   └── kube-apiserver serving certs
├── kube-apiserver-client-ca
│   └── Client certs for API server authentication
├── kubelet-ca
│   └── kubelet serving certs
├── etcd-ca
│   ├── etcd peer certs
│   └── etcd client certs
├── service-ca
│   └── Serving certs for services (via service-ca-operator)
├── ingress-ca
│   └── Ingress controller certs
└── machine-config-server-ca
    └── MCS serving cert
```

### Certificate Rotation

All certificates in OpenShift have expiration dates. The various operators handle rotation:
- kubelet certs: kubelet auto-rotates
- API server certs: cluster-kube-apiserver-operator
- etcd certs: cluster-etcd-operator
- Service certs: service-ca-operator

This happens automatically. No human intervention needed (usually).

### Certificates During Installation

One of the trickiest parts of installation is certificate bootstrapping:

1. The installer generates initial CAs and certificates
2. These are embedded in the Ignition configs
3. Nodes boot with these initial certs
4. Operators take over and manage certificate lifecycle

The initial certificates have short lifetimes (24 hours for some). This is intentional — it forces the cluster to prove it can rotate certificates early.

## 1.8 OpenShift API Extensions

### Beyond Vanilla Kubernetes APIs

OpenShift adds many Custom Resource Definitions:

**config.openshift.io**: Cluster-wide configuration
- ClusterVersion (cluster version and upgrades)
- Infrastructure (cloud provider info)
- Network (cluster networking config)
- OAuth (authentication config)
- Ingress (ingress configuration)
- Image (image registry config)
- etc.

**operator.openshift.io**: Operator configuration
- Operator-specific configs (Authentication, Console, DNS, etc.)

**machineconfiguration.openshift.io**: OS configuration
- MachineConfig
- MachineConfigPool
- KubeletConfig
- ContainerRuntimeConfig

**machine.openshift.io**: Machine management (IPI)
- Machine
- MachineSet
- MachineHealthCheck

**Security**:
- SecurityContextConstraints (SCCs) — more flexible than PSA

### Routes vs. Ingress

OpenShift has Routes, which predate Kubernetes Ingress:

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: my-route
spec:
  host: myapp.apps.cluster.example.com
  to:
    kind: Service
    name: my-service
  tls:
    termination: edge
```

Routes support:
- Automatic TLS certificate provisioning
- More routing options (blue-green, A/B)
- Passthrough TLS
- Re-encrypt TLS

OpenShift also supports standard Ingress resources (translated to Routes internally).

---

# Part 2: Installation Methods Overview

OpenShift has several installation methods, each suited to different environments and requirements. Understanding the differences helps you understand what Assisted Installer is abstracting.

## 2.1 IPI: Installer Provisioned Infrastructure

### What It Is

IPI is the "fully automated" installation. The installer:
- Provisions cloud/virtualization infrastructure (VMs, load balancers, DNS)
- Creates the cluster on that infrastructure
- Manages the infrastructure lifecycle (scaling, etc.)

Supported platforms: AWS, Azure, GCP, OpenStack, vSphere, bare-metal (via Metal³)

### How It Works

1. You create an `install-config.yaml`:
   ```yaml
   apiVersion: v1
   baseDomain: example.com
   metadata:
     name: my-cluster
   platform:
     aws:
       region: us-east-1
   pullSecret: '...'
   sshKey: 'ssh-rsa ...'
   ```

2. Run `openshift-install create cluster`

3. The installer:
   - Generates all manifests and Ignition configs
   - Provisions infrastructure (Terraform under the hood)
   - Creates a bootstrap instance
   - Creates control plane instances
   - Waits for bootstrap to complete
   - Destroys bootstrap instance
   - Creates worker instances
   - Waits for cluster operators to be ready

### Machine API Integration

In IPI, OpenShift can manage infrastructure through the Machine API:

- **Machine**: Represents a single node (VM, bare-metal host)
- **MachineSet**: Like a ReplicaSet for Machines
- **MachineDeployment**: Like a Deployment for Machines (not commonly used)

The Machine API controllers talk to the cloud provider API to create/delete VMs.

When you scale workers:
```bash
oc scale machineset my-cluster-worker-a --replicas=5
```

The Machine API controller creates new VMs, they boot with CoreOS, fetch Ignition, and join the cluster.

### What IPI Handles That Others Don't

- Infrastructure provisioning
- DNS record creation (api., api-int., *.apps.)
- Load balancer creation
- Security groups/firewall rules
- Storage provisioner setup (CSI drivers for the platform)

## 2.2 UPI: User Provisioned Infrastructure

### What It Is

UPI means "you provision the infrastructure, the installer just creates the cluster config."

You're responsible for:
- Creating VMs/bare-metal hosts
- Configuring DNS
- Setting up load balancers
- Network configuration
- Booting machines with the right Ignition configs

### How It Works

1. Create `install-config.yaml` (with `platform: none` or specific platform without provisioning)

2. Run `openshift-install create manifests` — generates Kubernetes manifests

3. Run `openshift-install create ignition-configs` — generates:
   - `bootstrap.ign` — for the bootstrap node
   - `master.ign` — for control plane nodes
   - `worker.ign` — for worker nodes

4. You provision infrastructure:
   - Set up DNS (api., api-int., *.apps.)
   - Set up load balancers
   - Create VMs or prepare bare-metal hosts

5. Boot machines with appropriate Ignition:
   - One bootstrap node with `bootstrap.ign`
   - Control plane nodes with `master.ign`
   - Worker nodes with `worker.ign`

6. Run `openshift-install wait-for bootstrap-complete`

7. Remove bootstrap node, point load balancer to control plane only

8. Run `openshift-install wait-for install-complete`

9. Approve worker CSRs

### The Ignition Configs in Detail

**bootstrap.ign** is large (tens of MB). It contains:
- Full configuration for the bootstrap node
- All the container images needed for bootstrap (embedded or URLs)
- Manifests for the initial cluster
- CAs and initial certificates

**master.ign and worker.ign** are small (a few KB). They contain:
- A pointer to fetch the real config from the Machine Config Server
- Certificate for authenticating to the MCS
- The MCS URL

Example `master.ign`:
```json
{
  "ignition": {
    "version": "3.2.0",
    "config": {
      "merge": [{
        "source": "https://api-int.my-cluster.example.com:22623/config/master"
      }]
    },
    "security": {
      "tls": {
        "certificateAuthorities": [{
          "source": "data:text/plain;base64,<BASE64_CA_CERT>"
        }]
      }
    }
  }
}
```

The node boots, Ignition runs, fetches the real config from MCS, applies it, and the node joins the cluster.

### When to Use UPI

- Environments where the installer can't provision infrastructure
- Strict security requirements (no cloud API access from installer)
- Custom infrastructure (unusual network topologies, air-gapped, etc.)
- Bare-metal without Metal³/BMC access
- Integration with existing provisioning systems

## 2.3 Agent-Based Installer

### What It Is

The agent-based installer is a newer method (4.12+) that:
- Generates a bootable ISO with an embedded agent
- The agent performs discovery and installation
- Works disconnected (air-gapped)
- No external service dependency

It's essentially "UPI with a smart ISO."

### How It Works

1. Create `install-config.yaml` and `agent-config.yaml`:
   ```yaml
   # agent-config.yaml
   apiVersion: v1alpha1
   kind: AgentConfig
   metadata:
     name: my-cluster
   rendezvousIP: 192.168.1.100  # Which host will be bootstrap
   hosts:
     - hostname: master-0
       role: master
       interfaces:
         - name: eno1
           macAddress: 00:11:22:33:44:55
       networkConfig:
         interfaces:
           - name: eno1
             type: ethernet
             state: up
             ipv4:
               enabled: true
               address:
                 - ip: 192.168.1.100
                   prefix-length: 24
   ```

2. Run `openshift-install agent create image`

3. This generates a single bootable ISO (`agent.x86_64.iso`)

4. Boot all machines with this ISO

5. The machine with the `rendezvousIP` becomes the bootstrap node

6. Other machines discover and register with it

7. Installation proceeds similarly to IPI/UPI

### Key Difference from Assisted

The agent-based installer:
- Generates a single ISO for all nodes (configuration baked in)
- Runs entirely locally (no external service)
- Configuration is determined upfront
- No approval workflow (all hosts pre-defined)

Assisted Installer:
- ISO is generic (discovery image)
- Central service coordinates installation
- Discovery-driven (learn about hosts, then configure)
- Approval workflow (inspect hosts, then install)

## 2.4 Assisted Installer (Preview)

This is the focus of Part 3, but in summary:

### What It Is

A service-based installer that:
- Provides a REST API for managing installations
- Generates discovery ISOs
- Discovers hosts automatically
- Validates hardware and network requirements
- Orchestrates installation with approval workflow

Available as:
- SaaS at console.redhat.com (cloud.redhat.com)
- On-premise via the Infrastructure Operator (ACM integration)

### Why It Exists

Assisted fills gaps that other methods don't:
- **UPI** requires manual coordination and is error-prone
- **IPI** requires cloud provider integration
- **Agent-based** requires configuration upfront

Assisted provides:
- Discovery workflow (boot first, configure later)
- Validation (check requirements before installing)
- GUI and API
- Integration with ACM for fleet management
- Support for edge/remote sites

---

# Part 3: Assisted Installer Deep Dive

Now we get to the meat: how Assisted Installer actually works, at every layer.

## 3.1 Architecture Overview

### Components

The Assisted Installer ecosystem consists of:

1. **assisted-service**: The main API server and controller
   - REST API for all operations
   - Cluster and host state management
   - Ignition config generation
   - Installation orchestration
   - Validations

2. **assisted-image-service**: ISO generation service
   - Generates and caches discovery ISOs
   - Supports different CPU architectures
   - Handles customization (SSH keys, proxy, static IPs)

3. **agent**: Runs on discovered hosts
   - Discovery (hardware, network inventory)
   - Connectivity checks
   - Installation execution
   - Communicates with assisted-service

4. **Infrastructure Operator**: Kubernetes operator for on-premise deployment
   - Manages AgentServiceConfig (service configuration)
   - Watches InfraEnv and ClusterDeployment CRDs
   - Reconciles CRDs into assisted-service objects
   - Creates Agent CRs for discovered hosts

5. **Database**: PostgreSQL for persistent state

6. **Object Storage**: S3-compatible storage for:
   - Generated ISOs
   - Cluster manifests
   - Installation logs

### Deployment Modes

**SaaS (console.redhat.com)**:
- Red Hat operates the service
- You just use the API/UI
- ISOs are hosted by Red Hat
- Connected to Red Hat for telemetry/support

**On-premise (via Infrastructure Operator)**:
- Deploy assisted-service in your own cluster (typically ACM hub)
- You manage the infrastructure
- Can work disconnected
- Uses Kubernetes CRDs as the interface

### Component Interactions

```
┌──────────────────────────────────────────────────────────────────┐
│                     User/Automation                               │
│                  (API calls / CRD applies)                        │
└─────────────────────────┬────────────────────────────────────────┘
                          │
         ┌────────────────┴────────────────┐
         │                                 │
         ▼                                 ▼
┌─────────────────┐              ┌─────────────────────────┐
│ assisted-service│◄────────────►│ Infrastructure Operator │
│    (REST API)   │              │    (CRD reconciler)     │
└────────┬────────┘              └─────────────────────────┘
         │
         │ Generate ISO request
         ▼
┌─────────────────────┐
│ assisted-image-service│
│   (ISO generation)  │
└─────────────────────┘
         │
         │ ISO URL
         ▼
┌─────────────────────────────────────────────────────────────────┐
│                        Hosts boot ISO                            │
│                     (Discovery Image)                            │
└─────────────────────────┬───────────────────────────────────────┘
                          │
                          │ Agent registers, sends inventory
                          ▼
┌─────────────────┐              ┌───────────────────────────────┐
│ assisted-service│◄────────────►│         PostgreSQL            │
│                 │              │      (persistent state)       │
└────────┬────────┘              └───────────────────────────────┘
         │
         │ Validations pass, install triggered
         │
         ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Agents execute installation                   │
│  (write Ignition, reboot, bootstrap, cluster formation)         │
└─────────────────────────────────────────────────────────────────┘
```

## 3.2 Custom Resource Definitions (On-Premise)

When running via the Infrastructure Operator, you interact via CRDs. Understanding these is essential.

### AgentServiceConfig

Configures the Assisted Service itself:

```yaml
apiVersion: agent-install.openshift.io/v1beta1
kind: AgentServiceConfig
metadata:
  name: agent
spec:
  databaseStorage:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 10Gi
  filesystemStorage:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 100Gi
  mirrorRegistryRef:  # For disconnected
    name: mirror-registry-config
  osImages:           # CoreOS images to use
    - openshiftVersion: "4.14"
      version: "414.92.202310191551-0"
      url: "https://..."
      cpuArchitecture: x86_64
```

The Infrastructure Operator watches this and deploys assisted-service, assisted-image-service, and PostgreSQL.

### InfraEnv

Represents a discovery environment — the configuration for discovery ISOs:

```yaml
apiVersion: agent-install.openshift.io/v1beta1
kind: InfraEnv
metadata:
  name: my-infraenv
  namespace: my-cluster
spec:
  clusterRef:               # Optional: bind to a cluster
    name: my-cluster
    namespace: my-cluster
  pullSecretRef:
    name: pull-secret
  sshAuthorizedKey: "ssh-rsa AAAA..."
  proxy:
    httpProxy: http://proxy.example.com:8080
    httpsProxy: http://proxy.example.com:8080
    noProxy: .example.com,10.0.0.0/8
  nmStateConfigLabelSelector:  # For static IPs
    matchLabels:
      infraenv: my-infraenv
  additionalNTPSources:
    - ntp.example.com
  cpuArchitecture: x86_64
```

After applying, the operator creates an ISO and populates status:

```yaml
status:
  isoDownloadURL: "https://assisted-image-service.../images/..."
  createdTime: "2024-01-15T10:30:00Z"
  conditions:
    - type: ImageCreated
      status: "True"
```

### NMStateConfig

For static IP configuration (one per host):

```yaml
apiVersion: agent-install.openshift.io/v1beta1
kind: NMStateConfig
metadata:
  name: master-0
  namespace: my-cluster
  labels:
    infraenv: my-infraenv  # Matches InfraEnv's nmStateConfigLabelSelector
spec:
  config:
    interfaces:
      - name: eno1
        type: ethernet
        state: up
        ipv4:
          enabled: true
          dhcp: false
          address:
            - ip: 192.168.1.100
              prefix-length: 24
        ipv6:
          enabled: false
    dns-resolver:
      config:
        server:
          - 192.168.1.1
    routes:
      config:
        - destination: 0.0.0.0/0
          next-hop-address: 192.168.1.1
          next-hop-interface: eno1
  interfaces:
    - name: eno1
      macAddress: "00:11:22:33:44:55"  # Maps config to physical interface
```

### ClusterDeployment (Hive CRD)

This is a Hive CRD (from ACM) that Assisted uses to define a cluster:

```yaml
apiVersion: hive.openshift.io/v1
kind: ClusterDeployment
metadata:
  name: my-cluster
  namespace: my-cluster
spec:
  clusterName: my-cluster
  baseDomain: example.com
  platform:
    agentBareMetal:
      agentSelector:
        matchLabels:
          cluster: my-cluster
  pullSecretRef:
    name: pull-secret
  clusterInstallRef:
    group: extensions.hive.openshift.io
    version: v1beta1
    kind: AgentClusterInstall
    name: my-cluster
```

### AgentClusterInstall

The detailed cluster configuration for Assisted:

```yaml
apiVersion: extensions.hive.openshift.io/v1beta1
kind: AgentClusterInstall
metadata:
  name: my-cluster
  namespace: my-cluster
spec:
  clusterDeploymentRef:
    name: my-cluster
  imageSetRef:
    name: openshift-v4.14.0  # ClusterImageSet reference
  networking:
    clusterNetwork:
      - cidr: 10.128.0.0/14
        hostPrefix: 23
    serviceNetwork:
      - 172.30.0.0/16
    machineNetwork:
      - cidr: 192.168.1.0/24
  provisionRequirements:
    controlPlaneAgents: 3
    workerAgents: 2
  sshPublicKey: "ssh-rsa AAAA..."
  apiVIP: 192.168.1.10
  ingressVIP: 192.168.1.11
  manifestsConfigMapRef:  # Optional: custom manifests
    name: my-manifests
  holdInstallation: false  # Set true to pause before install
```

### Agent

Created automatically when a host discovers itself. You don't create these manually:

```yaml
apiVersion: agent-install.openshift.io/v1beta1
kind: Agent
metadata:
  name: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee  # Host UUID
  namespace: my-cluster
  labels:
    infraenvs.agent-install.openshift.io: my-infraenv
spec:
  approved: true              # Set to true to allow installation
  hostname: master-0          # Override discovered hostname
  role: master                # master, worker, or auto-assign
  clusterDeploymentName:
    name: my-cluster
    namespace: my-cluster
  machineConfigPool: master   # Which MCP to join
status:
  inventory:
    hostname: localhost
    memory:
      physicalBytes: 17179869184
      usableBytes: 16500000000
    cpu:
      count: 8
      architecture: x86_64
      modelName: "Intel..."
    disks:
      - name: sda
        path: /dev/sda
        sizeBytes: 500107862016
        driveType: HDD
        bootable: true
    interfaces:
      - name: eno1
        ipv4Addresses:
          - 192.168.1.100/24
        macAddress: "00:11:22:33:44:55"
        speedMbps: 1000
    systemVendor:
      manufacturer: Dell
      productName: PowerEdge R640
  conditions:
    - type: SpecSynced
      status: "True"
    - type: Connected
      status: "True"
    - type: RequirementsMet
      status: "True"
  validationsInfo:
    hardware:
      - id: has-inventory
        status: success
      - id: has-min-cpu-cores
        status: success
        message: "Sufficient CPU cores"
      - id: has-min-memory
        status: success
        message: "Sufficient RAM"
      - id: has-min-valid-disks
        status: success
    network:
      - id: machine-cidr-defined
        status: success
      - id: belongs-to-machine-cidr
        status: success
      - id: api-vip-connected
        status: success
      - id: belongs-to-majority-group
        status: success
```

### ClusterImageSet

Defines which OpenShift version to install:

```yaml
apiVersion: hive.openshift.io/v1
kind: ClusterImageSet
metadata:
  name: openshift-v4.14.0
spec:
  releaseImage: quay.io/openshift-release-dev/ocp-release:4.14.0-x86_64
```

## 3.3 The Discovery Image

### What's in the ISO

The discovery ISO is a bootable CoreOS image with:

1. **Base CoreOS image**: Standard RHCOS live ISO
2. **Agent binary**: The `agent` process that runs on boot
3. **Configuration**: Embedded in the Ignition config
   - assisted-service URL
   - Pull secret
   - SSH key
   - Proxy settings
   - Static IP config (if any)
4. **Certificates**: For TLS communication with assisted-service

### ISO Generation Process

When you create an InfraEnv (or request an ISO via API):

1. **assisted-image-service** receives the request
2. It takes the base CoreOS ISO
3. Generates an Ignition config with:
   - Agent systemd service
   - Discovery configuration
   - Network configuration (static IPs if specified)
   - Pull secret, SSH keys
4. Embeds the Ignition into the ISO (in the initramfs)
5. Caches the ISO (keyed by the config hash)
6. Returns the download URL

The ISO is generated on-demand but cached. Same configuration = same ISO (deduplication).

### ISO Types

**Full ISO**: Contains the entire CoreOS image (~1GB)
- Boots independently
- Good for disconnected environments

**Minimal ISO**: Contains only the initramfs and kernel (~100MB)
- Requires network access to download rootfs
- Faster to download/transfer
- Good for connected environments

### Static IP Handling

For static IPs, the Ignition config includes NMState configuration:

```yaml
# Inside the Ignition config
storage:
  files:
    - path: /etc/assisted/network/host_config/master-0.yaml
      contents:
        source: data:text/plain;base64,...  # NMState YAML
    - path: /etc/assisted/network/mac_interface_map.yaml
      contents:
        source: data:text/plain;base64,...  # MAC to interface mapping
```

When the agent boots:
1. It reads the MAC address of the current machine
2. Matches it against the mac_interface_map
3. Applies the corresponding network configuration
4. Then starts discovery

## 3.4 The Agent

### Agent Startup Sequence

When a host boots the discovery ISO:

1. **BIOS/UEFI** loads the ISO
2. **Bootloader** (GRUB) loads kernel and initramfs
3. **Ignition** runs in initramfs:
   - Configures network (DHCP or static)
   - Writes configuration files
   - Enables systemd services
4. **System boots** into the live OS
5. **agent.service** starts

### Agent Service Configuration

The agent is configured via `/etc/assisted/agent.conf` or environment variables:

```bash
# /etc/assisted/agent.conf
SERVICE_URL=https://assisted-service.example.com:8443
INFRA_ENV_ID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
AGENT_AUTH_TOKEN=eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9...
PULL_SECRET_FILE=/etc/assisted/pull-secret.json
```

### Discovery Process

The agent performs discovery immediately on start:

1. **Hardware inventory**:
   - CPU info (count, model, flags)
   - Memory (total, usable)
   - Disks (path, size, type, model, bootability)
   - Network interfaces (name, MAC, speed, IPs)
   - System vendor info (manufacturer, product, serial)
   - GPU info
   - TPM info

2. **Network inventory**:
   - Routes
   - DNS configuration
   - NTP servers

3. **Hostname**: From `/etc/hostname` or reverse DNS

The agent sends all this to assisted-service via the REST API.

### Agent-Service Communication

The agent maintains a connection to assisted-service:

```
Agent                                    assisted-service
  │                                            │
  │──── POST /v2/infra-envs/{id}/hosts ────────►│
  │     (Register with inventory)              │
  │                                            │
  │◄─── 201 Created (host_id) ─────────────────│
  │                                            │
  │                                            │
  │──── GET /v2/infra-envs/{id}/hosts/{id}/    │
  │        next-step-instructions ─────────────►│
  │                                            │
  │◄─── 200 (steps to execute) ────────────────│
  │                                            │
  │──── POST /v2/infra-envs/{id}/hosts/{id}/   │
  │        instructions/{step_id} ─────────────►│
  │     (Step results)                         │
  │                                            │
  │     ... loop ...                           │
```

### Next Step Instructions

The service tells the agent what to do via "next steps":

**During discovery**:
- `inventory`: Refresh hardware inventory
- `connectivity-check`: Test connectivity to other hosts
- `api-vip-connectivity-check`: Test connectivity to API VIP
- `ntp-synchronizer`: Configure and verify NTP
- `domain-resolution`: Verify DNS resolution
- `container-image-availability`: Check image pull capability

**During installation**:
- `install`: Begin installation
- `download-boot-artifacts`: Download boot artifacts
- `write-image-to-disk`: Write CoreOS to disk
- `reboot`: Reboot into installed system

### Connectivity Checks

One of the critical validations is inter-host connectivity:

1. Each agent starts an HTTP server on a high port
2. Each agent tries to reach all other agents via:
   - L2 (direct on same network)
   - L3 (routed)
3. Results reported to service

This validates:
- Hosts can reach each other (required for etcd, API)
- Network topology is correct
- No firewall blocking cluster traffic

The service analyzes connectivity to determine:
- Are hosts on the same L2 network?
- Can they form a cluster?
- Which host is the "rendezvous" (best connectivity)

## 3.5 Validations

Assisted Installer performs extensive validation before allowing installation. This is a key differentiator from other installation methods.

### Host-Level Validations

**Hardware validations**:
| Validation | Requirement | Notes |
|------------|-------------|-------|
| has-inventory | Inventory collected | Basic sanity check |
| has-min-cpu-cores | ≥4 cores (master), ≥2 cores (worker) | SNO requires ≥8 |
| has-min-memory | ≥16GB (master), ≥8GB (worker) | SNO requires ≥16GB |
| has-min-valid-disks | ≥1 disk ≥120GB | Bootable, not removable |
| has-cpu-cores-for-role | Meets role requirement | Different for master/worker |
| has-memory-for-role | Meets role requirement | Different for master/worker |
| disk-encryption-requirements-satisfied | TPM2 if encryption enabled | For Secure Boot |
| compatible-with-cluster-platform | Platform support | vSphere, baremetal, etc. |
| hostname-valid | Valid hostname | DNS-compatible |
| hostname-unique | Unique in cluster | No duplicates |

**Network validations**:
| Validation | Requirement | Notes |
|------------|-------------|-------|
| machine-cidr-defined | Machine CIDR set | Required for IP validation |
| belongs-to-machine-cidr | IP in machine CIDR | Host must be on cluster network |
| belongs-to-majority-group | Connectivity group | Hosts must be able to communicate |
| api-vip-connected | Can reach API VIP | Required for cluster access |
| ntp-synced | NTP working | Critical for certificates |
| container-images-available | Can pull images | Registry access |
| sufficient-network-latency-requirement-for-role | Latency check | Critical for etcd (masters) |
| dns-wildcard-not-configured | No *.domain | Wildcard DNS breaks things |

**Platform-specific validations**:
| Validation | Requirement | Notes |
|------------|-------------|-------|
| vsphere-disk-uuid-enabled | disk.EnableUUID | vSphere specific |
| compatible-agent | Agent version | Must be compatible |
| lso-requirements-satisfied | LSO requirements | For local storage |
| odf-requirements-satisfied | ODF requirements | For ODF deployment |

### Cluster-Level Validations

**General**:
| Validation | Requirement |
|------------|-------------|
| all-hosts-are-ready-to-install | All hosts passed validations |
| sufficient-masters-count | Have required masters (1 or 3) |
| api-vip-defined | API VIP set (non-SNO) |
| api-vip-valid | API VIP valid for network |
| ingress-vip-defined | Ingress VIP set (non-SNO) |
| ingress-vip-valid | Ingress VIP valid for network |
| cluster-cidr-defined | Pod network defined |
| service-cidr-defined | Service network defined |
| dns-domain-defined | Base domain set |
| pull-secret-set | Pull secret provided |
| ntp-server-configured | NTP configured |
| network-type-valid | Valid network plugin |

**VIP validations**:
- API and Ingress VIPs must be in the machine network
- VIPs must not be assigned to any host
- VIPs must be different from each other

### Validation Flow

```
Host boots → Agent starts → Inventory collected → Validations run
                                                        │
                                    ┌───────────────────┴───────────────────┐
                                    │                                       │
                              All pass                               Some fail
                                    │                                       │
                                    ▼                                       ▼
                          Host ready for                          Host shows
                            installation                          validation
                                    │                              failures
                                    │                                       │
                                    │                                       ▼
                                    │                              User fixes
                                    │                                issues
                                    │                                       │
                                    │◄──────────────────────────────────────┘
                                    │
                                    ▼
                          All hosts ready →  Cluster ready for installation
```

### Validation Timing

Validations run:
- When inventory is updated
- When cluster configuration changes
- Periodically (agent polls service)

The service re-evaluates validations whenever relevant state changes. You don't have to manually re-run validations.

## 3.6 Installation Workflow

### Pre-Installation State

Before installation starts:
- All hosts have been discovered
- All validations pass
- User has approved hosts (set `approved: true` on Agent CRs)
- Cluster configuration is complete

### Installation Trigger

**Via CRD**: Set `spec.holdInstallation: false` on AgentClusterInstall (or remove it)

**Via API**: `POST /v2/clusters/{cluster_id}/actions/install`

### Installation Phases

The installation proceeds through phases:

```
                    ┌─────────────────┐
                    │    preparing    │
                    │  (preparation)  │
                    └────────┬────────┘
                             │
                    ┌────────▼────────┐
                    │  preparing-    │
                    │  for-install   │
                    └────────┬────────┘
                             │
                    ┌────────▼────────┐
                    │   installing    │
                    │  (writing disk) │
                    └────────┬────────┘
                             │
                    ┌────────▼────────┐
                    │  installing-    │
                    │  pending-user-  │
                    │    action       │
                    └────────┬────────┘
                             │ (if user action needed)
                    ┌────────▼────────┐
                    │   finalizing    │
                    │  (post-install) │
                    └────────┬────────┘
                             │
                    ┌────────▼────────┐
                    │    installed    │
                    │     (done)      │
                    └─────────────────┘
```

### Phase: Preparing

The service:
1. Generates manifests (combines user manifests with defaults)
2. Generates Ignition configs for all nodes
3. Selects the bootstrap node (best connectivity, or rendezvous IP)
4. Prepares artifacts for download

### Phase: Preparing for Install

Agents:
1. Receive instruction to download boot artifacts
2. Download CoreOS image (if not embedded in ISO)
3. Verify checksums
4. Ready to write to disk

### Phase: Installing

Agents:
1. Write CoreOS image to the installation disk
2. Write Ignition config to the disk
3. Configure bootloader to boot installed system
4. Reboot

After reboot:
- Nodes boot from disk (not ISO anymore)
- Ignition runs (configures the installed system)
- Bootstrap or join cluster depending on role

### What Happens at Reboot

This is where Assisted hands off to the standard OpenShift bootstrap process.

**Bootstrap node**:
1. Boots into installed CoreOS
2. Ignition applies bootstrap configuration
3. Starts temporary control plane (via podman containers):
   - etcd
   - kube-apiserver
   - Machine Config Server
   - cluster-bootstrap
4. Waits for control plane nodes

**Control plane nodes**:
1. Boot into installed CoreOS
2. Ignition fetches real config from MCS (on bootstrap)
3. Kubelet starts, joins cluster
4. etcd pod starts, joins etcd cluster

**Worker nodes** (if any):
1. Boot into installed CoreOS
2. Ignition fetches config from MCS
3. Kubelet starts, waits for CSR approval
4. Joins cluster after approval

### Agent Role During Installation

The agent continues running on hosts during installation to:
1. Report installation progress
2. Stream logs to the service
3. Report errors

The agent knows it's in installation mode and monitors:
- Bootstrap progress (watching for specific conditions)
- Operator status
- Error conditions

### Installation Monitoring

The service monitors installation by:
1. Receiving progress updates from agents
2. Eventually connecting to the cluster API (when available)
3. Watching cluster operators
4. Reporting ClusterVersion status

Progress is reflected in:
- Host status (phase, progress percentage)
- Cluster status (phase, progress percentage)
- Events and logs

### Bootstrap Pivot

One of the key moments is the "bootstrap pivot":

1. All control plane nodes are up
2. etcd quorum is established on control plane nodes
3. API server is running on control plane
4. Bootstrap's temporary etcd is no longer needed
5. Bootstrap can be removed

The `bootkube` process on bootstrap monitors for these conditions and signals "bootstrap complete."

In Assisted:
- The agent on bootstrap monitors for this condition
- Reports completion to assisted-service
- Bootstrap node can be repurposed (for SNO, it becomes the single node)

### Phase: Finalizing

After bootstrap completes:
1. Cluster operators are initializing
2. Service monitors operator status
3. Waits for ClusterVersion to report available
4. Generates kubeconfig and credentials
5. Installation complete

### Credentials and Access

After installation, Assisted provides:
- kubeconfig file
- kubeadmin password
- Console URL

These are stored in the database and available via API or in the ClusterDeployment status (for CRD mode).

## 3.7 Ignition Generation in Assisted

Assisted generates Ignition configs differently from the standard installer. Understanding this is important.

### What Assisted Generates

The service generates:
1. **Bootstrap Ignition**: Full configuration for bootstrap node
2. **Master Ignition**: Configuration for control plane nodes (or pointer to MCS)
3. **Worker Ignition**: Configuration for worker nodes (or pointer to MCS)

### Generation Process

When installation is triggered:

1. **Collect inputs**:
   - Cluster configuration (networks, VIPs, domain)
   - Host information (roles, hostnames, IPs)
   - Custom manifests (from ConfigMaps)
   - Image versions (release image)

2. **Generate base manifests**:
   - Run equivalent of `openshift-install create manifests`
   - Add custom manifests
   - Apply customizations

3. **Generate Ignition**:
   - Run equivalent of `openshift-install create ignition-configs`
   - Customize for each host

4. **Customize per-host**:
   - Hostname
   - Network configuration (static IPs)
   - Role-specific configuration

### Bootstrap Ignition Contents

The bootstrap Ignition contains:

- **Systemd units**:
  - `bootkube.service`: Starts bootstrap control plane
  - `approve-csr.service`: Auto-approves CSRs during bootstrap
  - `kubelet.service`: Kubelet configuration
  - etc.

- **Files**:
  - All manifests for operators
  - All CRDs
  - Bootstrap ETCD configuration
  - Certificates (CAs, initial serving certs)
  - kubeconfig files
  - Registry credentials (pull secret)

- **Bootstrap images**:
  - Container images for bootstrap components (or URLs to pull them)

The bootstrap Ignition is large (tens of MB) because it contains everything needed to bootstrap the cluster.

### Control Plane Ignition

For control plane nodes, Assisted generates either:

**Full Ignition** (older versions):
- Complete configuration
- All certificates
- Kubelet configuration

**Pointer Ignition** (current):
- Just points to MCS on bootstrap
- Fetches real config at boot time

```json
{
  "ignition": {
    "version": "3.2.0",
    "config": {
      "merge": [
        {
          "source": "https://api-int.my-cluster.example.com:22623/config/master"
        }
      ]
    },
    "security": {
      "tls": {
        "certificateAuthorities": [
          { "source": "data:text/plain;base64,<MCS_CA_CERT>" }
        ]
      }
    }
  }
}
```

### Network Configuration in Ignition

For static IPs, Assisted injects NetworkManager configuration:

```json
{
  "storage": {
    "files": [
      {
        "path": "/etc/NetworkManager/system-connections/eno1.nmconnection",
        "contents": {
          "source": "data:text/plain;base64,..."
        },
        "mode": 384
      }
    ]
  }
}
```

The nmconnection file format:
```ini
[connection]
id=eno1
type=ethernet
interface-name=eno1
autoconnect=true

[ipv4]
method=manual
addresses=192.168.1.100/24
gateway=192.168.1.1
dns=192.168.1.1

[ipv6]
method=disabled
```

### Hostname Configuration

Each host gets its hostname set via Ignition:

```json
{
  "storage": {
    "files": [
      {
        "path": "/etc/hostname",
        "contents": {
          "source": "data:,master-0"
        },
        "mode": 420
      }
    ]
  }
}
```

### Custom Manifests

Users can provide custom manifests via ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-custom-manifests
  namespace: my-cluster
data:
  99-custom-config.yaml: |
    apiVersion: machineconfiguration.openshift.io/v1
    kind: MachineConfig
    metadata:
      name: 99-custom-config
      labels:
        machineconfiguration.openshift.io/role: worker
    spec:
      config:
        ignition:
          version: 3.2.0
        storage:
          files:
            - path: /etc/my-custom-file
              contents:
                source: data:,custom-content
```

These manifests are merged into the installation manifests before Ignition generation.

## 3.8 Single Node OpenShift (SNO)

SNO is a special case that Assisted handles well.

### What's Different

- **One node**: Control plane, etcd, and workloads all on one node
- **No HA**: No fault tolerance (by design — edge use case)
- **No VIPs**: The node IP is the API and Ingress endpoint
- **Bootstrap-in-place**: No separate bootstrap node

### Bootstrap-in-Place

For SNO, the bootstrap process is different:

1. Node boots from discovery ISO
2. Installation writes Ignition and reboots
3. Node boots into installed system
4. **Same node** runs bootstrap AND becomes the final node
5. Bootstrap completes on the same node
6. Cluster is running

There's no separate bootstrap node to remove — the node transitions from bootstrap to production in place.

### Configuration Differences

AgentClusterInstall for SNO:

```yaml
apiVersion: extensions.hive.openshift.io/v1beta1
kind: AgentClusterInstall
metadata:
  name: sno-cluster
spec:
  clusterDeploymentRef:
    name: sno-cluster
  provisionRequirements:
    controlPlaneAgents: 1  # Just one
    workerAgents: 0
  networking:
    clusterNetwork:
      - cidr: 10.128.0.0/14
        hostPrefix: 23
    serviceNetwork:
      - 172.30.0.0/16
    machineNetwork:
      - cidr: 192.168.1.0/24
  # No apiVIP or ingressVIP — uses node IP
```

### Resource Requirements

SNO has higher minimum requirements:
- **CPU**: ≥8 cores
- **RAM**: ≥32GB (production), ≥16GB (minimum)
- **Disk**: ≥120GB

Because everything runs on one node, you need more resources.

## 3.9 Multi-Node Cluster Installation

For standard HA clusters (3 control plane + N workers):

### Node Roles

- **3 Control Plane (Masters)**: Run API server, etcd, controllers, scheduler
- **N Workers**: Run user workloads

### Bootstrap Node Selection

Assisted selects one master as the bootstrap node:
1. Check connectivity scores
2. Check if rendezvous IP is specified
3. Select the host with best connectivity
4. That host gets bootstrap Ignition

### Installation Sequence

1. **All nodes**: Write image to disk, reboot
2. **Bootstrap node**: Starts first, runs temporary control plane
3. **Other masters**: Boot, fetch config from bootstrap's MCS, join cluster
4. **etcd**: Forms quorum on masters
5. **Bootstrap complete**: Control plane moves to masters
6. **Workers**: Boot, CSRs auto-approved, join cluster
7. **Operators**: Initialize
8. **Complete**: All operators ready

### VIP Handling

API VIP and Ingress VIP are managed by:
- **keepalived**: VRRP for IP failover
- **haproxy**: Load balancing to backends

These run as static pods on control plane nodes.

During installation:
1. Bootstrap node claims the VIPs
2. As masters come up, they participate in VRRP
3. VIP floats to available node if bootstrap goes away

## 3.10 Day 2 Operations

### Adding Workers

After initial installation, you can add workers:

1. Create new NMStateConfig (if static IPs)
2. New hosts boot the same discovery ISO
3. They register with assisted-service
4. You approve them and set role=worker
5. They install and join the cluster

This works because:
- The InfraEnv still exists
- The cluster is still registered in assisted-service
- The service can generate worker Ignition

### Scaling Control Plane

Adding control plane nodes is more complex:
- etcd must be scaled carefully
- Certificates must be regenerated
- Not typically done via Assisted after initial install

### Day 2 Considerations

Assisted is primarily an **installation** tool. After installation:
- Use OpenShift's native tools for operations
- MCO for OS changes
- Machine API for scaling (if IPI-style)
- Manual for UPI-style

---

# Part 4: Comparison with Other Methods

## 4.1 Assisted vs. IPI

| Aspect | Assisted | IPI |
|--------|----------|-----|
| Infrastructure | You provision | Installer provisions |
| Discovery | Boot ISO, discover hosts | No discovery |
| Validation | Extensive, before install | Minimal |
| Bootstrap | You manage | Automatic (cloud VM) |
| VIPs | Static, you choose | Dynamic (cloud LB) |
| Platforms | Bare-metal, vSphere, etc. | AWS, Azure, GCP, etc. |
| GUI | Yes (console.redhat.com) | No (CLI only) |
| Machine API | Limited | Full |

## 4.2 Assisted vs. UPI

| Aspect | Assisted | UPI |
|--------|----------|-----|
| Discovery | Automatic | Manual inventory |
| Validation | Built-in | You validate |
| Ignition | Generated by service | Generated by installer |
| Workflow | API/GUI driven | Manual steps |
| Static IPs | NMStateConfig | Manual Ignition edit |
| Error feedback | Rich, early | Often at boot time |
| CSR approval | Automatic | Manual |

## 4.3 Assisted vs. Agent-Based

| Aspect | Assisted | Agent-Based |
|--------|----------|-------------|
| Service | Required (SaaS or on-prem) | None (self-contained) |
| ISO | Generic discovery | Pre-configured |
| Configuration | Discover then configure | Configure then boot |
| Approval | Explicit | Implicit (all hosts approved) |
| Disconnected | Via Infrastructure Operator | Native support |
| Fleet management | Yes (ACM) | No |
| GUI | Yes | No |

---

# Part 5: Troubleshooting and Debugging

## 5.1 Common Issues and Root Causes

### Host Not Registering

**Symptoms**: Boot ISO, but host doesn't appear in Assisted

**Possible causes**:
1. **Network**: Host can't reach assisted-service
2. **DNS**: Can't resolve service hostname
3. **TLS**: Certificate issues
4. **Proxy**: Proxy not configured or blocking

**Debugging**:
```bash
# On the host (via console)
journalctl -u agent.service
curl -v https://assisted-service.example.com/health
```

### Validation Failures

**Symptoms**: Host discovered but not ready to install

**Debugging**:
- Check Agent CR `.status.validationsInfo`
- Look for `status: failure` entries
- Address the specific issue

### Installation Stuck

**Symptoms**: Installation starts but doesn't progress

**Common stages where it sticks**:

1. **"Installing" for too long**: Disk write issues
2. **After reboot**: Ignition fetch failing
3. **"Waiting for bootstrap"**: Bootstrap not starting
4. **"Waiting for control plane"**: Masters not joining

**Debugging**:
```bash
# If you can access the host
journalctl -b
journalctl -u kubelet
crictl logs <container_id>

# Check bootkube on bootstrap
journalctl -u bootkube.service
```

### etcd Issues

**Symptoms**: Cluster partially starts, some components never ready

**Cause**: etcd can't form quorum

**Debugging**:
```bash
# On a master
crictl logs <etcd_container>
etcdctl member list
etcdctl endpoint health
```

## 5.2 Log Collection

### During Discovery

Agents send logs to assisted-service continuously. Access via:
- API: `GET /v2/clusters/{id}/logs`
- CRD: Check conditions and events
- Console: Download from UI

### During Installation

Logs are collected:
- Until reboot: In-memory, streamed to service
- After reboot: From disk, via agent (if still running)

### Post-Installation

If installation fails and you need logs:

```bash
# If node is accessible
oc adm must-gather
journalctl -u kubelet
crictl logs -f <container>

# If assisted-service is available
GET /v2/clusters/{id}/downloads/logs
```

## 5.3 Common Fixes

### NTP Issues

```yaml
# InfraEnv with NTP
spec:
  additionalNTPSources:
    - ntp.example.com
```

Or via kernel argument:
```yaml
spec:
  kernelArguments:
    - value: "chronyd.sources=ntp.example.com"
```

### DNS Issues

Ensure:
- `api.cluster.domain` resolves to API VIP
- `api-int.cluster.domain` resolves to API VIP
- `*.apps.cluster.domain` resolves to Ingress VIP

### Certificate Issues

- Check MCS CA is correct
- Check times are synchronized (NTP)
- Check cert expiration

### Disk Issues

- Ensure disk is at least 120GB
- Ensure disk is not mounted
- Ensure disk is not in RAID mode that hides it
- Try `wipefs` on the disk before boot

---

# Part 6: Appendices

## Appendix A: Glossary

| Term | Definition |
|------|------------|
| **Agent** | Process on discovered hosts that communicates with assisted-service |
| **AgentClusterInstall** | CRD defining Assisted cluster configuration |
| **Bootstrap** | Temporary process/node that starts a cluster |
| **Bootstrap-in-Place** | SNO bootstrap where same node becomes final node |
| **ClusterDeployment** | Hive CRD representing a cluster (used by Assisted) |
| **CVO** | Cluster Version Operator, manages all operators |
| **Ignition** | First-boot provisioning system for CoreOS |
| **InfraEnv** | CRD defining a discovery environment |
| **MCO** | Machine Config Operator, manages node OS configuration |
| **MCS** | Machine Config Server, serves Ignition to nodes |
| **NMState** | Network configuration format |
| **RHCOS** | Red Hat Enterprise Linux CoreOS |
| **SNO** | Single Node OpenShift |
| **VIP** | Virtual IP (API VIP, Ingress VIP) |

## Appendix B: API Endpoints Reference

Key assisted-service API endpoints:

```
# Cluster operations
POST   /v2/clusters                         # Create cluster
GET    /v2/clusters                         # List clusters
GET    /v2/clusters/{id}                    # Get cluster
PATCH  /v2/clusters/{id}                    # Update cluster
DELETE /v2/clusters/{id}                    # Delete cluster
POST   /v2/clusters/{id}/actions/install    # Start installation
POST   /v2/clusters/{id}/actions/reset      # Reset failed installation

# InfraEnv operations
POST   /v2/infra-envs                       # Create InfraEnv
GET    /v2/infra-envs                       # List InfraEnvs
GET    /v2/infra-envs/{id}                  # Get InfraEnv
GET    /v2/infra-envs/{id}/downloads/image  # Download ISO

# Host operations
GET    /v2/infra-envs/{id}/hosts            # List hosts
GET    /v2/infra-envs/{id}/hosts/{host_id}  # Get host
PATCH  /v2/infra-envs/{id}/hosts/{host_id}  # Update host (role, name, etc.)

# Installation artifacts
GET    /v2/clusters/{id}/downloads/kubeconfig        # Download kubeconfig
GET    /v2/clusters/{id}/downloads/credentials       # Get credentials
GET    /v2/clusters/{id}/downloads/files             # Download files
GET    /v2/clusters/{id}/logs                        # Get logs
```

## Appendix C: Port Reference

| Port | Component | Purpose |
|------|-----------|---------|
| 6443 | API Server | Kubernetes API |
| 22623 | Machine Config Server | Ignition serving |
| 443 | Ingress | HTTPS ingress |
| 80 | Ingress | HTTP ingress (redirect) |
| 2379 | etcd | Client traffic |
| 2380 | etcd | Peer traffic |
| 9000-9999 | Host network | Default service node ports |
| 10250 | Kubelet | API |
| 10257 | kube-controller-manager | Health/metrics |
| 10259 | kube-scheduler | Health/metrics |
| 6081 | OVN | Geneve (overlay network) |

## Appendix D: Directory Structure on Installed Node

After installation, key directories:

```
/etc/
├── kubernetes/
│   ├── manifests/          # Static pod manifests (control plane)
│   ├── static-pod-resources/
│   └── kubelet.conf
├── machine-config-daemon/
├── mco/
├── cni/
│   └── net.d/              # CNI configuration
└── NetworkManager/
    └── system-connections/  # Network config

/var/
├── lib/
│   ├── etcd/               # etcd data (control plane)
│   ├── kubelet/            # Kubelet data
│   └── containers/         # Container storage
└── log/

/opt/
└── openshift/              # OpenShift-specific scripts
```

## Appendix E: Useful Commands

### On a Discovered Host

```bash
# Agent status
systemctl status agent.service
journalctl -u agent.service -f

# Network
nmcli connection show
ip addr
curl -v https://assisted-service/health

# Hardware
lsblk
free -h
lscpu
```

### On an Installed Node

```bash
# Node status
oc get nodes
oc describe node <name>

# Cluster operators
oc get clusteroperators
oc get clusterversion

# Pods
oc get pods -A
oc get pods -n openshift-etcd
oc get pods -n openshift-kube-apiserver

# Machine config
oc get machineconfigs
oc get machineconfigpools
oc describe mcp worker

# Certificates
oc get secrets -A | grep tls
```

### Assisted Service (On-Premise)

```bash
# Check pods
oc get pods -n assisted-installer

# Logs
oc logs -n assisted-installer deployment/assisted-service
oc logs -n assisted-installer deployment/assisted-image-service

# Database
oc exec -it -n assisted-installer deployment/postgres -- psql -U assisted
```

---

# Summary

To summarize what happens when you install via Assisted:

1. **You create configuration** (InfraEnv, ClusterDeployment, AgentClusterInstall)

2. **Assisted generates a discovery ISO** containing:
   - CoreOS live image
   - Agent binary
   - Configuration (service URL, auth, network)

3. **Hosts boot the ISO** and:
   - Agent starts
   - Discovers hardware, network
   - Registers with assisted-service

4. **Assisted validates** everything:
   - Hardware meets requirements
   - Network connectivity works
   - All hosts can communicate

5. **You approve and trigger installation**

6. **Assisted generates Ignition configs**:
   - Full bootstrap config for bootstrap node
   - Pointer configs for other nodes

7. **Agents write CoreOS to disk** with Ignition

8. **Hosts reboot into installed system**:
   - Bootstrap node starts temporary control plane
   - Other nodes fetch config from MCS and join

9. **OpenShift bootstrap process runs**:
   - etcd forms quorum
   - Control plane moves to masters
   - Operators initialize

10. **Installation completes**:
    - ClusterVersion reports available
    - Credentials generated
    - Cluster ready for use

The key insight: **Assisted is an orchestration layer on top of the standard OpenShift bootstrap process**. It handles discovery, validation, and Ignition generation, but once nodes reboot into the installed system, it's standard OpenShift from there.
