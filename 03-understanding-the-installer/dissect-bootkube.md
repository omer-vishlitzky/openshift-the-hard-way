# Dissecting bootkube.sh

The `bootkube.sh` script is the orchestration heart of OpenShift bootstrap. It's approximately 656 lines of bash that coordinate the entire bootstrap process.

## Overview

bootkube.sh runs on the bootstrap node and:
1. Renders manifests using operator containers
2. Starts the bootstrap control plane (static pods)
3. Waits for the API server to be ready
4. Applies cluster manifests
5. Monitors for masters to join

## The 15 Stages

### Stage 1: Copy OpenShift Manifests

```bash
cp -r /opt/openshift/manifests /assets/manifests
```

Copies the pre-generated OpenShift manifests to the assets directory.

### Stage 2: Extract Release Image Info

```bash
RELEASE_IMAGE_DIGEST=$(oc adm release info ${RELEASE_IMAGE} --registry-config=/root/.docker/config.json -o json | jq -r '.digest')
```

Gets the release image digest for reproducibility.

### Stage 3: Render API Bootstrap

```bash
podman run ... ${KUBE_APISERVER_OPERATOR_IMAGE} \
  /usr/bin/cluster-kube-apiserver-operator render \
  --asset-input-dir=/assets/tls \
  --asset-output-dir=/assets/kube-apiserver-bootstrap \
  ...
```

The kube-apiserver-operator container renders:
- API server static pod manifest
- Required secret mounts
- TLS configuration

### Stage 4: Render Authentication API

```bash
podman run ... ${AUTHENTICATION_OPERATOR_IMAGE} \
  /usr/bin/authentication-operator render \
  --asset-input-dir=/assets/tls \
  --asset-output-dir=/assets/auth \
  ...
```

Renders OAuth server configuration.

### Stage 5: Render Config Bootstrap

```bash
podman run ... ${CONFIG_OPERATOR_IMAGE} \
  /usr/bin/config-operator render \
  --asset-input-dir=/assets/tls \
  --asset-output-dir=/assets/config-bootstrap \
  ...
```

Renders cluster configuration resources.

### Stage 6: Render CVO Bootstrap

```bash
podman run ... ${CVO_IMAGE} \
  /usr/bin/cluster-version-operator render \
  --release-image=${RELEASE_IMAGE} \
  --output-dir=/assets/cvo-bootstrap \
  ...
```

The Cluster Version Operator renders:
- All operator manifests from the release payload
- CVO deployment manifest
- Resource ordering information

### Stage 7: Render etcd Bootstrap

```bash
podman run ... ${ETCD_OPERATOR_IMAGE} \
  /usr/bin/cluster-etcd-operator render \
  --asset-input-dir=/assets/tls \
  --asset-output-dir=/assets/etcd-bootstrap \
  ...
```

Renders:
- etcd static pod manifest
- etcd peer and client certificates
- etcd scaling configuration

### Stage 8: Render kube-apiserver

```bash
podman run ... ${KUBE_APISERVER_OPERATOR_IMAGE} \
  /usr/bin/cluster-kube-apiserver-operator render \
  --asset-input-dir=/assets/tls \
  --asset-output-dir=/assets/kube-apiserver \
  ...
```

### Stage 9: Render kube-controller-manager

```bash
podman run ... ${KUBE_CONTROLLER_MANAGER_OPERATOR_IMAGE} \
  /usr/bin/cluster-kube-controller-manager-operator render \
  --asset-input-dir=/assets/tls \
  --asset-output-dir=/assets/kube-controller-manager \
  ...
```

### Stage 10: Render kube-scheduler

```bash
podman run ... ${KUBE_SCHEDULER_OPERATOR_IMAGE} \
  /usr/bin/cluster-kube-scheduler-operator render \
  --asset-input-dir=/assets/tls \
  --asset-output-dir=/assets/kube-scheduler \
  ...
```

### Stage 11: Render Ingress Operator

```bash
podman run ... ${INGRESS_OPERATOR_IMAGE} \
  /usr/bin/ingress-operator render \
  --asset-input-dir=/assets/tls \
  --asset-output-dir=/assets/ingress \
  ...
```

### Stage 12: Render MCO Bootstrap

