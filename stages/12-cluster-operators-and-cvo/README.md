# Stage 12: Cluster Operators and CVO

This stage explains how OpenShift converges to its desired state using Operators, and how the Cluster Version Operator (CVO) drives the platform version.

**Sources used in this stage**
- `../pdfs/openshift/Architecture.pdf`
- `../pdfs/openshift/Updating_clusters.pdf`

## Operator model in OpenShift

OpenShift is built from Operators. Each Operator watches specific custom resources and reconciles the cluster into the desired state. This includes core components such as networking, storage, authentication, and monitoring.

Key points:
- Operators run as controllers inside the cluster.
- Each Operator exposes its health through a `ClusterOperator` resource.
- The cluster is considered healthy only when all Operators report `Available=True`.

## The Cluster Version Operator (CVO)

The CVO is the top-level controller for platform versioning. It:
- Pulls the release image from a registry.
- Applies manifests in ordered runlevels.
- Waits for Operators to reconcile before moving to the next stage.

This is what makes OpenShift a single versioned platform rather than a collection of independent components.

## Hands-on: operator health checks

```bash
oc get clusterversion
oc get clusteroperators
oc describe clusteroperator <name>
```

## Verification checks

- `oc get clusterversion` shows `Available=True` and `Progressing=False`.
- `oc get clusteroperators` shows all Operators `Available=True`.

**Deliverables for this stage**
- A correct mental model of the Operator-driven platform.
- A repeatable method for validating cluster convergence.
