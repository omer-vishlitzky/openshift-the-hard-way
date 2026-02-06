# Stage 13: Operator Convergence

After the pivot, the Cluster Version Operator (CVO) deploys all cluster operators. This stage explains the process.

## What is Operator Convergence?

OpenShift is built on operators. The CVO:
1. Reads the release image
2. Extracts operator manifests
3. Applies them in dependency order
4. Monitors their health

Convergence is complete when all operators report Available=True.

## Cluster Version Operator (CVO)

The CVO is the master orchestrator:

```
┌─────────────────────────────────────────────────┐
│              RELEASE IMAGE                       │
│  (contains all operator manifests)               │
└───────────────────────┬─────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────┐
│         CLUSTER VERSION OPERATOR                 │
│  - Extracts manifests                           │
│  - Orders by run-level                          │
│  - Applies to cluster                           │
│  - Monitors health                              │
└───────────────────────┬─────────────────────────┘
                        │
        ┌───────────────┼───────────────┐
        ▼               ▼               ▼
   ┌─────────┐    ┌─────────┐    ┌─────────┐
   │ network │    │ ingress │    │  dns    │
   │operator │    │operator │    │operator │
   └─────────┘    └─────────┘    └─────────┘
```

## Monitor CVO Progress

```bash
export KUBECONFIG=${ASSETS_DIR}/kubeconfigs/admin.kubeconfig

# Watch cluster version
watch oc get clusterversion

# Check CVO logs
oc logs -n openshift-cluster-version deploy/cluster-version-operator -f
```

## Monitor All Operators

```bash
# Watch all cluster operators
watch oc get co

# Check specific operator
oc describe co network
```

## Operator Dependencies

Operators deploy in run-level order:

| Run Level | Operators |
|-----------|-----------|
| 0000 | cluster-version-operator |
| 0001-0009 | networking prerequisites |
| 0010-0019 | network, dns, service-ca |
| 0020-0029 | authentication, config |
| 0030-0039 | ingress, console |
| 0040+ | everything else |

## Key Operators

### network (OVN-Kubernetes)

```bash
oc get co network
oc get pods -n openshift-ovn-kubernetes
```

Must be healthy before most other operators.

### dns

```bash
oc get co dns
oc get pods -n openshift-dns
```

Provides cluster DNS (CoreDNS).

### ingress

```bash
oc get co ingress
oc get pods -n openshift-ingress
```

Runs router pods for external traffic.

### authentication

```bash
oc get co authentication
oc get pods -n openshift-authentication
```

OAuth server for cluster authentication.

### console

```bash
oc get co console
oc get pods -n openshift-console
```

Web console.

## Common Convergence Issues

### Operator stuck Progressing

```bash
# Check operator status
oc describe co <operator-name>

# Check operator pods
oc get pods -n openshift-<operator-name>

# Check operator logs
oc logs -n openshift-<operator-name> deploy/<operator-name>
```

### Network operator not ready

Common causes:
- CNI not deployed
- Node networking issues
- OVN pods failing

```bash
oc get pods -n openshift-ovn-kubernetes
oc logs -n openshift-ovn-kubernetes ds/ovnkube-node
```

### Image pull failures

```bash
# Check for ImagePullBackOff
oc get pods -A | grep -E 'ImagePull|ErrImage'

# Check pull secret
oc get secret -n openshift-config pull-secret
```

### DNS not resolving

```bash
# Check dns operator
oc get co dns

# Check dns pods
oc get pods -n openshift-dns

# Test DNS from a pod
oc run test --rm -it --restart=Never --image=busybox -- nslookup kubernetes
```

## Convergence Progress

Track overall progress:

```bash
# Count operators by status
oc get co -o json | jq '
  [.items[].status.conditions[] | select(.type=="Available")] |
  group_by(.status) |
  map({status: .[0].status, count: length})
'
```

## Waiting for Convergence

A cluster is converged when:
- All operators Available=True
- No operators Degraded=True
- ClusterVersion reports Available

```bash
# Wait for all operators
oc wait co --all --for=condition=Available --timeout=30m

# Check cluster version
oc get clusterversion -o jsonpath='{.items[0].status.conditions[?(@.type=="Available")].status}'
```

## Verification Checklist

```bash
# Cluster version progressing
oc get clusterversion

# All operators available
oc get co | grep -v "True.*False.*False"

# No degraded operators
oc get co | grep "True$" | grep -v Degraded

# All pods running
oc get pods -A | grep -v Running | grep -v Completed
```

## What's Next

Once all operators are Available, continue to [Stage 14: MCO Handoff](../14-mco-handoff/README.md) to understand how the Machine Config Operator manages nodes.
