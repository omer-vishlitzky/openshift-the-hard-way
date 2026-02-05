#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../config/cluster-vars.sh
source "${ROOT_DIR}/config/cluster-vars.sh"
# shellcheck source=../config/image-refs.sh
source "${ROOT_DIR}/config/image-refs.sh"

if [[ -z "${ETCD_IMAGE}" || -z "${KUBE_APISERVER_IMAGE}" || -z "${KUBE_CONTROLLER_MANAGER_IMAGE}" || -z "${KUBE_SCHEDULER_IMAGE}" ]]; then
  echo "Image refs are missing. Run scripts/25-get-image-refs.sh and try again."
  exit 1
fi

OUT_DIR="${ROOT_DIR}/generated/manifests"
TEMPLATES_DIR="${ROOT_DIR}/templates"
mkdir -p "${OUT_DIR}"

ETCD_INITIAL_CLUSTER="${MASTER0}=https://${MASTER0_IP}:2380,${MASTER1}=https://${MASTER1_IP}:2380,${MASTER2}=https://${MASTER2_IP}:2380"
ETCD_SERVERS="https://${MASTER0_IP}:2379,https://${MASTER1_IP}:2379,https://${MASTER2_IP}:2379"

render_for_node() {
  local node=$1
  local node_ip=$2
  local node_dir="${OUT_DIR}/${node}"
  mkdir -p "${node_dir}"

  export NODE_NAME=${node}
  export NODE_IP=${node_ip}
  export ETCD_INITIAL_CLUSTER
  export ETCD_SERVERS
  export ETCD_IMAGE
  export KUBE_APISERVER_IMAGE
  export KUBE_CONTROLLER_MANAGER_IMAGE
  export KUBE_SCHEDULER_IMAGE
  export CLUSTER_CIDR
  export SERVICE_CIDR
  export CLUSTER_NAME

  envsubst < "${TEMPLATES_DIR}/etcd-pod.yaml.tpl" > "${node_dir}/etcd-pod.yaml"
  envsubst < "${TEMPLATES_DIR}/kube-apiserver-pod.yaml.tpl" > "${node_dir}/kube-apiserver-pod.yaml"
  envsubst < "${TEMPLATES_DIR}/kube-controller-manager-pod.yaml.tpl" > "${node_dir}/kube-controller-manager-pod.yaml"
  envsubst < "${TEMPLATES_DIR}/kube-scheduler-pod.yaml.tpl" > "${node_dir}/kube-scheduler-pod.yaml"
}

render_for_node "${MASTER0}" "${MASTER0_IP}"
render_for_node "${MASTER1}" "${MASTER1_IP}"
render_for_node "${MASTER2}" "${MASTER2_IP}"

echo "Static pod manifests rendered in ${OUT_DIR}"
