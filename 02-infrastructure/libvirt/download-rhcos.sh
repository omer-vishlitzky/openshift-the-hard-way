#!/bin/bash
# Download RHCOS live ISO

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../config/cluster-vars.sh"

RHCOS_DIR="${ASSETS_DIR}/rhcos"
ISO_FILE="${RHCOS_DIR}/rhcos-live.x86_64.iso"

mkdir -p "${RHCOS_DIR}"

if [[ -f "${ISO_FILE}" ]]; then
    echo "RHCOS ISO already exists: ${ISO_FILE}"
    ls -lh "${ISO_FILE}"
    exit 0
fi

echo "Downloading RHCOS live ISO..."
echo "URL: ${RHCOS_IMAGE_URL}"
echo "Destination: ${ISO_FILE}"
echo ""

curl -L -o "${ISO_FILE}" "${RHCOS_IMAGE_URL}"

echo ""
echo "Download complete:"
ls -lh "${ISO_FILE}"

# Verify it's a valid ISO
file "${ISO_FILE}" | grep -q "ISO 9660" && echo "ISO verified" || echo "WARNING: File may not be a valid ISO"
