#!/bin/bash
# Build bootstrap ignition config

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

echo "Adding certificates..."
add_file "/etc/kubernetes/bootstrap-secrets/root-ca.crt" "${PKI_DIR}/root-ca.crt" 420
add_file "/etc/kubernetes/bootstrap-secrets/etcd-ca.crt" "${PKI_DIR}/etcd-ca.crt" 420
add_file "/etc/kubernetes/bootstrap-secrets/kubernetes-ca.crt" "${PKI_DIR}/kubernetes-ca.crt" 420

echo "Adding kubeconfigs..."
add_file "/etc/kubernetes/kubeconfig" "${ASSETS_DIR}/kubeconfigs/localhost.kubeconfig" 384

echo "Adding pull secret..."
add_file "/var/lib/kubelet/config.json" "${PULL_SECRET_FILE}" 384

# Add kubelet config
echo "Adding kubelet config..."
KUBELET_CONFIG=$(cat <<'KUBELETCONF'
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: /etc/kubernetes/bootstrap-secrets/kubernetes-ca.crt
authorization:
  mode: Webhook
cgroupDriver: systemd
clusterDNS:
- 172.30.0.10
clusterDomain: cluster.local
containerRuntimeEndpoint: unix:///var/run/crio/crio.sock
staticPodPath: /etc/kubernetes/manifests
KUBELETCONF
)
add_file_content "/etc/kubernetes/kubelet.conf" "${KUBELET_CONFIG}" 420

# Add environment file with image references
echo "Adding image references..."
IMAGE_REFS=$(cat <<EOF
RELEASE_IMAGE=${RELEASE_IMAGE}
ETCD_IMAGE=${ETCD_IMAGE}
KUBE_APISERVER_IMAGE=${KUBE_APISERVER_IMAGE}
CLUSTER_BOOTSTRAP_IMAGE=${CLUSTER_BOOTSTRAP_IMAGE}
MACHINE_CONFIG_OPERATOR_IMAGE=${MACHINE_CONFIG_OPERATOR_IMAGE}
EOF
)
add_file_content "/etc/kubernetes/bootstrap-images.env" "${IMAGE_REFS}" 420

# Close files array
cat >> "${OUTPUT_FILE}" <<'IGNITION_FILES_END'
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
  --config=/etc/kubernetes/kubelet.conf \
  --bootstrap-kubeconfig=/etc/kubernetes/kubeconfig \
  --kubeconfig=/var/lib/kubelet/kubeconfig \
  --container-runtime-endpoint=unix:///var/run/crio/crio.sock \
  --runtime-cgroups=/system.slice/crio.service \
  --node-labels=node-role.kubernetes.io/master=,node.openshift.io/os_id=rhcos \
  --register-with-taints=node-role.kubernetes.io/master=:NoSchedule \
  --pod-infra-container-image=quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:... \
  --v=3
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
After=kubelet.service
ConditionPathExists=/opt/openshift/bootkube.sh
ConditionPathExists=!/opt/openshift/.bootkube.done

[Service]
Type=oneshot
WorkingDirectory=/opt/openshift
ExecStart=/opt/openshift/bootkube.sh
ExecStartPost=/bin/touch /opt/openshift/.bootkube.done
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
else
    echo "ERROR: Generated invalid JSON!"
    exit 1
fi
