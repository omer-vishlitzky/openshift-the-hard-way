#!/bin/bash
# Helper script for RHCOS installation
#
# RHCOS installation is interactive - you boot from the live ISO
# and run coreos-installer. This script generates the commands
# you need to run on each node.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/cluster-vars.sh"

# Get the HTTP server IP (where ignition files are served)
HTTP_SERVER_IP=${HTTP_SERVER_IP:-$(hostname -I | awk '{print $1}')}
HTTP_PORT=${HTTP_PORT:-8080}

echo "=== RHCOS Installation Commands ==="
echo ""
echo "Prerequisites:"
echo "1. Download RHCOS live ISO from: ${RHCOS_IMAGE_URL}"
echo "2. Boot each VM from the ISO"
echo "3. Serve ignition files: cd ${IGNITION_DIR} && python3 -m http.server ${HTTP_PORT}"
echo ""
echo "-------------------------------------------------------------------"
echo ""

print_install_command() {
    local node_type=$1
    local node_name=$2
    local node_ip=$3

    echo "=== ${node_name} (${node_type}) ==="
    echo ""
    echo "1. Boot VM from RHCOS live ISO"
    echo ""
    echo "2. SSH to the live environment:"
    echo "   ssh core@${node_ip}"
    echo ""
    echo "3. Run the installer:"
    echo ""
    echo "   sudo coreos-installer install /dev/vda \\"
    echo "     --ignition-url=http://${HTTP_SERVER_IP}:${HTTP_PORT}/${node_type}.ign \\"
    echo "     --insecure-ignition"
    echo ""
    echo "4. Reboot:"
    echo "   sudo reboot"
    echo ""
    echo "-------------------------------------------------------------------"
    echo ""
}

# Bootstrap
print_install_command "bootstrap" "${BOOTSTRAP_NAME}" "${BOOTSTRAP_IP}"

# Masters
print_install_command "master" "${MASTER0_NAME}" "${MASTER0_IP}"
print_install_command "master" "${MASTER1_NAME}" "${MASTER1_IP}"
print_install_command "master" "${MASTER2_NAME}" "${MASTER2_IP}"

# Workers
print_install_command "worker" "${WORKER0_NAME}" "${WORKER0_IP}"
print_install_command "worker" "${WORKER1_NAME}" "${WORKER1_IP}"

echo ""
echo "=== Installation Order ==="
echo ""
echo "1. Start HTTP server:"
echo "   cd ${IGNITION_DIR} && python3 -m http.server ${HTTP_PORT}"
echo ""
echo "2. Install and boot BOOTSTRAP first"
echo "   Wait for bootstrap API: curl -k https://${BOOTSTRAP_IP}:6443/healthz"
echo ""
echo "3. Install and boot MASTERS (can be done in parallel)"
echo "   Watch: oc get nodes -w"
echo ""
echo "4. After pivot, install WORKERS"
echo "   Watch: oc get csr"
echo ""
