# Release Image Components

This document explains what each component in the release image does.

## Control Plane Components

### etcd
**Image**: `etcd`

The distributed key-value store that holds all cluster state:
- All Kubernetes objects (pods, deployments, secrets, etc.)
- OpenShift configuration
- Operator state

etcd runs as a static pod on each master node.

### kube-apiserver
**Image**: `kube-apiserver`

The Kubernetes API server:
- All cluster communication goes through the API server
- Authenticates and authorizes requests
- Validates and persists objects to etcd
- Serves the OpenShift/Kubernetes API

Runs as a static pod on each master node.

### kube-controller-manager
**Image**: `kube-controller-manager`

Runs control loops that manage cluster state:
- Node controller (monitors node health)
- Replication controller (maintains pod replicas)
- Endpoints controller (populates Endpoints objects)
- Service account controller (creates default accounts)
- And many more...

Runs as a static pod on each master node.

### kube-scheduler
**Image**: `kube-scheduler`

Assigns pods to nodes:
- Watches for unscheduled pods
- Evaluates node fitness based on constraints
- Binds pods to nodes

Runs as a static pod on each master node.

## Operators

### cluster-etcd-operator
**Image**: `cluster-etcd-operator`

Manages the etcd cluster:
- Renders etcd static pod manifests
- Handles member scaling (1 → 3)
- Manages certificates
- Handles backup/restore

### cluster-kube-apiserver-operator
**Image**: `cluster-kube-apiserver-operator`

Manages the API server:
- Renders API server static pod manifests
- Configures admission controllers
- Manages API server certificates
- Handles API server rollouts

### cluster-kube-controller-manager-operator
**Image**: `cluster-kube-controller-manager-operator`

Manages the controller manager:
- Renders KCM static pod manifests
- Configures controllers
- Manages service account signing keys

### cluster-kube-scheduler-operator
**Image**: `cluster-kube-scheduler-operator`

Manages the scheduler:
- Renders scheduler static pod manifests
- Configures scheduling profiles
- Handles scheduler rollouts

### cluster-version-operator (CVO)
**Image**: `cluster-version-operator`

The master orchestrator:
- Reads the release image
- Applies all operator manifests
- Monitors cluster version
- Handles upgrades
- Reports cluster status

### machine-config-operator (MCO)
**Image**: `machine-config-operator`

Manages node configuration:
- Renders MachineConfig resources
- Applies OS-level configuration
- Manages kubelet configuration
- Handles node updates/reboots
- Runs the Machine Config Server

### cluster-config-operator
**Image**: `cluster-config-operator`

Manages cluster configuration:
- Infrastructure configuration
- Ingress configuration
- Network configuration
- Image registry configuration

### cluster-network-operator
**Image**: `cluster-network-operator`

Manages cluster networking:
- Deploys the CNI plugin (OVN-Kubernetes or SDN)
- Configures network policies
- Manages the cluster network

### cluster-ingress-operator
**Image**: `cluster-ingress-operator`

Manages ingress:
- Deploys router pods
- Configures ingress controllers
- Manages wildcard certificates

### cluster-dns-operator
**Image**: `cluster-dns-operator`

Manages cluster DNS:
- Deploys CoreDNS
- Configures DNS policies
- Manages DNS records

### cluster-authentication-operator
**Image**: `cluster-authentication-operator`

Manages authentication:
- Configures OAuth server
- Manages identity providers
- Handles console authentication

## Infrastructure Components

### cluster-bootstrap
**Image**: `cluster-bootstrap`

Orchestrates the bootstrap process:
- Starts static pods on bootstrap
- Waits for API server
- Monitors bootstrap progress

### machine-config-server
**Image**: `machine-config-server`

Serves Ignition configs to nodes:
- Runs on bootstrap (initially)
- Runs on masters (after pivot)
- Serves /config/master, /config/worker

### haproxy-router
**Image**: `haproxy-router`

The default ingress router:
- Routes HTTP/HTTPS traffic
- Terminates TLS
- Provides sticky sessions

### coredns
**Image**: `coredns`

Cluster DNS server:
- Resolves service names
- Forwards external DNS
- Provides service discovery

## Support Components

### cli
**Image**: `cli`

Contains `oc` and `kubectl`:
- Used in init containers
- Used for debugging

### pod
**Image**: `pod`

The pause container:
- Holds the network namespace
- Used as infra container

### hyperkube
**Image**: `hyperkube`

Combined Kubernetes binaries:
- kube-apiserver
- kube-controller-manager
- kube-scheduler
- kube-proxy
- kubelet

Used for some operations where individual images aren't suitable.

### oauth-server
**Image**: `oauth-server`

OAuth 2.0 server:
- Handles OAuth flows
- Issues tokens
- Integrates with identity providers

### oauth-apiserver
**Image**: `oauth-apiserver`

OAuth API extension:
- Extends Kubernetes API
- Manages OAuth tokens
- Manages OAuth clients

## Node Components

### machine-os-content
**Image**: `machine-os-content`

Contains RHCOS filesystem:
- Base OS packages
- Kubelet binary
- CRI-O runtime
- Required system services

This is used by the MCO to build MachineConfigs.

## How Components Interact

```
                    ┌─────────────────┐
                    │  Release Image  │
                    │  (bill of       │
                    │   materials)    │
                    └────────┬────────┘
                             │
                             ▼
                    ┌─────────────────┐
                    │      CVO        │
                    │ (orchestrator)  │
                    └────────┬────────┘
                             │
          ┌──────────────────┼──────────────────┐
          │                  │                  │
          ▼                  ▼                  ▼
   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
   │ etcd-operator│  │ kube-apiserver│  │    MCO      │
   │              │  │    operator   │  │             │
   └──────┬───────┘  └──────┬───────┘  └──────┬──────┘
          │                  │                  │
          ▼                  ▼                  ▼
   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
   │    etcd      │  │ kube-apiserver│  │   kubelet   │
   │  (static pod)│  │  (static pod) │  │ (systemd)   │
   └──────────────┘  └──────────────┘  └──────────────┘
```

## Version Coupling

All components in a release are tested together:
- Kubernetes version is fixed
- etcd version is fixed
- All operator versions are fixed
- RHCOS version is fixed

This is why we use the exact images from the release, not arbitrary versions.
