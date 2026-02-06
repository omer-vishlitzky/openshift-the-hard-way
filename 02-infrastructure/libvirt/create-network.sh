#!/bin/bash
# Create libvirt network for OpenShift cluster

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../config/cluster-vars.sh"

echo "Creating libvirt network: ${LIBVIRT_NETWORK}"

# Check if network already exists
if virsh net-info "${LIBVIRT_NETWORK}" &>/dev/null; then
    echo "Network ${LIBVIRT_NETWORK} already exists"
    virsh net-info "${LIBVIRT_NETWORK}"
    exit 0
fi

# Extract network address from CIDR
NETWORK_ADDR=$(echo "${MACHINE_NETWORK}" | cut -d'/' -f1)
# First three octets for the network definition
NETWORK_PREFIX=$(echo "${NETWORK_ADDR}" | cut -d'.' -f1-3)

# Create network definition
cat > /tmp/${LIBVIRT_NETWORK}-net.xml <<EOF
<network>
  <name>${LIBVIRT_NETWORK}</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='virbr-${LIBVIRT_NETWORK}' stp='on' delay='0'/>
  <ip address='${NETWORK_PREFIX}.1' netmask='255.255.255.0'>
    <!-- DHCP disabled - we use static IPs -->
  </ip>
</network>
EOF

echo "Network definition:"
cat /tmp/${LIBVIRT_NETWORK}-net.xml
echo ""

# Define and start the network
virsh net-define /tmp/${LIBVIRT_NETWORK}-net.xml
virsh net-autostart "${LIBVIRT_NETWORK}"
virsh net-start "${LIBVIRT_NETWORK}"

echo ""
echo "Network created successfully:"
virsh net-info "${LIBVIRT_NETWORK}"

# Cleanup
rm /tmp/${LIBVIRT_NETWORK}-net.xml
