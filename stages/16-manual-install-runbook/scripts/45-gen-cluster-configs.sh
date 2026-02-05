#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../config/cluster-vars.sh
source "${ROOT_DIR}/config/cluster-vars.sh"
if [[ -f "${ROOT_DIR}/config/release-image.sh" ]]; then
  # shellcheck source=../config/release-image.sh
  source "${ROOT_DIR}/config/release-image.sh"
fi

CLUSTER_ID=$(cat "${ROOT_DIR}/config/cluster-id.txt")
if [[ -z "${RELEASE_VERSION:-}" || -z "${RELEASE_IMAGE:-}" || -z "${RELEASE_CHANNEL:-}" ]]; then
  echo "Release metadata missing. Run scripts/05-resolve-release.sh first."
  exit 1
fi

OUT_DIR="${ROOT_DIR}/generated/cluster-config"
TEMPLATES_DIR="${ROOT_DIR}/templates/cluster-config"
mkdir -p "${OUT_DIR}"

export CLUSTER_DOMAIN
export BASE_DOMAIN
export CLUSTER_CIDR
export SERVICE_CIDR
export RELEASE_CHANNEL
export RELEASE_VERSION
export RELEASE_IMAGE
export CLUSTER_ID

for tpl in "${TEMPLATES_DIR}"/*.tpl; do
  name=$(basename "${tpl}" .tpl)
  envsubst < "${tpl}" > "${OUT_DIR}/${name}"
done

echo "Cluster config manifests rendered in ${OUT_DIR}"
