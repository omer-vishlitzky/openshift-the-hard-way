# Stage 07: Static Pod Manifests

Static pods are the foundation of the OpenShift control plane. They're managed directly by kubelet, not by the API server.

## What Are Static Pods?

Static pods:
- Are defined by YAML files in `/etc/kubernetes/manifests/`
- Are started and managed by kubelet directly
- Don't require a running API server
- Are the only way to bootstrap the control plane

The control plane runs as static pods:
- etcd
- kube-apiserver
- kube-controller-manager
- kube-scheduler

## Why Operators Render Manifests

We use operator containers to render manifests because:

1. **Complexity**: Static pod manifests are 500+ lines each
2. **Version-specific**: Arguments, flags, and image references change between versions
3. **Correctness**: Operators validate inputs and handle edge cases
4. **Consistency**: Same logic used in production clusters

## Render All Manifests

```bash
./render-all.sh
```

This runs each operator's `render` command and outputs to `${MANIFESTS_DIR}/`.

## How Rendering Works

Each operator has a `render` subcommand:

```bash
podman run --rm \
  -v ${PKI_DIR}:/assets/tls:ro,z \
  -v ${MANIFESTS_DIR}:/assets/output:z \
  ${CLUSTER_KUBE_APISERVER_OPERATOR_IMAGE} \
  /usr/bin/cluster-kube-apiserver-operator render \
  --asset-input-dir=/assets/tls \
  --asset-output-dir=/assets/output \
  --manifest-etcd-serving-ca=/assets/tls/etcd-ca.crt \
  --manifest-etcd-server-urls=https://etcd.${CLUSTER_DOMAIN}:2379 \
  ...
```

The operator:
1. Reads certificates from input directory
2. Reads configuration parameters from flags
3. Renders manifests with correct images, arguments, and mounts
4. Writes output to the output directory

## Render etcd

```bash
./render-etcd.sh
```

etcd static pod manifest includes:
- etcd image from release
- Peer and client TLS configuration
- Data directory mount
- Environment variables for cluster formation

Key configuration:
```yaml
env:
- name: ETCD_NAME
  value: "etcd-0"
- name: ETCD_INITIAL_CLUSTER
  value: "etcd-0=https://etcd-0.cluster.example.com:2380,etcd-1=...,etcd-2=..."
- name: ETCD_INITIAL_CLUSTER_STATE
  value: "new"  # or "existing" for scaling
```

## Render kube-apiserver

```bash
./render-kube-apiserver.sh
```

API server manifest includes:
- TLS certificates for serving and client auth
- etcd client certificates
- Service account key
- Feature gates
- Admission controllers
- Audit logging

Key arguments:
```yaml
args:
- --etcd-servers=https://etcd.cluster.example.com:2379
- --etcd-cafile=/etc/kubernetes/secrets/etcd-ca.crt
- --tls-cert-file=/etc/kubernetes/secrets/serving.crt
- --tls-private-key-file=/etc/kubernetes/secrets/serving.key
- --service-account-key-file=/etc/kubernetes/secrets/service-account.pub
- --service-cluster-ip-range=172.30.0.0/16
- --enable-admission-plugins=...
```

## Render kube-controller-manager

```bash
./render-kcm.sh
```

Controller manager manifest includes:
- Kubeconfig for API server auth
- Service account signing key
- Cluster CIDR configuration
- Leader election configuration

Key arguments:
```yaml
args:
- --kubeconfig=/etc/kubernetes/secrets/kubeconfig
- --service-account-private-key-file=/etc/kubernetes/secrets/service-account.key
- --cluster-cidr=10.128.0.0/14
- --service-cluster-ip-range=172.30.0.0/16
- --leader-elect=true
```

## Render kube-scheduler

```bash
./render-scheduler.sh
```

Scheduler manifest includes:
- Kubeconfig for API server auth
- Scheduling profiles
- Leader election configuration

## Manifest Structure

After rendering:
```
${MANIFESTS_DIR}/
├── bootstrap-manifests/
│   ├── etcd-member.yaml              # etcd static pod
│   ├── kube-apiserver-pod.yaml       # API server static pod
│   ├── kube-controller-manager-pod.yaml
│   └── kube-scheduler-pod.yaml
├── manifests/
│   └── ... (cluster manifests to apply after bootstrap)
├── etcd-bootstrap/
│   ├── etcd-member.yaml
│   └── secrets/
│       ├── etcd-all-certs.yaml
│       └── ...
└── kube-apiserver-bootstrap/
    ├── kube-apiserver-pod.yaml
    └── secrets/
        └── ...
```

## Understanding Static Pod Structure

A static pod manifest has this structure:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: openshift-kube-apiserver
  labels:
    app: openshift-kube-apiserver
spec:
  hostNetwork: true         # Uses host networking
  containers:
  - name: kube-apiserver
    image: quay.io/.../kube-apiserver@sha256:...
    command:
    - /bin/bash
    - -c
    - exec hyperkube kube-apiserver ...
    args: [...]
    volumeMounts:
    - name: secrets
      mountPath: /etc/kubernetes/secrets
      readOnly: true
    - name: config
      mountPath: /etc/kubernetes/config
      readOnly: true
    livenessProbe: {...}
    readinessProbe: {...}
  volumes:
  - name: secrets
    hostPath:
      path: /etc/kubernetes/static-pod-resources/kube-apiserver-certs
  - name: config
    hostPath:
      path: /etc/kubernetes/static-pod-resources/kube-apiserver-config
```

Key characteristics:
- `hostNetwork: true`: Uses node's network namespace
- Secrets mounted from host paths
- Liveness/readiness probes for health checking
- No restart policy (kubelet always restarts static pods)

## Comparing Manual vs Operator-Rendered

See [comparison.md](comparison.md) for a detailed comparison of:
- What the operator adds vs a minimal manifest
- Why certain arguments are needed
- What would break without operator rendering

## Verification

```bash
./verify.sh
```

Checks:
- All manifests exist
- Manifests are valid YAML
- Required images are referenced
- Secret mounts exist

## What's Next

In [Stage 08](../08-ignition/README.md), we build complete Ignition configs that include these manifests, certificates, kubeconfigs, and systemd units.
