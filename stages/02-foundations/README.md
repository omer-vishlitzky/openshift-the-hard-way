# Stage 02: Foundations (Beginner to Deep Dive)

This stage is a complete on-ramp for engineers who have no prior OpenShift or Kubernetes background. It is intentionally thorough. The goal is to build a correct mental model before we touch metal.

**Sources used in this stage**
- `../pdfs/openshift/Architecture.pdf`
- `../pdfs/openshift/Installation_overview.pdf`
- `../pdfs/openshift/Installing_on_bare_metal.pdf`

**What OpenShift is (in one paragraph)**
OpenShift is a Kubernetes platform that ships as a tightly versioned, self-updating system. It is not just Kubernetes plus add-ons. OpenShift includes the operating system (RHCOS), a release payload that defines the entire platform, and a set of Operators that reconcile every critical component. The result is a system that upgrades as a whole, enforces a consistent configuration, and expects the cluster to manage itself after bootstrap.

**Kubernetes vs OpenShift (practical differences)**
| Area | Kubernetes (vanilla) | OpenShift | Why it matters for install |
| --- | --- | --- | --- |
| Distribution | You assemble components | Single release payload | You must deliver the exact payload version |
| OS | Any Linux | RHCOS by default | OS immutability changes how config is applied |
| Updates | Varies by install | Cluster Version Operator (CVO) | Release image drives updates and reconciliation |
| Config drift | Admin-managed | Machine Config Operator (MCO) enforces | Host config changes are reconciled |
| Platform services | Optional | Integrated (Ingress, OAuth, monitoring) | These are installed during bootstrap |

## Core vocabulary you must know

| Term | What it is | Why it matters for install |
| --- | --- | --- |
| Cluster | A set of nodes managed as one system | Installation creates the cluster identity and state |
| Node | A machine (physical or VM) running kubelet | Nodes are the actual OS targets you provision |
| Pod | The smallest schedulable unit in Kubernetes | Control plane components run as pods |
| Control plane | Components that store state and schedule work | This is what bootstrap builds first |
| etcd | Distributed key-value store for cluster state | All control plane health depends on it |
| kube-apiserver | Front door of the cluster | Every component talks to the API server |
| kube-controller-manager | Reconciles resources to desired state | Makes the cluster converge |
| kube-scheduler | Assigns pods to nodes | Required for workloads to run |
| kubelet | Node agent | Registers nodes and runs pods |
| Operator | Controller that manages a component | OpenShift relies on Operators for lifecycle |
| Ignition | First-boot provisioning tool for RHCOS | Defines how disks, files, and services are created |
| RHCOS | Immutable OS image for OpenShift nodes | You do not manage it like normal Linux |
| Release image | Container image containing all manifests | CVO applies this to build the platform |

## Control plane deep dive (what actually runs)
The control plane is just a set of pods that run on control plane nodes. These pods are initially created as static pods so the system can start without a running API.

**Core control plane components**
| Component | Role | Installation implication |
| --- | --- | --- |
| kube-apiserver | Serves the API | Must be reachable via the API VIP during install |
| etcd | Stores all cluster state | Requires low latency storage and quorum |
| kube-controller-manager | Reconciles state | Brings resources to desired state |
| kube-scheduler | Assigns workloads | Needed for Operators to run |

**How a single API request flows**
1. Client sends a request to the API server.
2. The API server validates and writes the desired state into etcd.
3. Controllers notice the new desired state and reconcile the real world.
4. The kubelet on each node ensures the correct pods run.

This "control loop" is why Kubernetes is called a declarative system. You describe the end state. The system makes it true.

## etcd deep dive (why it is critical)
- etcd is the source of truth for the cluster.
- It uses the Raft consensus algorithm, which requires a majority (quorum) to be healthy.
- For HA, you run an odd number of etcd members (3 is the baseline).
- Performance matters: the docs call out a p99 fsync of 10 ms or lower for etcd storage.

Practical result: if etcd is slow or loses quorum, your entire control plane becomes unreliable. This is why disk performance is a hard requirement in the bare metal docs.

## RHCOS and Ignition deep dive

**RHCOS**
RHCOS is an immutable OS delivered as an OSTree image. Most of the OS is read-only. Configuration is applied at first boot using Ignition and later enforced by the Machine Config Operator.

**Ignition**
Ignition runs once during the initramfs stage on first boot. It can:
- Partition disks and format filesystems.
- Write files and systemd units.
- Configure users and SSH keys.
- Inject network configuration.

This is why installation is driven by Ignition configs. If Ignition is wrong, the node does not become a correct OpenShift host.

**Why this matters for \"by hand\" installation**
You are not \"installing packages\" on nodes. You are providing an OS image plus a precise Ignition config that builds the node into the cluster. The node's configuration after first boot is enforced by the MCO.

## Operators and the OpenShift release payload

OpenShift uses Operators to manage almost everything. The Cluster Version Operator (CVO) pulls a release image and applies manifests in ordered runlevels. Those manifests create and update all other operators.

- The release image is the single versioned artifact for the platform.
- The CVO is the source of truth for what should be running.
- The MCO applies OS and node configuration changes after the control plane is up.

This model is what makes OpenShift \"one platform version\" instead of a loose set of components.

## Bootstrap and pivot, in plain terms

Bootstrap is a temporary control plane that exists only to create the real control plane. It is a bridge.

- The bootstrap node starts a single-node etcd and a temporary API server.
- Control plane nodes fetch configuration from bootstrap and start their own control plane pods.
- The etcd operator expands etcd to all control plane nodes.
- The temporary control plane shuts down and the production control plane takes over.

In HA, this pivot is a handoff between machines. In SNO, bootstrap and control plane are the same node, but the same phases still occur.

## Networking basics for the install

There are two primary VIPs in a standard HA setup:
- The API VIP is used by clients and nodes to reach the API server on port 6443 and the Machine Config Server on 22623.
- The Ingress VIP fronts application traffic on ports 80 and 443.

DNS and load balancing are not optional. They are part of the control plane's ability to converge.

## What you should be able to explain after this stage

- Why OpenShift is more than \"just Kubernetes.\"
- Why the release image and the CVO are central to cluster state.
- Why etcd performance and quorum are non-negotiable.
- How Ignition and RHCOS change the installation model.
- What the bootstrap node is and why it is temporary.

**Deliverables for this stage**
- A shared language and a correct mental model for the rest of the project.
