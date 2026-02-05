#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../config/cluster-vars.sh
source "${ROOT_DIR}/config/cluster-vars.sh"
if [[ -f "${ROOT_DIR}/config/release-image.sh" ]]; then
  # shellcheck source=../config/release-image.sh
  source "${ROOT_DIR}/config/release-image.sh"
fi

if ! command -v oc >/dev/null 2>&1; then
  echo "oc is required"
  exit 1
fi

if [[ -z "${PULL_SECRET:-}" ]]; then
  echo "Set PULL_SECRET to the path of your pull secret JSON"
  exit 1
fi

if [[ -z "${RELEASE_IMAGE:-}" ]]; then
  echo "RELEASE_IMAGE is not set. Run scripts/05-resolve-release.sh first."
  exit 1
fi

OUT_DIR="${ROOT_DIR}/generated/release-manifests"
mkdir -p "${OUT_DIR}"

oc adm release extract --registry-config "${PULL_SECRET}" --from "${RELEASE_IMAGE}" --to "${OUT_DIR}"

echo "Release manifests extracted to ${OUT_DIR}"
