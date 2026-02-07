#!/bin/bash
# Create libvirt network for OpenShift cluster
# Includes DNS entries - no separate dnsmasq setup needed

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

# Create network definition with DNS
cat > /tmp/${LIBVIRT_NETWORK}-net.xml <<EOF
<network>
  <name>${LIBVIRT_NETWORK}</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='virbr-${LIBVIRT_NETWORK}' stp='on' delay='0'/>
  <domain name='${CLUSTER_DOMAIN}' localOnly='yes'/>
  <dns>
    <!-- API VIP -->
    <host ip='${API_VIP}'>
      <hostname>api.${CLUSTER_DOMAIN}</hostname>
      <hostname>api-int.${CLUSTER_DOMAIN}</hostname>
    </host>
    <!-- Ingress VIP (apps wildcard handled by dnsmasq below) -->
    <host ip='${INGRESS_VIP}'>
      <hostname>apps.${CLUSTER_DOMAIN}</hostname>
      <hostname>oauth-openshift.apps.${CLUSTER_DOMAIN}</hostname>
      <hostname>console-openshift-console.apps.${CLUSTER_DOMAIN}</hostname>
    </host>
    <!-- Bootstrap -->
    <host ip='${BOOTSTRAP_IP}'>
      <hostname>${BOOTSTRAP_NAME}.${CLUSTER_DOMAIN}</hostname>
    </host>
    <!-- Masters -->
    <host ip='${MASTER0_IP}'>
      <hostname>${MASTER0_NAME}.${CLUSTER_DOMAIN}</hostname>
      <hostname>etcd-0.${CLUSTER_DOMAIN}</hostname>
    </host>
    <host ip='${MASTER1_IP}'>
      <hostname>${MASTER1_NAME}.${CLUSTER_DOMAIN}</hostname>
      <hostname>etcd-1.${CLUSTER_DOMAIN}</hostname>
    </host>
    <host ip='${MASTER2_IP}'>
      <hostname>${MASTER2_NAME}.${CLUSTER_DOMAIN}</hostname>
      <hostname>etcd-2.${CLUSTER_DOMAIN}</hostname>
    </host>
    <!-- Workers -->
    <host ip='${WORKER0_IP}'>
      <hostname>${WORKER0_NAME}.${CLUSTER_DOMAIN}</hostname>
    </host>
    <host ip='${WORKER1_IP}'>
      <hostname>${WORKER1_NAME}.${CLUSTER_DOMAIN}</hostname>
    </host>
    <!-- SRV records for etcd discovery -->
    <srv service='etcd-server-ssl' protocol='tcp' domain='${CLUSTER_DOMAIN}' target='etcd-0.${CLUSTER_DOMAIN}' port='2380' weight='10'/>
    <srv service='etcd-server-ssl' protocol='tcp' domain='${CLUSTER_DOMAIN}' target='etcd-1.${CLUSTER_DOMAIN}' port='2380' weight='10'/>
    <srv service='etcd-server-ssl' protocol='tcp' domain='${CLUSTER_DOMAIN}' target='etcd-2.${CLUSTER_DOMAIN}' port='2380' weight='10'/>
  </dns>
  <ip address='${GATEWAY}' netmask='255.255.255.0'>
    <!-- DHCP for live ISO environment only. Installed systems use static IPs from ignition. -->
    <dhcp>
      <range start='192.168.126.200' end='192.168.126.254'/>
    </dhcp>
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

# Enable NAT forwarding so VMs can reach the internet (for pulling images).
# Libvirt sets this up automatically, but firewalld often overrides it.
HOST_IFACE=$(ip route get 8.8.8.8 | grep -oP 'dev \K\S+')
echo ""
echo "Enabling NAT forwarding for ${MACHINE_NETWORK} via ${HOST_IFACE}..."
iptables -t nat -A POSTROUTING -s ${MACHINE_NETWORK} -o ${HOST_IFACE} -j MASQUERADE
iptables -I FORWARD -s ${MACHINE_NETWORK} -j ACCEPT
iptables -I FORWARD -d ${MACHINE_NETWORK} -j ACCEPT
echo "NAT forwarding enabled."

# Add API and Ingress VIPs to the bridge interface.
# HAProxy binds to these IPs. Without them, VMs can't reach the API via the VIP.
BRIDGE_IFACE="virbr-${LIBVIRT_NETWORK}"
echo ""
echo "Adding VIPs to ${BRIDGE_IFACE}..."
ip addr add ${API_VIP}/24 dev ${BRIDGE_IFACE} 2>/dev/null || true
ip addr add ${INGRESS_VIP}/24 dev ${BRIDGE_IFACE} 2>/dev/null || true
echo "  API VIP: ${API_VIP}"
echo "  Ingress VIP: ${INGRESS_VIP}"
