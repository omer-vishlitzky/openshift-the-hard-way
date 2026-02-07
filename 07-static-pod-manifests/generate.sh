#!/bin/bash
# Generate static pod manifests for the bootstrap control plane
#
# In real OpenShift, operator containers render these manifests.
# Here we write them by hand so you understand every field.
#
# These static pods are what kubelet starts BEFORE the API server exists.
# They ARE the control plane.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/cluster-vars.sh"
source "${SCRIPT_DIR}/../04-release-image/component-images.sh"

BOOTSTRAP_MANIFESTS="${MANIFESTS_DIR}/bootstrap-manifests"
BOOTSTRAP_CONFIGS="${MANIFESTS_DIR}/bootstrap-configs"
mkdir -p "${BOOTSTRAP_MANIFESTS}" "${BOOTSTRAP_CONFIGS}"

echo "=== Generating Static Pod Manifests ==="
echo "Output: ${BOOTSTRAP_MANIFESTS}"
echo ""

# OpenShift uses the hyperkube image for apiserver, controller-manager, and scheduler.
# hyperkube is a single binary that contains all Kubernetes components.
HYPERKUBE="${HYPERKUBE_IMAGE}"
ETCD="${ETCD_IMAGE}"

# --- etcd ---
#
# etcd is the distributed key-value store backing ALL Kubernetes state.
# On bootstrap, we start a SINGLE etcd member. Masters will join later
# to form a 3-member cluster.
#
# Key concepts:
#   --initial-cluster-state=new    : This is a brand new cluster
#   --initial-cluster              : Lists all members that will form the cluster
#                                    (on bootstrap, just this one node)
#   hostNetwork: true              : etcd binds directly to the node's IP
#   /var/lib/etcd                  : Persistent data directory

echo "Writing etcd-bootstrap.yaml..."

cat > "${BOOTSTRAP_MANIFESTS}/etcd-bootstrap.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: etcd-bootstrap
  namespace: openshift-etcd
  labels:
    app: etcd
    k8s-app: etcd
spec:
  hostNetwork: true
  containers:
  - name: etcd
    image: ${ETCD}
    command:
    - /usr/bin/etcd
    - --name=etcd-bootstrap
    - --data-dir=/var/lib/etcd
    # Client-facing: API server connects here
    - --listen-client-urls=https://0.0.0.0:2379
    - --advertise-client-urls=https://${BOOTSTRAP_IP}:2379
    # Peer-facing: other etcd members connect here (none yet on bootstrap)
    - --listen-peer-urls=https://0.0.0.0:2380
    - --initial-advertise-peer-urls=https://${BOOTSTRAP_IP}:2380
    # Cluster formation: bootstrap starts alone
    - --initial-cluster=etcd-bootstrap=https://${BOOTSTRAP_IP}:2380
    - --initial-cluster-state=new
    - --initial-cluster-token=openshift-etcd
    # TLS for client connections (API server → etcd)
    - --cert-file=/etc/kubernetes/secrets/etcd-server.crt
    - --key-file=/etc/kubernetes/secrets/etcd-server.key
    - --client-cert-auth=true
    - --trusted-ca-file=/etc/kubernetes/secrets/etcd-ca.crt
    # TLS for peer connections (etcd ↔ etcd)
    - --peer-cert-file=/etc/kubernetes/secrets/etcd-peer.crt
    - --peer-key-file=/etc/kubernetes/secrets/etcd-peer.key
    - --peer-client-cert-auth=true
    - --peer-trusted-ca-file=/etc/kubernetes/secrets/etcd-ca.crt
    # Tuning
    - --quota-backend-bytes=8589934592
    env:
    - name: ETCD_CIPHER_SUITES
      value: TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
    volumeMounts:
    - name: etcd-data
      mountPath: /var/lib/etcd
    - name: secrets
      mountPath: /etc/kubernetes/secrets
      readOnly: true
    livenessProbe:
      exec:
        command:
        - /bin/sh
        - -c
        - "etcdctl endpoint health --endpoints=https://localhost:2379 --cacert=/etc/kubernetes/secrets/etcd-ca.crt --cert=/etc/kubernetes/secrets/etcd-server.crt --key=/etc/kubernetes/secrets/etcd-server.key"
      initialDelaySeconds: 45
      periodSeconds: 30
    resources:
      requests:
        memory: 600Mi
        cpu: 300m
  volumes:
  - name: etcd-data
    hostPath:
      path: /var/lib/etcd
      type: DirectoryOrCreate
  - name: secrets
    hostPath:
      path: /etc/kubernetes/bootstrap-secrets
EOF

