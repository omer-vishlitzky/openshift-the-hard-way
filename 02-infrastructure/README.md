# Stage 02: Infrastructure

We need:
1. A network for cluster communication
2. VMs for each node
3. DNS that resolves cluster names
4. A load balancer for API and ingress

## Why This Stage Exists

OpenShift has strict infrastructure requirements:

OpenShift components discover each other via DNS:
- API server: `api.cluster.domain`
- Machine Config Server: `api-int.cluster.domain`
- etcd discovery: SRV records for `_etcd-server-ssl._tcp`
- Apps: `*.apps.cluster.domain` wildcard

Without correct DNS, nodes can't find the API server, etcd can't form a cluster, and routes don't work.

**Load balancer is required.** Unlike single-node Kubernetes:
- API needs to be HA across 3 masters
- During bootstrap, traffic goes to bootstrap node first
- After pivot, bootstrap is removed and traffic goes only to masters
- Ingress routes to workers (or masters in compact clusters)

**VMs simulate bare metal.** We use libvirt because:
- It's free and widely available
- VMs behave exactly like physical servers for OpenShift purposes
- We control the network, DNS, and boot process
- Same concepts apply to real hardware

## Network Topology

```
                    ┌─────────────────────────────────────────────────────────────┐
                    │                    Host Machine                             │
                    │                                                             │
                    │  ┌──────────────────────────────────────────────────────┐   │
                    │  │              libvirt network: ocp4                   │   │
                    │  │                192.168.126.0/24                      │   │
                    │  │                                                      │   │
                    │  │   ┌─────────┐  ┌─────────┐  ┌─────────┐              │   │
                    │  │   │Bootstrap│  │Master-0 │  │Master-1 │              │   │
                    │  │   │  .100   │  │  .101   │  │  .102   │              │   │
                    │  │   └────┬────┘  └────┬────┘  └────┬────┘              │   │
                    │  │        │            │            │                   │   │
                    │  │   ┌────┴────┐  ┌────┴────┐  ┌────┴────┐              │   │
                    │  │   │Master-2 │  │Worker-0 │  │Worker-1 │              │   │
                    │  │   │  .103   │  │  .110   │  │  .111   │              │   │
                    │  │   └────┬────┘  └────┬────┘  └────┬────┘              │   │
                    │  │        │            │            │                   │   │
                    │  │   ─────┴────────────┴────────────┴───────────────    │   │
                    │  │                      │                               │   │
                    │  │              ┌───────┴───────┐                       │   │
                    │  │              │  Gateway .1   │                       │   │
                    │  │              │  DNS Server   │                       │   │
                    │  │              │  dnsmasq      │                       │   │
                    │  │              └───────────────┘                       │   │
                    │  │                                                      │   │
                    │  └──────────────────────────────────────────────────────┘   │
                    │                                                             │
                    │  ┌──────────────────┐                                       │
                    │  │ HAProxy LB       │                                       │
                    │  │ API VIP: .10     │  → forwards to :6443 on masters       │
                    │  │ Ingress VIP: .11 │  → forwards to :443,:80 on workers    │
                    │  └──────────────────┘                                       │
                    │                                                             │
                    └─────────────────────────────────────────────────────────────┘
```

### How real OpenShift handles VIPs

In our lab, the host runs HAProxy and holds the VIPs. In a real baremetal cluster, there's no external host — the cluster manages its own VIPs using two components that MCO deploys as static pods on every master:

