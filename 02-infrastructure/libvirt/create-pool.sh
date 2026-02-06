#!/bin/bash
# Create libvirt storage pool for OpenShift VMs

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../config/cluster-vars.sh"

echo "Creating libvirt storage pool: ${LIBVIRT_POOL}"

# Check if pool already exists
if virsh pool-info "${LIBVIRT_POOL}" &>/dev/null; then
    echo "Pool ${LIBVIRT_POOL} already exists"
    virsh pool-info "${LIBVIRT_POOL}"
    exit 0
fi

# Create directory for pool
sudo mkdir -p "${LIBVIRT_POOL_PATH}"
sudo chown qemu:qemu "${LIBVIRT_POOL_PATH}" || sudo chown libvirt-qemu:libvirt-qemu "${LIBVIRT_POOL_PATH}" || true
sudo chmod 755 "${LIBVIRT_POOL_PATH}"

# Define pool
virsh pool-define-as "${LIBVIRT_POOL}" dir --target "${LIBVIRT_POOL_PATH}"

# Build and start pool
virsh pool-build "${LIBVIRT_POOL}"
virsh pool-autostart "${LIBVIRT_POOL}"
virsh pool-start "${LIBVIRT_POOL}"

echo ""
echo "Pool created successfully:"
virsh pool-info "${LIBVIRT_POOL}"