# --- kube-apiserver ---
#
# The API server is the front door to the cluster. Every kubectl command,
# every operator, every controller talks through it.
#
# On bootstrap, it connects to the local etcd and serves on port 6443.
# Key concepts:
#   --etcd-servers              : Where etcd is (localhost on bootstrap)
#   --service-cluster-ip-range  : Virtual IPs for Services (not real network IPs)
#   --service-account-*         : JWT signing for pods to authenticate to the API
#   --client-ca-file            : Who can authenticate to the API (mutual TLS)
#   --requestheader-*           : API aggregation (lets OpenShift extend the API)
#   hostNetwork: true           : Binds to node port 6443 directly

echo "Writing kube-apiserver-bootstrap.yaml..."

cat > "${BOOTSTRAP_MANIFESTS}/kube-apiserver-bootstrap.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver-bootstrap
  namespace: openshift-kube-apiserver
  labels:
    app: openshift-kube-apiserver
spec:
  hostNetwork: true
  containers:
  - name: kube-apiserver
    image: ${HYPERKUBE}
    command:
    - hyperkube
    - kube-apiserver
    # Where to store data
    - --etcd-servers=https://localhost:2379
    - --etcd-cafile=/etc/kubernetes/secrets/etcd-ca.crt
    - --etcd-certfile=/etc/kubernetes/secrets/etcd-client.crt
    - --etcd-keyfile=/etc/kubernetes/secrets/etcd-client.key
    # TLS serving
    - --tls-cert-file=/etc/kubernetes/secrets/kube-apiserver.crt
    - --tls-private-key-file=/etc/kubernetes/secrets/kube-apiserver.key
    # Client authentication
    - --client-ca-file=/etc/kubernetes/secrets/kubernetes-ca.crt
    # Service accounts (pods use these tokens to talk to the API)
    - --service-account-key-file=/etc/kubernetes/secrets/service-account.pub
    - --service-account-signing-key-file=/etc/kubernetes/secrets/service-account.key
    - --service-account-issuer=https://kubernetes.default.svc
    - --api-audiences=https://kubernetes.default.svc
    # Networking
    - --service-cluster-ip-range=${SERVICE_NETWORK_CIDR}
    # Authorization
    - --authorization-mode=Node,RBAC
    - --enable-admission-plugins=NodeRestriction
    # API aggregation (allows OpenShift APIs like routes, builds, etc.)
    - --requestheader-client-ca-file=/etc/kubernetes/secrets/front-proxy-ca.crt
    - --requestheader-allowed-names=system:admin,system:openshift-aggregator
    - --requestheader-extra-headers-prefix=X-Remote-Extra-
    - --requestheader-group-headers=X-Remote-Group
    - --requestheader-username-headers=X-Remote-User
    - --proxy-client-cert-file=/etc/kubernetes/secrets/front-proxy-client.crt
    - --proxy-client-key-file=/etc/kubernetes/secrets/front-proxy-client.key
    # Kubelet client (API server → kubelet for logs, exec, port-forward)
    - --kubelet-client-certificate=/etc/kubernetes/secrets/kube-apiserver-kubelet-client.crt
    - --kubelet-client-key=/etc/kubernetes/secrets/kube-apiserver-kubelet-client.key
    - --kubelet-certificate-authority=/etc/kubernetes/secrets/kubernetes-ca.crt
    # Allow bootstrapping kubelet certificates
    - --enable-bootstrap-token-auth=true
    # Misc
    - --allow-privileged=true
    - --v=2
    volumeMounts:
    - name: secrets
      mountPath: /etc/kubernetes/secrets
      readOnly: true
    livenessProbe:
      httpGet:
        path: /healthz
        port: 6443
        scheme: HTTPS
      initialDelaySeconds: 45
      periodSeconds: 10
    readinessProbe:
      httpGet:
        path: /readyz
        port: 6443
        scheme: HTTPS
      initialDelaySeconds: 10
      periodSeconds: 10
    resources:
      requests:
        memory: 1Gi
        cpu: 500m
  volumes:
  - name: secrets
    hostPath:
      path: /etc/kubernetes/bootstrap-secrets
EOF

# --- kube-controller-manager ---
#
# Runs control loops: if a Deployment says 3 replicas but only 2 exist,
# the controller-manager creates another one.
#
# Key concepts:
#   --cluster-cidr              : Pod network CIDR (where pods get IPs)
#   --service-cluster-ip-range  : Must match API server
#   --service-account-private-key-file : Signs service account tokens
#   --root-ca-file              : CA injected into every pod's service account
#   --leader-elect              : Only one controller-manager runs at a time

echo "Writing kube-controller-manager-bootstrap.yaml..."

