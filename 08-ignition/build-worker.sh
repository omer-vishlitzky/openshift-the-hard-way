#!/bin/bash
# Build worker ignition configs — one per worker node.
#
# Same pattern as build-master.sh: MCO rendered ignition as base,
# plus per-node static IP and bootstrap kubeconfig.
# Workers don't need kube-proxy (masters handle ClusterIP routing).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/cluster-vars.sh"

MCO_WORKER_IGN="${ASSETS_DIR}/mco-rendered/worker-ignition.json"

if [[ ! -f "${MCO_WORKER_IGN}" ]]; then
    echo "ERROR: MCO rendered worker ignition not found: ${MCO_WORKER_IGN}"
    echo "Run 04-release-image/extract-mco-config.sh first."
    exit 1
fi

mkdir -p "${IGNITION_DIR}"

build_worker_ign() {
    local idx=$1
    local ip=$2
    local name=$3
    local output="${IGNITION_DIR}/worker-${idx}.ign"

    echo "Building worker-${idx}.ign (${name}, ${ip})..."

    local ssh_key=$(cat "${SSH_PUB_KEY}")

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

    encode_string() { echo "data:text/plain;charset=utf-8;base64,$(echo -n "$1" | base64 -w0)"; }
    encode_file()   { echo "data:text/plain;charset=utf-8;base64,$(base64 -w0 "$1")"; }

    local nm_src=$(encode_string "$nm_conn")
    local ca_src=$(encode_file "${PKI_DIR}/kubernetes-ca.crt")
    local kc_src=$(encode_file "${ASSETS_DIR}/kubeconfigs/kubelet-bootstrap.kubeconfig")
    local ps_src=$(encode_file "${PULL_SECRET_FILE}")

    jq --arg ssh_key "$ssh_key" \
       --arg nm_src "$nm_src" \
       --arg ca_src "$ca_src" \
       --arg kc_src "$kc_src" \
       --arg ps_src "$ps_src" \
    '
    .passwd.users = [{"name": "core", "sshAuthorizedKeys": [$ssh_key]}]

    | .storage.files += [
        {"path": "/etc/NetworkManager/system-connections/ens3.nmconnection", "contents": {"source": $nm_src}, "mode": 384},
        {"path": "/etc/kubernetes/kubeconfig", "contents": {"source": $kc_src}, "mode": 384},
        {"path": "/etc/kubernetes/ca.crt", "contents": {"source": $ca_src}, "mode": 420},
        {"path": "/var/lib/kubelet/config.json", "contents": {"source": $ps_src}, "mode": 384}
      ]
    ' "${MCO_WORKER_IGN}" > "${output}"

    jq . "${output}" > /dev/null && echo "  OK ($(du -h "${output}" | cut -f1))" || echo "  ERROR: invalid JSON"
}

echo "=== Building Worker Ignition Configs ==="
echo "Base: MCO rendered worker ignition"
echo ""
build_worker_ign 0 "${WORKER0_IP}" "${WORKER0_NAME}"
build_worker_ign 1 "${WORKER1_IP}" "${WORKER1_NAME}"
echo ""
echo "Done. Each worker has MCO's OS config + per-node static IP."
