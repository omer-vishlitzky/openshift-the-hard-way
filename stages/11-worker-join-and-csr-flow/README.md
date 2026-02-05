# Stage 11: Worker Join and CSR Flow

This stage explains how worker nodes join the cluster, how TLS bootstrapping works, and how to approve CSRs when needed.

**Sources used in this stage**
- `../pdfs/openshift/Architecture.pdf`
- `../pdfs/openshift/Installing_on_bare_metal.pdf`

## What happens when a worker boots

1. The worker boots from RHCOS with its Ignition config.
2. The kubelet starts and registers the node with the API server.
3. The kubelet generates certificate signing requests (CSRs) for its client and serving certificates.
4. The cluster approves these CSRs and the node becomes `Ready`.

## CSR flow in OpenShift

OpenShift includes controllers that approve most node CSRs automatically. When a node does not match expected identity or configuration, CSRs can remain pending and require manual approval.

## Hands-on: inspect and approve CSRs

List CSRs:

```bash
oc get csr
```

Inspect a specific CSR:

```bash
oc describe csr <csr_name>
```

Approve a CSR manually:

```bash
oc adm certificate approve <csr_name>
```

## Verification checks

- `oc get nodes` shows the worker as `Ready`.
- `oc get csr` shows no pending CSRs for the new worker.
- `oc -n openshift-machine-config-operator get pods` shows MCD running on the worker.

**Deliverables for this stage**
- A clear understanding of how workers join the cluster.
- A concrete CSR troubleshooting routine.
