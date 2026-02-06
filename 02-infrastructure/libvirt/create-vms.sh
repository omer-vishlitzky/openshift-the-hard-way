#!/bin/bash
# Create VMs for OpenShift cluster

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../config/cluster-vars.sh"

create_vm() {
    local name=$1
    local vcpus=$2
    local memory=$3
    local disk_size=$4
    local ip=$5

    local full_name="${CLUSTER_NAME}-${name}"
    local disk_path="${LIBVIRT_POOL_PATH}/${full_name}.qcow2"

    echo "Creating VM: ${full_name}"

    # Check if VM already exists
    if virsh dominfo "${full_name}" &>/dev/null; then
        echo "  VM ${full_name} already exists, skipping"
        return
    fi

    # Create disk
    if [[ ! -f "${disk_path}" ]]; then
        echo "  Creating disk: ${disk_path} (${disk_size}GB)"
        sudo qemu-img create -f qcow2 "${disk_path}" "${disk_size}G"
        sudo chown qemu:qemu "${disk_path}" 2>/dev/null || sudo chown libvirt-qemu:libvirt-qemu "${disk_path}" 2>/dev/null || true
    fi

    # Create VM
    virt-install \
        --name "${full_name}" \
        --vcpus "${vcpus}" \
        --memory "${memory}" \
        --disk "path=${disk_path},format=qcow2" \
        --network "network=${LIBVIRT_NETWORK},model=virtio" \
        --os-variant "rhel9-unknown" \
        --boot "hd,cdrom" \
        --graphics "vnc,listen=0.0.0.0" \
        --noautoconsole \
        --print-xml > "/tmp/${full_name}.xml"

    virsh define "/tmp/${full_name}.xml"
    rm "/tmp/${full_name}.xml"

    echo "  VM ${full_name} created (not started)"
}

echo "=== Creating OpenShift VMs ==="
echo ""

# Bootstrap
create_vm "bootstrap" "${BOOTSTRAP_VCPUS}" "${BOOTSTRAP_MEMORY}" "${BOOTSTRAP_DISK}" "${BOOTSTRAP_IP}"

# Masters
create_vm "master-0" "${MASTER_VCPUS}" "${MASTER_MEMORY}" "${MASTER_DISK}" "${MASTER0_IP}"
create_vm "master-1" "${MASTER_VCPUS}" "${MASTER_MEMORY}" "${MASTER_DISK}" "${MASTER1_IP}"
create_vm "master-2" "${MASTER_VCPUS}" "${MASTER_MEMORY}" "${MASTER_DISK}" "${MASTER2_IP}"

# Workers
create_vm "worker-0" "${WORKER_VCPUS}" "${WORKER_MEMORY}" "${WORKER_DISK}" "${WORKER0_IP}"
create_vm "worker-1" "${WORKER_VCPUS}" "${WORKER_MEMORY}" "${WORKER_DISK}" "${WORKER1_IP}"

echo ""
echo "=== VM Summary ==="
virsh list --all | grep "${CLUSTER_NAME}"
