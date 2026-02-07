#!/bin/bash
# Create VMs for OpenShift cluster.
# Copies RHCOS ISO and ignition files to the libvirt pool,
# creates each VM with the ISO attached as CDROM.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../config/cluster-vars.sh"

ISO_SRC="${ASSETS_DIR}/rhcos/rhcos-live.x86_64.iso"
ISO_DST="${LIBVIRT_POOL_PATH}/rhcos-live.x86_64.iso"

# Copy ISO where qemu can read it
if [[ ! -f "${ISO_DST}" ]]; then
    echo "Copying RHCOS ISO to ${LIBVIRT_POOL_PATH}/"
    cp "${ISO_SRC}" "${ISO_DST}"
fi

# Copy ignition files where qemu can read them
echo "Copying ignition files to ${LIBVIRT_POOL_PATH}/"
cp "${IGNITION_DIR}"/*.ign "${LIBVIRT_POOL_PATH}/" 2>/dev/null || true

create_vm() {
    local name=$1
    local vcpus=$2
    local memory=$3
    local disk_size=$4

    local full_name="${CLUSTER_NAME}-${name}"
    local disk_path="${LIBVIRT_POOL_PATH}/${full_name}.qcow2"

    if virsh dominfo "${full_name}" &>/dev/null; then
        echo "  ${full_name} already exists, skipping"
        return
    fi

    echo "Creating ${full_name}..."
    [[ ! -f "${disk_path}" ]] && qemu-img create -f qcow2 "${disk_path}" "${disk_size}G"

    # --cdrom starts the VM immediately. We use --disk device=cdrom instead
    # so we can define-only without starting.
    virt-install \
        --name "${full_name}" \
        --vcpus "${vcpus}" \
        --memory "${memory}" \
        --disk "path=${disk_path},format=qcow2" \
        --disk "${ISO_DST},device=cdrom,readonly=on" \
        --network "network=${LIBVIRT_NETWORK},model=virtio" \
        --os-variant "rhel9-unknown" \
        --boot "hd,cdrom" \
        --graphics "vnc,listen=0.0.0.0" \
        --noautoconsole \
        --print-xml > "/tmp/${full_name}.xml" 2>/dev/null

    virsh define "/tmp/${full_name}.xml"
    rm "/tmp/${full_name}.xml"
}

echo "=== Creating OpenShift VMs ==="
create_vm "bootstrap" "${BOOTSTRAP_VCPUS}" "${BOOTSTRAP_MEMORY}" "${BOOTSTRAP_DISK}"
create_vm "master-0" "${MASTER_VCPUS}" "${MASTER_MEMORY}" "${MASTER_DISK}"
create_vm "master-1" "${MASTER_VCPUS}" "${MASTER_MEMORY}" "${MASTER_DISK}"
create_vm "master-2" "${MASTER_VCPUS}" "${MASTER_MEMORY}" "${MASTER_DISK}"
create_vm "worker-0" "${WORKER_VCPUS}" "${WORKER_MEMORY}" "${WORKER_DISK}"
create_vm "worker-1" "${WORKER_VCPUS}" "${WORKER_MEMORY}" "${WORKER_DISK}"

echo ""
virsh list --all | grep "${CLUSTER_NAME}"
