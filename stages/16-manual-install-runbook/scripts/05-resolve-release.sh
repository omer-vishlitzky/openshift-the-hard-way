#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../config/cluster-vars.sh
source "${ROOT_DIR}/config/cluster-vars.sh"

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required"
  exit 1
fi

CHANNEL_URL="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${RELEASE_CHANNEL}/release.txt"

RELEASE_IMAGE=$(curl -sL "${CHANNEL_URL}" | awk -F': ' '/Pull From/ {print $2; exit}')
RELEASE_VERSION=$(curl -sL "${CHANNEL_URL}" | awk -F': ' '/Name/ {print $2; exit}')

if [[ -z "${RELEASE_IMAGE}" ]]; then
  echo "Failed to resolve release image from ${CHANNEL_URL}"
  exit 1
fi

cat > "${ROOT_DIR}/config/release-image.sh" <<EOFREL
RELEASE_CHANNEL=${RELEASE_CHANNEL}
RELEASE_VERSION=${RELEASE_VERSION}
RELEASE_IMAGE=${RELEASE_IMAGE}
EOFREL

echo "Resolved release image: ${RELEASE_IMAGE} (${RELEASE_VERSION})"