cat > "${BOOTSTRAP_MANIFESTS}/kube-controller-manager-bootstrap.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: kube-controller-manager-bootstrap
  namespace: openshift-kube-controller-manager
  labels:
    app: kube-controller-manager
spec:
  hostNetwork: true
  containers:
  - name: kube-controller-manager
    image: ${HYPERKUBE}
    command:
    - hyperkube
    - kube-controller-manager
    # How to talk to API server
    - --kubeconfig=/etc/kubernetes/kubeconfigs/kube-controller-manager.kubeconfig
    - --authentication-kubeconfig=/etc/kubernetes/kubeconfigs/kube-controller-manager.kubeconfig
    - --authorization-kubeconfig=/etc/kubernetes/kubeconfigs/kube-controller-manager.kubeconfig
    # Networking
    - --cluster-cidr=${CLUSTER_NETWORK_CIDR}
    - --service-cluster-ip-range=${SERVICE_NETWORK_CIDR}
    - --allocate-node-cidrs=true
    # Service account token signing
    - --service-account-private-key-file=/etc/kubernetes/secrets/service-account.key
    - --root-ca-file=/etc/kubernetes/secrets/kubernetes-ca.crt
    - --use-service-account-credentials=true
    # Certificates
    - --cluster-signing-cert-file=/etc/kubernetes/secrets/kubernetes-ca.crt
    - --cluster-signing-key-file=/etc/kubernetes/secrets/kubernetes-ca.key
    # Leader election (only one KCM active at a time)
    - --leader-elect=true
    - --leader-elect-retry-period=3s
    - --leader-elect-resource-lock=leases
    # Controllers
    - --controllers=*,bootstrapsigner,tokencleaner
    - --v=2
    volumeMounts:
    - name: secrets
      mountPath: /etc/kubernetes/secrets
      readOnly: true
    - name: kubeconfigs
      mountPath: /etc/kubernetes/kubeconfigs
      readOnly: true
    livenessProbe:
      httpGet:
        path: /healthz
        port: 10257
        scheme: HTTPS
      initialDelaySeconds: 45
      periodSeconds: 10
    resources:
      requests:
        memory: 256Mi
        cpu: 200m
  volumes:
  - name: secrets
    hostPath:
      path: /etc/kubernetes/bootstrap-secrets
  - name: kubeconfigs
    hostPath:
      path: /etc/kubernetes/kubeconfigs
EOF

# --- kube-scheduler ---
#
# Decides which node runs each pod. Watches for unscheduled pods,
# scores each node, and binds the pod to the best one.
#
# The simplest control plane component - just needs API access.

echo "Writing kube-scheduler-bootstrap.yaml..."

cat > "${BOOTSTRAP_MANIFESTS}/kube-scheduler-bootstrap.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: kube-scheduler-bootstrap
  namespace: openshift-kube-scheduler
  labels:
    app: openshift-kube-scheduler
spec:
  hostNetwork: true
  containers:
  - name: kube-scheduler
    image: ${HYPERKUBE}
    command:
    - hyperkube
    - kube-scheduler
    - --kubeconfig=/etc/kubernetes/kubeconfigs/kube-scheduler.kubeconfig
    - --authentication-kubeconfig=/etc/kubernetes/kubeconfigs/kube-scheduler.kubeconfig
    - --authorization-kubeconfig=/etc/kubernetes/kubeconfigs/kube-scheduler.kubeconfig
    - --leader-elect=true
    - --leader-elect-retry-period=3s
    - --leader-elect-resource-lock=leases
    - --v=2
    volumeMounts:
    - name: kubeconfigs
      mountPath: /etc/kubernetes/kubeconfigs
      readOnly: true
    livenessProbe:
      httpGet:
        path: /healthz
        port: 10259
        scheme: HTTPS
      initialDelaySeconds: 45
      periodSeconds: 10
    resources:
      requests:
        memory: 128Mi
        cpu: 100m
  volumes:
  - name: kubeconfigs
    hostPath:
      path: /etc/kubernetes/kubeconfigs
EOF

echo ""
echo "=== Static Pod Manifests Generated ==="
echo ""
echo "Files:"
ls -la "${BOOTSTRAP_MANIFESTS}"/*.yaml
echo ""
echo "These manifests will be embedded into bootstrap ignition (Stage 08)."
echo "Kubelet will read them from /etc/kubernetes/manifests/ and start the control plane."
echo ""
echo "On the bootstrap node, kubelet starts these in order:"
echo "  1. etcd (must be healthy before API server can start)"
echo "  2. kube-apiserver (connects to etcd, serves the API)"
echo "  3. kube-controller-manager (runs control loops)"
echo "  4. kube-scheduler (schedules pods to nodes)"
