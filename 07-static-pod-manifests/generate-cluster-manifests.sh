#!/bin/bash
# Generate cluster manifests that bootkube.sh applies after the control plane starts.
#
# These are the Kubernetes resources that turn a bare etcd+apiserver into
# a cluster that nodes can join and CVO can take over.
#
# What we write by hand (core, must understand):
#   - Namespaces
#   - RBAC for node bootstrapping
#   - Cluster identity (Infrastructure, Network CRs)
#   - Pull secret (so operators can pull images)
#   - Kubeadmin credential
#   - CVO deployment (the ONE operator we start — it handles the rest)
#
# What CVO handles (50+ operators, no value in hand-writing):
#   - Prometheus, console, image-registry, ingress, etc.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/cluster-vars.sh"
source "${SCRIPT_DIR}/../04-release-image/component-images.sh"

CLUSTER_MANIFESTS="${MANIFESTS_DIR}/cluster-manifests"
mkdir -p "${CLUSTER_MANIFESTS}"

echo "=== Generating Cluster Manifests ==="
echo "Output: ${CLUSTER_MANIFESTS}"
echo ""

# Generate a random cluster ID (normally the installer creates this)
INFRA_ID="${CLUSTER_NAME}-$(head -c4 /dev/urandom | xxd -p)"

# --- Namespaces ---
# These must exist before we can create resources in them.

echo "Writing namespaces..."
cat > "${CLUSTER_MANIFESTS}/01-namespaces.yaml" <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-config
---
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-config-managed
---
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-etcd
---
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-kube-apiserver
---
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-kube-controller-manager
---
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-kube-scheduler
---
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-cluster-version
---
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-machine-config-operator
---
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-infra
---
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-node
EOF

# --- RBAC for node bootstrapping ---
# When a kubelet starts with a bootstrap kubeconfig, it needs permission to:
# 1. Create a CertificateSigningRequest (CSR)
# 2. Get its CSR approved (we do this manually, KTHW-style)
#
# The built-in ClusterRole "system:node-bootstrapper" grants CSR creation.
# We bind our bootstrap identity (system:bootstrapper) to it.

echo "Writing RBAC..."
cat > "${CLUSTER_MANIFESTS}/02-rbac.yaml" <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:bootstrapper
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:node-bootstrapper
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: User
  name: system:bootstrapper
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:node-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:node-admin
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: User
  name: system:admin
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:bootstrapper-proxy
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:node-proxier
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: User
  name: system:bootstrapper
EOF

# --- Infrastructure CR ---
# Tells operators about the cluster's infrastructure (platform, API URLs).

echo "Writing infrastructure config..."
cat > "${CLUSTER_MANIFESTS}/03-infrastructure.yaml" <<EOF
apiVersion: config.openshift.io/v1
kind: Infrastructure
metadata:
  name: cluster
spec:
  platformSpec:
    type: None
status:
  infrastructureName: ${INFRA_ID}
  platform: None
  platformStatus:
    type: None
  apiServerURL: ${API_URL}
  apiServerInternalURL: ${API_INT_URL}
  controlPlaneTopology: HighlyAvailable
  infrastructureTopology: HighlyAvailable
EOF

# --- Network CR ---
# Tells the network operator what CIDRs to use.

echo "Writing network config..."
cat > "${CLUSTER_MANIFESTS}/04-network.yaml" <<EOF
apiVersion: config.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  clusterNetwork:
  - cidr: ${CLUSTER_NETWORK_CIDR}
    hostPrefix: ${CLUSTER_NETWORK_HOST_PREFIX}
  serviceNetwork:
  - ${SERVICE_NETWORK_CIDR}
  networkType: OVNKubernetes
EOF

# --- Operator Network CR ---
# The network operator watches operator.openshift.io/v1 Network (not config.openshift.io/v1).
# Without this, the network operator reports "No networks.operator.openshift.io cluster found"
# and never deploys OVN-Kubernetes.

echo "Writing operator Network CR..."
cat > "${CLUSTER_MANIFESTS}/04b-operator-network.yaml" <<EOF
apiVersion: operator.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  clusterNetwork:
  - cidr: ${CLUSTER_NETWORK_CIDR}
    hostPrefix: ${CLUSTER_NETWORK_HOST_PREFIX}
  serviceNetwork:
  - ${SERVICE_NETWORK_CIDR}
  defaultNetwork:
    type: OVNKubernetes
EOF

# --- DNS CR ---
echo "Writing DNS config..."
cat > "${CLUSTER_MANIFESTS}/05-dns.yaml" <<EOF
apiVersion: config.openshift.io/v1
kind: DNS
metadata:
  name: cluster
spec:
  baseDomain: ${BASE_DOMAIN}
EOF

# --- cluster-config-v1 ---
# Contains the install-config. The network operator reads this to configure OVN.
# Without it: "configmaps cluster-config-v1 not found".

echo "Writing cluster-config-v1..."
cat > "${CLUSTER_MANIFESTS}/05b-cluster-config-v1.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-config-v1
  namespace: kube-system