**keepalived** uses [VRRP](https://en.wikipedia.org/wiki/Virtual_Router_Redundancy_Protocol) to elect one master as the VIP holder. That master adds the VIP to its network interface. If it dies, another master takes over within seconds. Two instances run: one for the API VIP, one for the Ingress VIP.

**HAProxy** runs on every master, but only the VIP holder receives traffic. It load-balances to all masters (API) or all workers (ingress).

```
Real baremetal cluster:

  Master-0 (keepalived BACKUP)     Master-1 (keepalived MASTER)     Master-2 (keepalived BACKUP)
                                     │
                                     │ holds API VIP 192.168.126.10
                                     │ holds Ingress VIP 192.168.126.11
                                     │
                                     ├── HAProxy :6443 → master-0, master-1, master-2
                                     └── HAProxy :443  → worker-0, worker-1
```

MCO renders these static pod manifests (`keepalived.yaml`, `haproxy.yaml`) for `BareMetal` platform. Our platform is `None`, so MCO skips them — we use the host's HAProxy instead.

On cloud platforms (AWS, GCP, Azure), VIPs are replaced by cloud load balancers (NLB, etc.) provisioned by the installer. No keepalived needed.

## Step 1: Configure Cluster Variables

First, review and customize the cluster configuration:

```bash
# Copy the template
cp ../config/cluster-vars.sh ./cluster-vars.sh

# Edit as needed
vim cluster-vars.sh

# Source it
source ./cluster-vars.sh

# Verify
print_config
validate_config
```

Key settings to customize:
- `CLUSTER_NAME` and `BASE_DOMAIN`
- IP addresses (if your network differs)
- `PULL_SECRET_FILE` path
- `SSH_PUB_KEY` path

## Step 2: Create libvirt Network

libvirt networks are defined as XML. Ours needs:
- NAT forwarding (so VMs can reach the internet to pull images)
- DNS entries for every cluster hostname (API, nodes, etcd)
- A DHCP range for the live ISO environment (installed systems use static IPs from ignition)

Write the network definition:

```bash
cat > /tmp/ocp4-net.xml <<EOF
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
    <!-- API and Ingress VIPs -->
    <host ip='${API_VIP}'>
      <hostname>api.${CLUSTER_DOMAIN}</hostname>
      <hostname>api-int.${CLUSTER_DOMAIN}</hostname>
    </host>
    <host ip='${INGRESS_VIP}'>
      <hostname>apps.${CLUSTER_DOMAIN}</hostname>
      <hostname>oauth-openshift.apps.${CLUSTER_DOMAIN}</hostname>
      <hostname>console-openshift-console.apps.${CLUSTER_DOMAIN}</hostname>
    </host>
    <!-- Bootstrap -->
    <host ip='${BOOTSTRAP_IP}'>
      <hostname>${BOOTSTRAP_NAME}.${CLUSTER_DOMAIN}</hostname>
    </host>
    <!-- Masters (each also gets an etcd alias for SRV discovery) -->
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
    <!-- SRV records for etcd peer discovery -->
    <srv service='etcd-server-ssl' protocol='tcp' domain='${CLUSTER_DOMAIN}' target='etcd-0.${CLUSTER_DOMAIN}' port='2380' weight='10'/>
    <srv service='etcd-server-ssl' protocol='tcp' domain='${CLUSTER_DOMAIN}' target='etcd-1.${CLUSTER_DOMAIN}' port='2380' weight='10'/>
    <srv service='etcd-server-ssl' protocol='tcp' domain='${CLUSTER_DOMAIN}' target='etcd-2.${CLUSTER_DOMAIN}' port='2380' weight='10'/>
  </dns>
  <ip address='${GATEWAY}' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.126.200' end='192.168.126.254'/>
    </dhcp>
  </ip>
</network>
EOF
```

The `<dns>` block is doing the work of a separate dnsmasq setup — libvirt's built-in dnsmasq serves these records to VMs on this network. The `<srv>` records are how etcd peers discover each other during bootstrap.

The DHCP range (`200-254`) is only used during the live ISO boot. Once RHCOS is installed, each node uses the static IP baked into its ignition config.

Define, autostart, and start the network:

```bash
virsh net-define /tmp/ocp4-net.xml
virsh net-autostart ${LIBVIRT_NETWORK}
virsh net-start ${LIBVIRT_NETWORK}
```

Verify it's running:

```bash
virsh net-info ${LIBVIRT_NETWORK}
```

### Enable NAT forwarding

VMs need internet access to pull container images. libvirt sets up NAT automatically, but firewalld often overrides it. Add explicit rules:

```bash
HOST_IFACE=$(ip route get 8.8.8.8 | grep -oP 'dev \K\S+')
iptables -t nat -A POSTROUTING -s ${MACHINE_NETWORK} -o ${HOST_IFACE} -j MASQUERADE
iptables -I FORWARD -s ${MACHINE_NETWORK} -j ACCEPT
iptables -I FORWARD -d ${MACHINE_NETWORK} -j ACCEPT
```

### Add VIPs to the libvirt bridge

HAProxy on the host needs to bind to the API and Ingress VIPs. These IPs must exist on the libvirt bridge interface so VMs can reach them:

```bash
ip addr add ${API_VIP}/24 dev virbr-${LIBVIRT_NETWORK} 2>/dev/null || true
ip addr add ${INGRESS_VIP}/24 dev virbr-${LIBVIRT_NETWORK} 2>/dev/null || true
```

Verify the VIPs are on the bridge:

```bash
ip addr show virbr-${LIBVIRT_NETWORK} | grep inet
```

You should see `.1` (gateway), `.10` (API VIP), and `.11` (Ingress VIP).

## Step 3: Create libvirt Storage Pool

A storage pool tells libvirt where to store VM disk images. It's just a directory on the host.

```bash
mkdir -p ${LIBVIRT_POOL_PATH}
virsh pool-define-as ${LIBVIRT_POOL} dir --target ${LIBVIRT_POOL_PATH}
virsh pool-build ${LIBVIRT_POOL}
virsh pool-autostart ${LIBVIRT_POOL}
virsh pool-start ${LIBVIRT_POOL}
```

Verify:

```bash
virsh pool-info ${LIBVIRT_POOL}
```

## Step 4: Verify DNS

DNS is already configured — the libvirt network XML from Step 2 includes all the records. libvirt runs its own dnsmasq instance that serves them to VMs on the network.

Verify from the host:

```bash
dig @${GATEWAY} api.${CLUSTER_DOMAIN} +short
dig @${GATEWAY} ${MASTER0_NAME}.${CLUSTER_DOMAIN} +short
dig @${GATEWAY} _etcd-server-ssl._tcp.${CLUSTER_DOMAIN} SRV +short
```

You should see `192.168.126.10`, `192.168.126.101`, and three SRV records pointing to `etcd-0/1/2`.

**Note on apps wildcard:** libvirt DNS doesn't support wildcard records. The network XML includes explicit entries for `console-openshift-console.apps` and `oauth-openshift.apps` which are needed during bootstrap. If operators create new routes later, add them to the network XML:

```bash
virsh net-update ${LIBVIRT_NETWORK} add dns-host \
  "<host ip='${INGRESS_VIP}'><hostname>NEW-ROUTE.apps.${CLUSTER_DOMAIN}</hostname></host>" \
  --live --config
```

## Step 5: Configure Load Balancer

OpenShift needs a load balancer for four ports:

| Port | Purpose | Backends |
|------|---------|----------|
| 6443 | Kubernetes API | bootstrap + masters (remove bootstrap after pivot) |
| 22623 | Machine Config Server | bootstrap + masters |
| 80 | Ingress HTTP | workers |
| 443 | Ingress HTTPS | workers |

Allow HAProxy to bind to any port (SELinux blocks non-standard ports like 6443 and 22623 by default):

```bash
sudo setsebool -P haproxy_connect_any=1
```

Write the HAProxy configuration:

```bash
cat > /tmp/haproxy.cfg <<EOF
global
    log /dev/log local0
    chroot /var/lib/haproxy
    maxconn 4000
    user haproxy
    group haproxy
    daemon
    stats socket /var/lib/haproxy/stats

defaults
    mode tcp
    log global
    option tcplog
    option dontlognull
    option redispatch
    retries 3
    timeout queue 1m
    timeout connect 10s
    timeout client 1m
    timeout server 1m
    timeout check 10s
    maxconn 3000

listen stats
    bind *:9000
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s

frontend kubernetes-api
    bind *:6443
    default_backend kubernetes-api-backend

backend kubernetes-api-backend
    balance roundrobin
    server ${BOOTSTRAP_NAME} ${BOOTSTRAP_IP}:6443 check
    server ${MASTER0_NAME} ${MASTER0_IP}:6443 check
    server ${MASTER1_NAME} ${MASTER1_IP}:6443 check
    server ${MASTER2_NAME} ${MASTER2_IP}:6443 check

frontend machine-config-server
    bind *:22623
    default_backend machine-config-server-backend

backend machine-config-server-backend
    balance roundrobin
    server ${BOOTSTRAP_NAME} ${BOOTSTRAP_IP}:22623 check
    server ${MASTER0_NAME} ${MASTER0_IP}:22623 check
    server ${MASTER1_NAME} ${MASTER1_IP}:22623 check
    server ${MASTER2_NAME} ${MASTER2_IP}:22623 check

frontend ingress-http
    bind *:80
    default_backend ingress-http-backend

backend ingress-http-backend
    balance roundrobin
    server ${WORKER0_NAME} ${WORKER0_IP}:80 check
    server ${WORKER1_NAME} ${WORKER1_IP}:80 check

frontend ingress-https
    bind *:443
    default_backend ingress-https-backend

backend ingress-https-backend
    balance roundrobin
    server ${WORKER0_NAME} ${WORKER0_IP}:443 check
    server ${WORKER1_NAME} ${WORKER1_IP}:443 check
EOF
```

All frontends are TCP mode — HAProxy passes through TLS without terminating it. The API server and ingress routers handle their own TLS.

Install and start:

```bash
sudo cp /tmp/haproxy.cfg /etc/haproxy/haproxy.cfg
sudo systemctl enable --now haproxy
```

Open firewall ports so VMs can reach HAProxy through the libvirt bridge:

```bash
sudo firewall-cmd --zone=libvirt --add-port=6443/tcp
sudo firewall-cmd --zone=libvirt --add-port=22623/tcp
sudo firewall-cmd --zone=libvirt --add-port=80/tcp
sudo firewall-cmd --zone=libvirt --add-port=443/tcp
```

Verify HAProxy is listening:

```bash
ss -tlnp | grep haproxy
```

Stats page at http://localhost:9000/stats — all backends will show DOWN until VMs are running.

## Step 6: Download RHCOS

Download the RHCOS live ISO into the libvirt pool directory (qemu needs to read it from there):

```bash
curl -L -o ${LIBVIRT_POOL_PATH}/rhcos-live.x86_64.iso ${RHCOS_IMAGE_URL}
```

This is ~1GB. Verify:

```bash
file ${LIBVIRT_POOL_PATH}/rhcos-live.x86_64.iso
```

Should say `ISO 9660`.

## Step 7: Create VMs

Each VM gets a qcow2 disk (thin-provisioned — starts near zero, grows as data is written) and the RHCOS ISO attached as a CDROM. Boot order is `hd,cdrom` — first boot falls through empty disk to CDROM, after install it boots from disk.

We define VMs without starting them. They'll be started later in Stage 09 after ignition configs are built.

Create the disks:

```bash
for name in bootstrap master-0 master-1 master-2 worker-0 worker-1; do
  qemu-img create -f qcow2 ${LIBVIRT_POOL_PATH}/${CLUSTER_NAME}-${name}.qcow2 100G
done
```

Define bootstrap VM:

```bash
virt-install \
  --name ${CLUSTER_NAME}-bootstrap \
  --vcpus ${BOOTSTRAP_VCPUS} --memory ${BOOTSTRAP_MEMORY} \
  --disk path=${LIBVIRT_POOL_PATH}/${CLUSTER_NAME}-bootstrap.qcow2,format=qcow2 \
  --disk ${LIBVIRT_POOL_PATH}/rhcos-live.x86_64.iso,device=cdrom,readonly=on \
  --network network=${LIBVIRT_NETWORK},model=virtio \
  --os-variant rhel9-unknown \
  --boot hd,cdrom \
  --graphics vnc,listen=0.0.0.0 \
  --noautoconsole \
  --print-xml | virsh define /dev/stdin
```

Define master VMs:

```bash
for i in 0 1 2; do
  virt-install \
    --name ${CLUSTER_NAME}-master-${i} \
    --vcpus ${MASTER_VCPUS} --memory ${MASTER_MEMORY} \
    --disk path=${LIBVIRT_POOL_PATH}/${CLUSTER_NAME}-master-${i}.qcow2,format=qcow2 \
    --disk ${LIBVIRT_POOL_PATH}/rhcos-live.x86_64.iso,device=cdrom,readonly=on \
    --network network=${LIBVIRT_NETWORK},model=virtio \
    --os-variant rhel9-unknown \
    --boot hd,cdrom \
    --graphics vnc,listen=0.0.0.0 \
    --noautoconsole \
    --print-xml | virsh define /dev/stdin
done
```

Define worker VMs:

```bash
for i in 0 1; do
  virt-install \
    --name ${CLUSTER_NAME}-worker-${i} \
    --vcpus ${WORKER_VCPUS} --memory ${WORKER_MEMORY} \
    --disk path=${LIBVIRT_POOL_PATH}/${CLUSTER_NAME}-worker-${i}.qcow2,format=qcow2 \
    --disk ${LIBVIRT_POOL_PATH}/rhcos-live.x86_64.iso,device=cdrom,readonly=on \
    --network network=${LIBVIRT_NETWORK},model=virtio \
    --os-variant rhel9-unknown \
    --boot hd,cdrom \
    --graphics vnc,listen=0.0.0.0 \
    --noautoconsole \
    --print-xml | virsh define /dev/stdin
done
```

Verify all 6 VMs are defined:

```bash
virsh list --all
```

```
 Id   Name                State
------------------------------------
 -    ocp4-bootstrap      shut off
 -    ocp4-master-0       shut off
 -    ocp4-master-1       shut off
 -    ocp4-master-2       shut off
 -    ocp4-worker-0       shut off
 -    ocp4-worker-1       shut off
```

## What's Next

In [Stage 03](../03-understanding-the-installer/README.md), we examine what `openshift-install` produces to understand what we need to create manually.
