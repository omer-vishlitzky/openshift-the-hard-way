#!/bin/bash
# Extract OpenShift API CRDs from the release image.
#
# Why this is needed:
#   A bare Kubernetes API server doesn't know about OpenShift types like
#   Infrastructure, Network, DNS, ClusterVersion, ClusterOperator, etc.
#   These are Custom Resource Definitions (CRDs) that extend the API.
#
#   CVO needs these CRDs to exist BEFORE it starts, because its informers
#   watch these types. Without them, CVO can't initialize.
#
# Where the CRDs come from:
#   1. cluster-config-api image: 95 CRDs for OpenShift config types
#      (Infrastructure, Network, DNS, OAuth, Ingress, etc.)
#   2. CVO render: 2 CRDs for CVO's own types
#      (ClusterVersion, ClusterOperator)
#
# In the real installer, bootkube.sh runs cluster-config-api render and
# CVO render to produce these. We extract them ahead of time.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/cluster-vars.sh"
source "${SCRIPT_DIR}/component-images.sh"

CRDS_DIR="${MANIFESTS_DIR}/openshift-crds"
mkdir -p "${CRDS_DIR}"

echo "=== Extracting OpenShift CRDs ==="

# Get cluster-config-api image from release
API_IMAGE=$(oc adm release info "${RELEASE_IMAGE}" \
    --registry-config="${PULL_SECRET_FILE}" \
    --image-for=cluster-config-api)
echo "cluster-config-api: ${API_IMAGE}"

# Extract CRDs from cluster-config-api
echo "Extracting config API CRDs..."
CONTAINER_ID=$(podman create --authfile "${PULL_SECRET_FILE}" "${API_IMAGE}")
podman cp "${CONTAINER_ID}":/manifests/. /tmp/othw-api-crds/
podman rm "${CONTAINER_ID}" >/dev/null
cp /tmp/othw-api-crds/*.crd.yaml "${CRDS_DIR}/"
rm -rf /tmp/othw-api-crds
echo "  $(ls "${CRDS_DIR}"/*.crd.yaml | wc -l) CRDs from cluster-config-api"

# Extract CRDs from CVO render (ClusterVersion + ClusterOperator)
echo "Extracting CVO CRDs..."
mkdir -p /tmp/othw-cvo-render
podman run --rm --authfile "${PULL_SECRET_FILE}" \
    -v /tmp/othw-cvo-render:/output:z \
    "${RELEASE_IMAGE}" \
    render --output-dir=/output --release-image="${RELEASE_IMAGE}" \
    2>/dev/null
cp /tmp/othw-cvo-render/manifests/0000_00_cluster-version-operator_01_cluster*.yaml "${CRDS_DIR}/" 2>/dev/null
rm -rf /tmp/othw-cvo-render
echo "  Added ClusterVersion and ClusterOperator CRDs"

echo ""
echo "=== CRDs Extracted ==="
echo "Total: $(ls "${CRDS_DIR}"/*.yaml | wc -l) CRDs in ${CRDS_DIR}"
