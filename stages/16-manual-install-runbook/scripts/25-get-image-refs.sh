#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../config/cluster-vars.sh
source "${ROOT_DIR}/config/cluster-vars.sh"

if ! command -v oc >/dev/null 2>&1; then
  echo "oc is required"
  exit 1
fi

if [[ -z "${PULL_SECRET:-}" ]]; then
  echo "Set PULL_SECRET to the path of your pull secret JSON"
  exit 1
fi

OUT_FILE="${ROOT_DIR}/config/image-refs.sh"

get_image() {
  local name=$1
  oc adm release info --registry-config "${PULL_SECRET}" "${RELEASE_IMAGE}" \
    -o jsonpath="{.references.spec.tags[?(@.name=='${name}')].from.name}"
}

ETCD_IMAGE=$(get_image etcd)
KUBE_APISERVER_IMAGE=$(get_image kube-apiserver)
KUBE_CONTROLLER_MANAGER_IMAGE=$(get_image kube-controller-manager)
KUBE_SCHEDULER_IMAGE=$(get_image kube-scheduler)

cat > "${OUT_FILE}" <<EOFIMG
ETCD_IMAGE=${ETCD_IMAGE}
KUBE_APISERVER_IMAGE=${KUBE_APISERVER_IMAGE}
KUBE_CONTROLLER_MANAGER_IMAGE=${KUBE_CONTROLLER_MANAGER_IMAGE}
KUBE_SCHEDULER_IMAGE=${KUBE_SCHEDULER_IMAGE}
EOFIMG

echo "Wrote image refs to ${OUT_FILE}"