data:
  install-config: |
    apiVersion: v1
    metadata:
      name: ${CLUSTER_NAME}
    baseDomain: ${BASE_DOMAIN}
    networking:
      networkType: OVNKubernetes
      clusterNetwork:
      - cidr: ${CLUSTER_NETWORK_CIDR}
        hostPrefix: ${CLUSTER_NETWORK_HOST_PREFIX}
      serviceNetwork:
      - ${SERVICE_NETWORK_CIDR}
      machineNetwork:
      - cidr: ${MACHINE_NETWORK}
    platform:
      none: {}
    controlPlane:
      replicas: 3
    compute:
    - replicas: 2
EOF

# --- etcd-endpoints ---
# Tells the etcd-operator where the bootstrap etcd is.
# Without it: "configmap etcd-endpoints not found" and etcd-operator can't find existing etcd.

echo "Writing etcd-endpoints..."
cat > "${CLUSTER_MANIFESTS}/05c-etcd-endpoints.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: etcd-endpoints
  namespace: openshift-etcd
data:
  bootstrapIP: "${BOOTSTRAP_IP}"
EOF

# --- FeatureGate ---
# CVO reads this to determine which feature set is active.
# Without it, CVO detects a feature mismatch and shuts down.
echo "Writing FeatureGate..."
cat > "${CLUSTER_MANIFESTS}/05a-featuregate.yaml" <<'EOF'
apiVersion: config.openshift.io/v1
kind: FeatureGate
metadata:
  name: cluster
spec:
  featureSet: ""
EOF

# --- Pull secret ---
# Operators need this to pull images from the registry.
echo "Writing pull secret..."
PULL_SECRET_B64=$(base64 -w0 "${PULL_SECRET_FILE}")
cat > "${CLUSTER_MANIFESTS}/06-pull-secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: pull-secret
  namespace: openshift-config
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: ${PULL_SECRET_B64}
EOF

# --- Kubeadmin password ---
# The initial admin credential. We generate a random password.
echo "Writing kubeadmin password..."
KUBEADMIN_PASSWORD=$(head -c16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c16)
KUBEADMIN_HASH=$(echo -n "${KUBEADMIN_PASSWORD}" | htpasswd -niB kubeadmin 2>/dev/null | cut -d: -f2 || echo -n "${KUBEADMIN_PASSWORD}" | base64 -w0)

# Save password to file for the user
mkdir -p "${ASSETS_DIR}/auth"
echo "${KUBEADMIN_PASSWORD}" > "${ASSETS_DIR}/auth/kubeadmin-password"

KUBEADMIN_HASH_B64=$(echo -n "${KUBEADMIN_HASH}" | base64 -w0)
cat > "${CLUSTER_MANIFESTS}/07-kubeadmin.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: kubeadmin
  namespace: kube-system
type: Opaque
data:
  kubeadmin: ${KUBEADMIN_HASH_B64}
EOF

# --- ClusterVersion CR ---
# Tells CVO what release image to reconcile against.

echo "Writing ClusterVersion..."
cat > "${CLUSTER_MANIFESTS}/08-clusterversion.yaml" <<EOF
apiVersion: config.openshift.io/v1
kind: ClusterVersion
metadata:
  name: version
spec:
  channel: stable-${OCP_VERSION%.*}
  clusterID: $(uuidgen)
EOF

# --- CVO Static Pod ---
# CVO runs as a static pod on bootstrap (same as etcd, apiserver).
# The bootstrap kubelet doesn't register as a node, so Deployments can't
# schedule. Static pods are the only way to run containers on bootstrap.
# CVO reads the release image, creates CRDs, and deploys all operators.

echo "Writing CVO static pod..."
BOOTSTRAP_MANIFESTS="${MANIFESTS_DIR}/bootstrap-manifests"
cat > "${BOOTSTRAP_MANIFESTS}/cvo-bootstrap.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: cvo-bootstrap
  namespace: openshift-cluster-version
  labels:
    k8s-app: cluster-version-operator
spec:
  hostNetwork: true
  containers:
  - name: cluster-version-operator
    # The RELEASE IMAGE, not the CVO operator image.
    # CVO needs /release-manifests/ which only exists in the release image.
    image: ${RELEASE_IMAGE}
    args:
    - start
    - --release-image=${RELEASE_IMAGE}
    - --enable-auto-update=false
    - --kubeconfig=/etc/kubernetes/kubeconfigs/localhost.kubeconfig
    # Empty --listen disables the metrics endpoint (otherwise requires TLS cert)
    - --listen=
    - --v=2
    securityContext:
      privileged: true
    env:
    - name: KUBERNETES_SERVICE_HOST
      value: "127.0.0.1"
    - name: KUBERNETES_SERVICE_PORT
      value: "6443"
    - name: NODE_NAME
      value: "bootstrap"
    - name: CLUSTER_PROFILE
      value: "self-managed-high-availability"
    volumeMounts:
    - name: kubeconfigs
      mountPath: /etc/kubernetes/kubeconfigs
      readOnly: true
  volumes:
  - name: kubeconfigs
    hostPath:
      path: /etc/kubernetes/kubeconfigs
EOF

echo ""
echo "=== Cluster Manifests Generated ==="
echo ""
ls -la "${CLUSTER_MANIFESTS}"/*.yaml
echo ""
echo "Kubeadmin password saved to: ${ASSETS_DIR}/auth/kubeadmin-password"
echo "  Username: kubeadmin"
echo "  Password: ${KUBEADMIN_PASSWORD}"
echo ""
echo "These manifests will be applied by bootkube.sh after the control plane starts."
echo "CVO runs as a static pod using the release image — it deploys all other operators."