```bash
podman run ... ${MACHINE_CONFIG_OPERATOR_IMAGE} \
  /usr/bin/machine-config-operator bootstrap \
  --asset-input-dir=/assets/tls \
  --asset-output-dir=/assets/mco-bootstrap \
  --machine-config-file=/assets/manifests/*.yaml \
  ...
```

The MCO renders:
- MachineConfig resources
- MachineConfigPool definitions
- Rendered machine configs for each role

### Stage 13: Run cluster-bootstrap

```bash
podman run ... ${CLUSTER_BOOTSTRAP_IMAGE} \
  /usr/bin/cluster-bootstrap \
  start --asset-dir=/assets \
  ...
```

This is where the magic happens:
1. Writes static pod manifests to `/etc/kubernetes/manifests/`
2. Kubelet detects new manifests and starts pods
3. etcd starts first
4. API server starts and connects to etcd
5. Controller manager and scheduler start

### Stage 14: Restore CVO Overrides

```bash
# Apply CVO manifests
oc apply -f /assets/cvo-bootstrap/
```

Seeds the Cluster Version Operator with:
- Its own deployment
- ClusterVersion resource
- Override configuration

### Stage 15: API Server Verification

```bash
wait_for_api() {
  until curl -k https://localhost:6443/healthz; do
    sleep 5
  done
}
```

Waits for the API server to become healthy.

## The Waiting Game

After Stage 15, bootkube.sh enters a monitoring phase:

```bash
# Wait for bootstrap to complete
/usr/bin/bootstrap-progress-listener --bootstrap-complete
```

This waits for signals that:
1. All masters have joined
2. etcd has scaled to 3 members
3. Control plane is healthy
4. CVO has started deploying operators

## Key Files Created

| File | Purpose |
|------|---------|
| `/etc/kubernetes/manifests/etcd-pod.yaml` | etcd static pod |
| `/etc/kubernetes/manifests/kube-apiserver-pod.yaml` | API server static pod |
| `/etc/kubernetes/manifests/kube-controller-manager-pod.yaml` | KCM static pod |
| `/etc/kubernetes/manifests/kube-scheduler-pod.yaml` | Scheduler static pod |
| `/etc/kubernetes/bootstrap-secrets/*` | All bootstrap certificates |
| `/var/lib/etcd/member/` | etcd data directory |

## Environment Variables

bootkube.sh uses these environment variables (set by Ignition):

| Variable | Purpose |
|----------|---------|
| `RELEASE_IMAGE` | The OpenShift release image |
| `KUBE_APISERVER_OPERATOR_IMAGE` | Image for API server operator |
| `ETCD_OPERATOR_IMAGE` | Image for etcd operator |
| `MACHINE_CONFIG_OPERATOR_IMAGE` | Image for MCO |
| `CLUSTER_BOOTSTRAP_IMAGE` | Image for cluster-bootstrap |
| ... | One for each operator |

## Why Use Operator Render?

You might ask: why not just template the manifests ourselves?

1. **Version coupling**: Manifests change between versions
2. **Complexity**: Operators encode complex logic (image references, feature gates, etc.)
3. **Correctness**: Operators validate input
4. **Maintenance**: Operators are updated with each release

By using operator `render` commands, we get correct, version-appropriate manifests without reimplementing operator logic.

## Our Approach

We'll replicate bootkube.sh's logic with educational scripts:

```
scripts/
├── render-all.sh           # Orchestrate all rendering
├── render-etcd.sh          # Stage 7 equivalent
├── render-kube-apiserver.sh # Stage 8 equivalent
├── render-kcm.sh           # Stage 9 equivalent
├── render-scheduler.sh     # Stage 10 equivalent
├── render-cvo.sh           # Stage 6 equivalent
├── render-mco.sh           # Stage 12 equivalent
└── start-bootstrap.sh      # Stage 13 equivalent
```

Each script:
1. Explains what it does
2. Shows the operator command
3. Validates output
4. Logs progress

## What's Different

Our approach differs from bootkube.sh in:

1. **Transparency**: Each step is a separate, documented script
2. **Verification**: We verify each stage before proceeding
3. **Education**: We explain WHY each stage exists
4. **Manual triggers**: You run each stage, not an automated script

## Next Steps

See [Stage 04](../04-release-image/README.md) to understand the release image and extract operator images.
