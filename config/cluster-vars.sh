#!/bin/bash
# Cluster Configuration
# Source this file before running any scripts

# Cluster Identity
export CLUSTER_NAME="ocp4"
export BASE_DOMAIN="example.com"
export CLUSTER_DOMAIN="${CLUSTER_NAME}.${BASE_DOMAIN}"

# OpenShift Version
export OCP_VERSION="4.14.0"
export OCP_RELEASE_IMAGE="quay.io/openshift-release-dev/ocp-release:${OCP_VERSION}-x86_64"

# Networking - Machine Network
export MACHINE_NETWORK="192.168.126.0/24"
export MACHINE_NETWORK_PREFIX="24"

# Networking - Cluster Networks
export CLUSTER_NETWORK_CIDR="10.128.0.0/14"
export CLUSTER_NETWORK_HOST_PREFIX="23"
export SERVICE_NETWORK_CIDR="172.30.0.0/16"

# API and Ingress VIPs (must be in MACHINE_NETWORK, not assigned to any host)
export API_VIP="192.168.126.10"
export INGRESS_VIP="192.168.126.11"

# DNS Server (must resolve cluster DNS records)
export DNS_SERVER="192.168.126.1"

# Gateway
export GATEWAY="192.168.126.1"

# Node IPs
export BOOTSTRAP_IP="192.168.126.100"
export MASTER0_IP="192.168.126.101"
export MASTER1_IP="192.168.126.102"
export MASTER2_IP="192.168.126.103"
export WORKER0_IP="192.168.126.110"
export WORKER1_IP="192.168.126.111"

# Node Names (short names, FQDN = name.CLUSTER_DOMAIN)
export BOOTSTRAP_NAME="bootstrap"
export MASTER0_NAME="master-0"
export MASTER1_NAME="master-1"
export MASTER2_NAME="master-2"
export WORKER0_NAME="worker-0"
export WORKER1_NAME="worker-1"

# SSH Key (will be injected into nodes)
export SSH_PUB_KEY="${HOME}/.ssh/id_rsa.pub"

# Pull Secret (download from console.redhat.com)
export PULL_SECRET_FILE="${HOME}/pull-secret.json"

# Working Directories
export ASSETS_DIR="${PWD}/assets"
export PKI_DIR="${ASSETS_DIR}/pki"
export MANIFESTS_DIR="${ASSETS_DIR}/manifests"
export IGNITION_DIR="${ASSETS_DIR}/ignition"

# libvirt Configuration
export LIBVIRT_NETWORK="ocp4"
export LIBVIRT_POOL="ocp4"
export LIBVIRT_POOL_PATH="/var/lib/libvirt/images/ocp4"

# VM Resources
export BOOTSTRAP_VCPUS="4"
export BOOTSTRAP_MEMORY="16384"  # MB
export BOOTSTRAP_DISK="100"     # GB

export MASTER_VCPUS="4"
export MASTER_MEMORY="16384"
export MASTER_DISK="100"

export WORKER_VCPUS="4"
export WORKER_MEMORY="8192"
export WORKER_DISK="100"

# RHCOS Image
export RHCOS_VERSION="4.14.0"
export RHCOS_IMAGE_URL="https://mirror.openshift.com/pub/openshift-v4/dependencies/rhcos/${OCP_VERSION%.*}/${RHCOS_VERSION}/rhcos-live.x86_64.iso"

# Derived Values (don't modify)
export API_URL="https://api.${CLUSTER_DOMAIN}:6443"
export API_INT_URL="https://api-int.${CLUSTER_DOMAIN}:6443"
export OAUTH_URL="https://oauth-openshift.apps.${CLUSTER_DOMAIN}"

# Validation
validate_config() {
    local errors=0

    if [[ ! -f "${SSH_PUB_KEY}" ]]; then
        echo "ERROR: SSH public key not found: ${SSH_PUB_KEY}"
        errors=$((errors + 1))
    fi

    if [[ ! -f "${PULL_SECRET_FILE}" ]]; then
        echo "ERROR: Pull secret not found: ${PULL_SECRET_FILE}"
        echo "Download from: https://console.redhat.com/openshift/install/pull-secret"
        errors=$((errors + 1))
    fi

    return $errors
}

# Print configuration summary
print_config() {
    echo "=== Cluster Configuration ==="
    echo "Cluster: ${CLUSTER_NAME}.${BASE_DOMAIN}"
    echo "Version: ${OCP_VERSION}"
    echo ""
    echo "Networking:"
    echo "  Machine Network: ${MACHINE_NETWORK}"
    echo "  Cluster Network: ${CLUSTER_NETWORK_CIDR}"
    echo "  Service Network: ${SERVICE_NETWORK_CIDR}"
    echo "  API VIP: ${API_VIP}"
    echo "  Ingress VIP: ${INGRESS_VIP}"
    echo ""
    echo "Nodes:"
    echo "  Bootstrap: ${BOOTSTRAP_NAME} (${BOOTSTRAP_IP})"
    echo "  Master 0:  ${MASTER0_NAME} (${MASTER0_IP})"
    echo "  Master 1:  ${MASTER1_NAME} (${MASTER1_IP})"
    echo "  Master 2:  ${MASTER2_NAME} (${MASTER2_IP})"
    echo "  Worker 0:  ${WORKER0_NAME} (${WORKER0_IP})"
    echo "  Worker 1:  ${WORKER1_NAME} (${WORKER1_IP})"
    echo ""
    echo "URLs:"
    echo "  API: ${API_URL}"
    echo "  Console: https://console-openshift-console.apps.${CLUSTER_DOMAIN}"
}
