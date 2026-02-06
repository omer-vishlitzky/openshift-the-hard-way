# Single Node OpenShift (SNO) Differences

This appendix covers how SNO differs from the HA cluster documented in this guide.

## What is SNO?

Single Node OpenShift runs the entire cluster on one node:
- Control plane + worker on same node
- No etcd clustering (single member)
- No bootstrap node needed
- Simpler but no high availability

## Key Differences

| Aspect | HA Cluster (3 masters) | SNO |
|--------|------------------------|-----|
| Nodes | 1 bootstrap + 3 masters + workers | 1 node |
| etcd | 3 members with quorum | 1 member |
| Bootstrap | Separate bootstrap node | Self-bootstrap |
| HA | Yes | No |
| Resource requirements | Higher | Lower |
| Use case | Production | Edge, Dev/Test |

## etcd Differences

### HA Cluster
- Bootstrap starts 1-member etcd
- Masters join, etcd scales to 4
- Bootstrap removed, etcd = 3

### SNO
- Single etcd member
- No scaling required
- No quorum considerations

## Bootstrap Differences

### HA Cluster
```
Bootstrap → renders manifests
         → starts control plane
         → Masters join
         → etcd scales
         → Pivot to masters
         → Bootstrap shutdown
```

### SNO
```
SNO Node → renders manifests
        → starts control plane
        → etcd runs locally
        → No pivot needed
        → Node is ready
```

SNO includes bootstrap logic in the node ignition itself.

## Ignition Differences

### HA master.ign
Fetches config from MCS:
```json
{
  "ignition": {
    "config": {
      "merge": [{
        "source": "https://api-int:22623/config/master"
      }]
    }
  }
}
```

### SNO ignition
Contains everything (like bootstrap.ign):
- All certificates
- All manifests
- Bootstrap scripts
- Control plane config

## Networking Differences

### HA Cluster
- API VIP + Ingress VIP
- Load balancer required
- DNS for VIPs

### SNO
- No VIPs (single IP)
- No load balancer
- API and Ingress on node IP

## DNS Differences

### HA Cluster
```
api.cluster.example.com       → VIP
api-int.cluster.example.com   → VIP
*.apps.cluster.example.com    → Ingress VIP
```

### SNO
```
api.cluster.example.com       → Node IP
api-int.cluster.example.com   → Node IP
*.apps.cluster.example.com    → Node IP
```

## Resource Requirements

### HA Cluster (per master)
- 4 vCPU
- 16 GB RAM
- 100 GB disk

### SNO
- 8 vCPU
- 16-32 GB RAM (runs everything)
- 120+ GB disk

## SNO-Specific Manifests

SNO requires specific configuration:

```yaml
# install-config.yaml for SNO
apiVersion: v1
baseDomain: example.com
metadata:
  name: sno-cluster
compute:
- name: worker
  replicas: 0  # No separate workers
controlPlane:
  name: master
  replicas: 1  # Single master
platform:
  none: {}
bootstrapInPlace:
  installationDisk: /dev/sda  # SNO-specific
```

## Operator Behavior

Some operators behave differently on SNO:

### ingress-operator
- Runs router on control plane node
- No worker nodes to schedule on

### etcd-operator
- Manages single member
- No scaling operations

### machine-config-operator
- Single node in each pool
- No rolling updates (node is the cluster)

## Upgrading SNO

Upgrades are different:
- Node must reboot for kubelet updates
- Entire cluster is unavailable during updates
- No rolling updates possible

## When to Use SNO

**Good for:**
- Edge deployments
- Development/testing
- Resource-constrained environments
- Non-production workloads

**Not good for:**
- Production workloads requiring HA
- Multi-tenancy
- Large-scale deployments

## Converting This Guide for SNO

To install SNO using this guide:

1. Skip bootstrap VM
2. Create single node with SNO ignition
3. Skip etcd scaling sections
4. Skip pivot sections
5. Skip worker join (unless adding workers to SNO later)

## Future Addition

A complete SNO walkthrough may be added as a separate track.
