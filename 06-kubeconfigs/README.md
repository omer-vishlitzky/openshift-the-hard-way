# Stage 06: Kubeconfigs

Kubeconfigs are YAML files that define how to connect to and authenticate with the Kubernetes API server. We need several different kubeconfigs for different components.

## What is a Kubeconfig?

A kubeconfig contains:
1. **Cluster**: API server URL and CA certificate
2. **User**: Client certificate or token for authentication
3. **Context**: Maps a user to a cluster

```yaml
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: <base64 CA cert>
    server: https://api.example.com:6443
  name: cluster
users:
- name: admin
  user:
    client-certificate-data: <base64 client cert>
    client-key-data: <base64 client key>
contexts:
- context:
    cluster: cluster
    user: admin
  name: admin
current-context: admin
```

## Required Kubeconfigs

| Kubeconfig | User | Purpose |
|------------|------|---------|
| admin.kubeconfig | system:admin | Cluster administrator |
| kube-controller-manager.kubeconfig | system:kube-controller-manager | Controller manager → API server |
| kube-scheduler.kubeconfig | system:kube-scheduler | Scheduler → API server |
| kubelet-bootstrap.kubeconfig | system:bootstrapper | Initial kubelet authentication |
| localhost.kubeconfig | system:admin | For operators on localhost |
| localhost-recovery.kubeconfig | system:admin | For recovery operations |

## Generate All Kubeconfigs

```bash
./generate.sh
```

This creates kubeconfigs in `${ASSETS_DIR}/kubeconfigs/`.

## Manual Generation (Educational)

### Admin Kubeconfig

```bash
source ../config/cluster-vars.sh
KUBECONFIG_DIR="${ASSETS_DIR}/kubeconfigs"
mkdir -p "${KUBECONFIG_DIR}"

# Base64 encode certificates
CA_DATA=$(base64 -w0 "${PKI_DIR}/kubernetes-ca.crt")
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

### Controller Manager Kubeconfig

The controller manager needs to:
- Connect to the API server
- Sign service account tokens
- Manage cluster resources

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

### Scheduler Kubeconfig

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

### Kubelet Bootstrap Kubeconfig

This is a special kubeconfig used by kubelet for initial TLS bootstrapping:

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

### Localhost Kubeconfig

Used by operators running on the same node as the API server:

```bash
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

## API Server URLs

Note the different API server URLs:

| URL | Usage |
|-----|-------|
| `https://api.cluster.example.com:6443` | External access (through load balancer) |
| `https://api-int.cluster.example.com:6443` | Internal access (control plane components) |
| `https://localhost:6443` | Same-node access (operators on control plane) |

Control plane components use `api-int` to avoid going through the external load balancer.

## File Locations in the Cluster

In a running OpenShift cluster, kubeconfigs are stored at:

| Path | Kubeconfig |
|------|------------|
| `/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/lb-ext.kubeconfig` | External LB |
| `/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/lb-int.kubeconfig` | Internal LB |
| `/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost.kubeconfig` | Localhost |

## Kubeconfig Tree

After generation:
```
${ASSETS_DIR}/kubeconfigs/
├── admin.kubeconfig
├── kube-controller-manager.kubeconfig
├── kube-scheduler.kubeconfig
├── kubelet-bootstrap.kubeconfig
├── localhost.kubeconfig
└── localhost-recovery.kubeconfig
```

## Verification

```bash
./verify.sh
```

Checks:
- All kubeconfigs exist
- Kubeconfigs are valid YAML
- Server URLs are correct
- Certificates are embedded

## Testing (after cluster is up)

Once the cluster is running, test the admin kubeconfig:

```bash
export KUBECONFIG="${ASSETS_DIR}/kubeconfigs/admin.kubeconfig"
oc get nodes
```

## Security Notes

- Kubeconfigs contain private keys - protect them!
- admin.kubeconfig has cluster-admin privileges
- Never commit kubeconfigs to git
- Rotate credentials periodically

## What's Next

In [Stage 07](../07-static-pod-manifests/README.md), we render the static pod manifests for etcd, API server, controller manager, and scheduler.
