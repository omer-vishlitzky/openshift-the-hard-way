#!/bin/bash
# Build master ignition configs — one per master node.
#
# Uses MCO's rendered master ignition as the base. MCO provides everything a
# RHCOS node needs at the OS level (OVS bridges, kubelet.service, CRI-O config,
# SELinux, NetworkManager scripts, etc.).
#
# We add three things MCO doesn't know about:
#   1. Static IP — MCO renders generic config; we add per-node NetworkManager profiles
#   2. kube-proxy — needed to bootstrap ClusterIP routing before OVN takes over
#   3. kubelet-bootstrap.kubeconfig — we skip MCS, so we embed the bootstrap kubeconfig directly

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/cluster-vars.sh"
source "${SCRIPT_DIR}/../04-release-image/component-images.sh"

MCO_MASTER_IGN="${ASSETS_DIR}/mco-rendered/master-ignition.json"

if [[ ! -f "${MCO_MASTER_IGN}" ]]; then
    echo "ERROR: MCO rendered master ignition not found: ${MCO_MASTER_IGN}"
    echo "Run 04-release-image/extract-mco-config.sh first."
    exit 1
fi

mkdir -p "${IGNITION_DIR}"

build_master_ign() {
    local idx=$1
    local ip=$2
    local name=$3
    local output="${IGNITION_DIR}/master-${idx}.ign"

    echo "Building master-${idx}.ign (${name}, ${ip})..."

    # Start from MCO's rendered ignition and merge our additions.
    # jq merges: MCO base + our files + our units + SSH key.
    local ssh_key=$(cat "${SSH_PUB_KEY}")

    # Per-node static IP
    local nm_conn="[connection]
id=ens3
type=ethernet
autoconnect=true

[ipv4]
method=manual
addresses=${ip}/24
gateway=${GATEWAY}
dns=${DNS_SERVER}

[ipv6]
method=disabled"

    # kube-proxy: translates Service ClusterIPs to real endpoint IPs via iptables.
    # Without it, operators can't reach the API at 172.30.0.1:443 and all crash.
    # OVN-Kubernetes replaces kube-proxy later, but kube-proxy bootstraps it.
    local kube_proxy_pod="apiVersion: v1
kind: Pod
metadata:
  name: kube-proxy
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
  - name: kube-proxy
    image: ${KUBE_PROXY_IMAGE}
    command:
    - /usr/bin/kube-proxy
    - --kubeconfig=/etc/kubernetes/kubeconfig
    - --cluster-cidr=${CLUSTER_NETWORK_CIDR}
    - --v=2
    securityContext:
      privileged: true
    volumeMounts:
    - name: kubeconfig
      mountPath: /etc/kubernetes/kubeconfig
      readOnly: true
  volumes:
  - name: kubeconfig
    hostPath:
      path: /etc/kubernetes/kubeconfig"

    # Encode files as data URIs
    encode_string() { echo "data:text/plain;charset=utf-8;base64,$(echo -n "$1" | base64 -w0)"; }
    encode_file()   { echo "data:text/plain;charset=utf-8;base64,$(base64 -w0 "$1")"; }

    local nm_src=$(encode_string "$nm_conn")
    local ca_src=$(encode_file "${PKI_DIR}/kubernetes-ca.crt")
    local etcd_ca_src=$(encode_file "${PKI_DIR}/etcd-ca.crt")
    local kc_src=$(encode_file "${ASSETS_DIR}/kubeconfigs/kubelet-bootstrap.kubeconfig")
    local ps_src=$(encode_file "${PULL_SECRET_FILE}")
    local proxy_src=$(encode_string "$kube_proxy_pod")

    # Merge MCO ignition + our extras using jq
    jq --arg ssh_key "$ssh_key" \
       --arg nm_src "$nm_src" \
       --arg ca_src "$ca_src" \
       --arg etcd_ca_src "$etcd_ca_src" \
       --arg kc_src "$kc_src" \
       --arg ps_src "$ps_src" \
       --arg proxy_src "$proxy_src" \
    '
    # Add SSH key
    .passwd.users = [{"name": "core", "sshAuthorizedKeys": [$ssh_key]}]

    # Add our files (MCO files are preserved, ours are appended)
    | .storage.files += [
        {"path": "/etc/NetworkManager/system-connections/ens3.nmconnection", "contents": {"source": $nm_src}, "mode": 384},
        {"path": "/etc/kubernetes/kubeconfig", "contents": {"source": $kc_src}, "mode": 384},
        {"path": "/etc/kubernetes/ca.crt", "contents": {"source": $ca_src}, "mode": 420},
        {"path": "/etc/kubernetes/etcd-ca.crt", "contents": {"source": $etcd_ca_src}, "mode": 420},
        {"path": "/var/lib/kubelet/config.json", "contents": {"source": $ps_src}, "mode": 384},
        {"path": "/etc/kubernetes/manifests/kube-proxy.yaml", "contents": {"source": $proxy_src}, "mode": 420}
      ]

    # Ensure manifests directory exists
    | .storage.directories = (.storage.directories // []) + [
        {"path": "/etc/kubernetes/manifests", "mode": 493}
      ]
    ' "${MCO_MASTER_IGN}" > "${output}"

    jq . "${output}" > /dev/null && echo "  OK ($(du -h "${output}" | cut -f1))" || echo "  ERROR: invalid JSON"
}

echo "=== Building Master Ignition Configs ==="
echo "Base: MCO rendered master ignition"
echo ""
build_master_ign 0 "${MASTER0_IP}" "${MASTER0_NAME}"
build_master_ign 1 "${MASTER1_IP}" "${MASTER1_NAME}"
build_master_ign 2 "${MASTER2_IP}" "${MASTER2_NAME}"
echo ""
echo "Done. Each master has MCO's OS config + per-node static IP + kube-proxy."
