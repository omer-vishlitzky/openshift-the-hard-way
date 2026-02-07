# Stage 06: Kubeconfigs

A kubeconfig answers three questions: **who am I**, **where's the API server**, and **how do I prove it**. Every component that talks to the API server needs one.

```yaml
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: <base64 CA cert>    # how to verify the API server's cert
    server: https://api.example.com:6443            # where's the API server
  name: cluster
users:
- name: admin
  user:
    client-certificate-data: <base64 client cert>   # who am I
    client-key-data: <base64 client key>            # prove it
contexts:
- context:
    cluster: cluster
    user: admin
  name: admin
current-context: admin
```

## What We're Building

Five kubeconfigs, each used by a different component to authenticate against the API server:

**admin.kubeconfig** — Used by you with `oc`/`kubectl`. Connects to `api.ocp4.example.com:6443` (through HAProxy). Authenticates as `system:admin` using the admin client cert from Stage 05. This is what you copy to `~/.kube/config`.

**kube-controller-manager.kubeconfig** — Used by the KCM static pod. Connects to `api-int.ocp4.example.com:6443` (same VIP, internal convention). Authenticates as `system:kube-controller-manager`.

**kube-scheduler.kubeconfig** — Used by the scheduler static pod. Connects to `api-int`. Authenticates as `system:kube-scheduler`.

**kubelet-bootstrap.kubeconfig** — Used by kubelet on first boot. Connects to `api-int`. Authenticates as `system:bootstrapper` — a temporary identity with minimal permissions (just enough to submit a CSR). Once the CSR is approved and kubelet gets a real certificate, it writes its own permanent kubeconfig to `/var/lib/kubelet/kubeconfig` and stops using this one.

**localhost.kubeconfig** — Used by bootkube.sh and CVO on the bootstrap node. Connects to `localhost:6443` — bypasses the VIP entirely and talks directly to the API server on the same machine. During early bootstrap, the VIP might not be routable yet, but localhost always works. Uses the admin cert (same identity as admin.kubeconfig, different network path).

`api` and `api-int` both resolve to the same VIP (`192.168.126.10`). `api-int` is the convention for internal cluster traffic, `api` for external. Same destination.

## Generate

```bash
source config/cluster-vars.sh
KUBECONFIG_DIR="${ASSETS_DIR}/kubeconfigs"
mkdir -p "${KUBECONFIG_DIR}"

# Base64 encode the CA cert — every kubeconfig needs this to verify the API server's identity
CA_DATA=$(base64 -w0 "${PKI_DIR}/kubernetes-ca.crt")
```

All five kubeconfigs have the same structure — only the server URL, cert, and key change.

### admin.kubeconfig

```bash
ADMIN_CERT=$(base64 -w0 "${PKI_DIR}/admin.crt")
ADMIN_KEY=$(base64 -w0 "${PKI_DIR}/admin.key")

cat > "${KUBECONFIG_DIR}/admin.kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${CA_DATA}
    server: ${API_URL}
  name: ${CLUSTER_NAME}
users:
- name: admin
  user:
    client-certificate-data: ${ADMIN_CERT}
    client-key-data: ${ADMIN_KEY}
contexts:
- context:
    cluster: ${CLUSTER_NAME}
    user: admin
  name: admin
current-context: admin
EOF
```

### kube-controller-manager.kubeconfig

```bash
KCM_CERT=$(base64 -w0 "${PKI_DIR}/kube-controller-manager.crt")
KCM_KEY=$(base64 -w0 "${PKI_DIR}/kube-controller-manager.key")

cat > "${KUBECONFIG_DIR}/kube-controller-manager.kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${CA_DATA}
    server: ${API_INT_URL}
  name: ${CLUSTER_NAME}
users:
- name: system:kube-controller-manager
  user:
    client-certificate-data: ${KCM_CERT}
    client-key-data: ${KCM_KEY}
contexts:
- context:
    cluster: ${CLUSTER_NAME}
    user: system:kube-controller-manager
  name: system:kube-controller-manager
current-context: system:kube-controller-manager
EOF
```

### kube-scheduler.kubeconfig

```bash
SCHED_CERT=$(base64 -w0 "${PKI_DIR}/kube-scheduler.crt")
SCHED_KEY=$(base64 -w0 "${PKI_DIR}/kube-scheduler.key")

cat > "${KUBECONFIG_DIR}/kube-scheduler.kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${CA_DATA}
    server: ${API_INT_URL}
  name: ${CLUSTER_NAME}
users:
- name: system:kube-scheduler
  user:
    client-certificate-data: ${SCHED_CERT}
    client-key-data: ${SCHED_KEY}
contexts:
- context:
    cluster: ${CLUSTER_NAME}
    user: system:kube-scheduler
  name: system:kube-scheduler
current-context: system:kube-scheduler
EOF
```

### kubelet-bootstrap.kubeconfig

```bash
BOOTSTRAP_CERT=$(base64 -w0 "${PKI_DIR}/kubelet-bootstrap.crt")
BOOTSTRAP_KEY=$(base64 -w0 "${PKI_DIR}/kubelet-bootstrap.key")

cat > "${KUBECONFIG_DIR}/kubelet-bootstrap.kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${CA_DATA}
    server: ${API_INT_URL}
  name: ${CLUSTER_NAME}
users:
- name: system:bootstrapper
  user:
    client-certificate-data: ${BOOTSTRAP_CERT}
    client-key-data: ${BOOTSTRAP_KEY}
contexts:
- context:
    cluster: ${CLUSTER_NAME}
    user: system:bootstrapper
  name: system:bootstrapper
current-context: system:bootstrapper
EOF
```

### localhost.kubeconfig

```bash
# Same admin cert, but connects to localhost instead of the VIP
cat > "${KUBECONFIG_DIR}/localhost.kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${CA_DATA}
    server: https://localhost:6443
  name: localhost
users:
- name: admin
  user:
    client-certificate-data: ${ADMIN_CERT}
    client-key-data: ${ADMIN_KEY}
contexts:
- context:
    cluster: localhost
    user: admin
  name: admin
current-context: admin
EOF
```

### Verify

```bash
ls ${KUBECONFIG_DIR}/
```

You should have 5 files. Once the cluster is running, test with:

```bash
KUBECONFIG=${KUBECONFIG_DIR}/admin.kubeconfig oc get nodes
```

## What's Next

In [Stage 07](../07-static-pod-manifests/README.md), we write the static pod manifests for etcd, API server, controller manager, and scheduler.
