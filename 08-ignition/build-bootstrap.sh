#!/bin/bash
# Build bootstrap ignition config
#
# This creates a complete bootstrap.ign that includes:
# - All PKI certificates and keys
# - All kubeconfigs
# - bootkube.sh orchestration script
# - Static pod manifests (hand-written in Stage 07)
# - Cluster manifests
# - kubelet and bootkube systemd units

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/cluster-vars.sh"
source "${SCRIPT_DIR}/../04-release-image/component-images.sh"

mkdir -p "${IGNITION_DIR}"

OUTPUT_FILE="${IGNITION_DIR}/bootstrap.ign"

echo "=== Building Bootstrap Ignition ==="
echo ""

# Helper function to encode file as data URL
encode_file() {
    local file=$1
    local mime=${2:-"text/plain"}
    echo "data:${mime};charset=utf-8;base64,$(base64 -w0 "$file")"
}

# Helper function to encode string as data URL
encode_string() {
    local content=$1
    echo "data:text/plain;charset=utf-8;base64,$(echo -n "$content" | base64 -w0)"
}

# Start building ignition
cat > "${OUTPUT_FILE}" <<'IGNITION_START'
{
  "ignition": {
    "version": "3.2.0"
  },
  "passwd": {
    "users": [
      {
        "name": "core",
        "sshAuthorizedKeys": [
IGNITION_START

# Add SSH key
SSH_KEY=$(cat "${SSH_PUB_KEY}")
echo "          \"${SSH_KEY}\"" >> "${OUTPUT_FILE}"

cat >> "${OUTPUT_FILE}" <<'IGNITION_USERS_END'
        ]
      }
    ]
  },
  "storage": {
    "files": [
IGNITION_USERS_END

# Add files
files_added=0

add_file() {
    local path=$1
    local source_file=$2
    local mode=$3

    if [[ ! -f "$source_file" ]]; then
        echo "  WARNING: File not found, skipping: $source_file"
        return
    fi

    if [[ $files_added -gt 0 ]]; then
        echo "," >> "${OUTPUT_FILE}"
    fi
    files_added=$((files_added + 1))

    local encoded=$(encode_file "$source_file")
    cat >> "${OUTPUT_FILE}" <<EOF
      {
        "path": "${path}",
        "contents": { "source": "${encoded}" },
        "mode": ${mode}
      }
EOF
    echo "  Added: ${path}"
}

add_file_content() {
    local path=$1
    local content=$2
    local mode=$3

    if [[ $files_added -gt 0 ]]; then
        echo "," >> "${OUTPUT_FILE}"
    fi
    files_added=$((files_added + 1))

    local encoded=$(encode_string "$content")
    cat >> "${OUTPUT_FILE}" <<EOF
      {
        "path": "${path}",
        "contents": { "source": "${encoded}" },
        "mode": ${mode}
      }
EOF
    echo "  Added: ${path}"
}

# === Static Network Config ===
# Each node gets a NetworkManager connection file with its static IP.
echo "Adding network config..."
NETWORK_CONFIG=$(cat <<NETEOF
[connection]
id=ens3
type=ethernet
autoconnect=true

[ipv4]
method=manual
addresses=${BOOTSTRAP_IP}/24
gateway=${GATEWAY}
dns=${DNS_SERVER}

[ipv6]
method=disabled
NETEOF
)
add_file_content "/etc/NetworkManager/system-connections/ens3.nmconnection" "${NETWORK_CONFIG}" 384

# === CRI-O Config ===
# Tell CRI-O to use the OpenShift pause image (not registry.k8s.io/pause)
# and where to find pull credentials.
echo "Adding CRI-O config..."
CRIO_CONFIG=$(cat <<CRIOEOF
[crio.image]
pause_image = "${POD_IMAGE}"
pause_image_auth_file = "/var/lib/kubelet/config.json"
CRIOEOF
)
add_file_content "/etc/crio/crio.conf.d/00-pause.conf" "${CRIO_CONFIG}" 420

# === PKI Certificates ===
echo "Adding PKI certificates..."

# CA certificates (public)
add_file "/etc/kubernetes/bootstrap-secrets/root-ca.crt" "${PKI_DIR}/root-ca.crt" 420
add_file "/etc/kubernetes/bootstrap-secrets/etcd-ca.crt" "${PKI_DIR}/etcd-ca.crt" 420
add_file "/etc/kubernetes/bootstrap-secrets/kubernetes-ca.crt" "${PKI_DIR}/kubernetes-ca.crt" 420
add_file "/etc/kubernetes/bootstrap-secrets/front-proxy-ca.crt" "${PKI_DIR}/front-proxy-ca.crt" 420

# CA keys (needed for bootstrap to sign certs)
add_file "/etc/kubernetes/bootstrap-secrets/root-ca.key" "${PKI_DIR}/root-ca.key" 384
add_file "/etc/kubernetes/bootstrap-secrets/etcd-ca.key" "${PKI_DIR}/etcd-ca.key" 384
add_file "/etc/kubernetes/bootstrap-secrets/kubernetes-ca.key" "${PKI_DIR}/kubernetes-ca.key" 384

# etcd certificates
add_file "/etc/kubernetes/bootstrap-secrets/etcd-peer.crt" "${PKI_DIR}/etcd-peer-bootstrap.crt" 420
add_file "/etc/kubernetes/bootstrap-secrets/etcd-peer.key" "${PKI_DIR}/etcd-peer-bootstrap.key" 384
add_file "/etc/kubernetes/bootstrap-secrets/etcd-server.crt" "${PKI_DIR}/etcd-server.crt" 420
add_file "/etc/kubernetes/bootstrap-secrets/etcd-server.key" "${PKI_DIR}/etcd-server.key" 384
add_file "/etc/kubernetes/bootstrap-secrets/etcd-client.crt" "${PKI_DIR}/etcd-client.crt" 420
add_file "/etc/kubernetes/bootstrap-secrets/etcd-client.key" "${PKI_DIR}/etcd-client.key" 384

# API server certificates
add_file "/etc/kubernetes/bootstrap-secrets/kube-apiserver.crt" "${PKI_DIR}/kube-apiserver.crt" 420
add_file "/etc/kubernetes/bootstrap-secrets/kube-apiserver.key" "${PKI_DIR}/kube-apiserver.key" 384
add_file "/etc/kubernetes/bootstrap-secrets/kube-apiserver-kubelet-client.crt" "${PKI_DIR}/kube-apiserver-kubelet-client.crt" 420
add_file "/etc/kubernetes/bootstrap-secrets/kube-apiserver-kubelet-client.key" "${PKI_DIR}/kube-apiserver-kubelet-client.key" 384

# Front proxy (aggregation layer)
add_file "/etc/kubernetes/bootstrap-secrets/front-proxy-client.crt" "${PKI_DIR}/front-proxy-client.crt" 420
add_file "/etc/kubernetes/bootstrap-secrets/front-proxy-client.key" "${PKI_DIR}/front-proxy-client.key" 384

# Service account keys
add_file "/etc/kubernetes/bootstrap-secrets/service-account.key" "${PKI_DIR}/service-account.key" 384
add_file "/etc/kubernetes/bootstrap-secrets/service-account.pub" "${PKI_DIR}/service-account.pub" 420

# Admin certificate
add_file "/etc/kubernetes/bootstrap-secrets/admin.crt" "${PKI_DIR}/admin.crt" 420
add_file "/etc/kubernetes/bootstrap-secrets/admin.key" "${PKI_DIR}/admin.key" 384

# === Kubeconfigs ===
echo "Adding kubeconfigs..."
add_file "/etc/kubernetes/kubeconfigs/localhost.kubeconfig" "${ASSETS_DIR}/kubeconfigs/localhost.kubeconfig" 384
add_file "/etc/kubernetes/kubeconfigs/admin.kubeconfig" "${ASSETS_DIR}/kubeconfigs/admin.kubeconfig" 384
add_file "/etc/kubernetes/kubeconfigs/kube-controller-manager.kubeconfig" "${ASSETS_DIR}/kubeconfigs/kube-controller-manager.kubeconfig" 384
add_file "/etc/kubernetes/kubeconfigs/kube-scheduler.kubeconfig" "${ASSETS_DIR}/kubeconfigs/kube-scheduler.kubeconfig" 384
add_file "/etc/kubernetes/kubeconfigs/kubelet-bootstrap.kubeconfig" "${ASSETS_DIR}/kubeconfigs/kubelet-bootstrap.kubeconfig" 384

# === Pull Secret ===
echo "Adding pull secret..."
add_file "/var/lib/kubelet/config.json" "${PULL_SECRET_FILE}" 384

# === bootkube.sh ===
echo "Adding bootkube.sh..."
add_file "/usr/local/bin/bootkube.sh" "${SCRIPT_DIR}/components/bootkube.sh" 493

# === Image References ===
echo "Adding image references..."
IMAGE_REFS=$(cat <<EOF
RELEASE_IMAGE=${RELEASE_IMAGE}
ETCD_IMAGE=${ETCD_IMAGE}
HYPERKUBE_IMAGE=${HYPERKUBE_IMAGE}
POD_IMAGE=${POD_IMAGE}
EOF
)
add_file_content "/etc/kubernetes/bootstrap-images.env" "${IMAGE_REFS}" 420

# === Cluster Config ===
echo "Adding cluster configuration..."
CLUSTER_CONFIG=$(cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-config
  namespace: kube-system
data:
  cluster-name: "${CLUSTER_NAME}"
  base-domain: "${BASE_DOMAIN}"
  api-server-url: "${API_URL}"
  machine-network: "${MACHINE_NETWORK}"
  cluster-network-cidr: "${CLUSTER_NETWORK_CIDR}"
  service-network-cidr: "${SERVICE_NETWORK_CIDR}"
EOF
)
add_file_content "/opt/openshift/manifests/cluster-config.yaml" "${CLUSTER_CONFIG}" 420

# === Static Pod Manifests (if pre-rendered) ===
echo "Adding static pod manifests..."
if [[ -d "${MANIFESTS_DIR}/bootstrap-manifests" ]]; then
    for manifest in "${MANIFESTS_DIR}/bootstrap-manifests"/*.yaml; do
        if [[ -f "$manifest" ]]; then
            add_file "/etc/kubernetes/manifests/$(basename "$manifest")" "$manifest" 420
        fi
    done
fi

# === Cluster Manifests ===
echo "Adding cluster manifests..."
if [[ -d "${MANIFESTS_DIR}/cluster-manifests" ]]; then
    for manifest in "${MANIFESTS_DIR}/cluster-manifests"/*.yaml; do
        if [[ -f "$manifest" ]]; then
            add_file "/opt/openshift/manifests/$(basename "$manifest")" "$manifest" 420
        fi
    done
fi

# === OpenShift API CRDs ===
# These define the OpenShift API types (Infrastructure, Network, DNS, ClusterVersion, etc.)
# CVO needs them to exist before it can start its informers.
echo "Adding OpenShift API CRDs..."
if [[ -d "${MANIFESTS_DIR}/openshift-crds" ]]; then
    for crd in "${MANIFESTS_DIR}/openshift-crds"/*.yaml; do
        if [[ -f "$crd" ]]; then
            add_file "/opt/openshift/crds/$(basename "$crd")" "$crd" 420
        fi
    done
fi

# === Create manifests directory marker ===
add_file_content "/etc/kubernetes/manifests/.keep" "" 420

# Close files array
cat >> "${OUTPUT_FILE}" <<'IGNITION_FILES_END'
    ],
    "directories": [
      { "path": "/opt/openshift", "mode": 493 },
      { "path": "/opt/openshift/manifests", "mode": 493 },
      { "path": "/opt/openshift/crds", "mode": 493 },
      { "path": "/etc/kubernetes/manifests", "mode": 493 },
      { "path": "/etc/kubernetes/bootstrap-secrets", "mode": 448 },
      { "path": "/etc/kubernetes/kubeconfigs", "mode": 448 }
    ]
  },
  "systemd": {
    "units": [
IGNITION_FILES_END

# Add systemd units
units_added=0

add_unit() {
    local name=$1
    local enabled=$2
    local contents=$3

    if [[ $units_added -gt 0 ]]; then
        echo "," >> "${OUTPUT_FILE}"
    fi
    units_added=$((units_added + 1))

    # Escape the contents for JSON
    local escaped=$(echo "$contents" | jq -Rs .)

    cat >> "${OUTPUT_FILE}" <<EOF
      {
        "name": "${name}",
        "enabled": ${enabled},
        "contents": ${escaped}
      }
EOF
    echo "  Added unit: ${name}"
}

add_unit_from_file() {
    local name=$1
    local enabled=$2
    local source_file=$3

    if [[ ! -f "$source_file" ]]; then
        echo "  WARNING: Unit file not found, skipping: $source_file"
        return
    fi

    local contents=$(cat "$source_file")
    add_unit "$name" "$enabled" "$contents"
}

echo "Adding systemd units..."

# kubelet.service
KUBELET_UNIT=$(cat <<'UNITEOF'
[Unit]
Description=Kubernetes Kubelet
Wants=rpc-statd.service network-online.target crio.service
After=network-online.target crio.service

[Service]
Type=notify
ExecStart=/usr/bin/kubelet \
  --anonymous-auth=false \
  --container-runtime-endpoint=/var/run/crio/crio.sock \
  --pod-manifest-path=/etc/kubernetes/manifests \
  --cluster-domain=cluster.local \
  --cgroup-driver=systemd \
  --v=2
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNITEOF
)
add_unit "kubelet.service" "true" "${KUBELET_UNIT}"

# bootkube.service
BOOTKUBE_UNIT=$(cat <<'UNITEOF'
[Unit]
Description=Bootstrap the OpenShift cluster
Wants=kubelet.service
After=kubelet.service crio.service
ConditionPathExists=/usr/local/bin/bootkube.sh
ConditionPathExists=!/opt/openshift/.bootkube.done

[Service]
Type=oneshot
WorkingDirectory=/opt/openshift
ExecStart=/usr/local/bin/bootkube.sh
Restart=on-failure
RestartSec=5
RemainAfterExit=true
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UNITEOF
)
add_unit "bootkube.service" "true" "${BOOTKUBE_UNIT}"

# Close systemd units and root object
cat >> "${OUTPUT_FILE}" <<'IGNITION_END'
    ]
  }
}
IGNITION_END

# Validate JSON
if jq . "${OUTPUT_FILE}" > /dev/null 2>&1; then
    echo ""
    echo "=== Bootstrap Ignition Built ==="
    echo "Output: ${OUTPUT_FILE}"
    echo "Size: $(du -h "${OUTPUT_FILE}" | cut -f1)"
    echo "Files embedded: ${files_added}"
    echo "Systemd units: ${units_added}"
    echo ""
    echo "Verify with: jq . ${OUTPUT_FILE} | head -50"
else
    echo "ERROR: Generated invalid JSON!"
    echo "Debug with: cat ${OUTPUT_FILE} | python3 -m json.tool"
    exit 1
fi
