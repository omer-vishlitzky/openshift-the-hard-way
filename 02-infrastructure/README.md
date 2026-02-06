# Stage 02: Infrastructure

We need:
1. A network for cluster communication
2. VMs for each node
3. DNS that resolves cluster names
4. A load balancer for API and ingress

## Network Topology

```
                    ┌─────────────────────────────────────────────────────────────┐
                    │                    Host Machine                             │
                    │                                                             │
                    │  ┌──────────────────────────────────────────────────────┐   │
                    │  │              libvirt network: ocp4                   │   │
                    │  │                192.168.126.0/24                      │   │
                    │  │                                                      │   │
                    │  │   ┌─────────┐  ┌─────────┐  ┌─────────┐             │   │
                    │  │   │Bootstrap│  │Master-0 │  │Master-1 │             │   │
                    │  │   │  .100   │  │  .101   │  │  .102   │             │   │
                    │  │   └────┬────┘  └────┬────┘  └────┬────┘             │   │
                    │  │        │            │            │                   │   │
                    │  │   ┌────┴────┐  ┌────┴────┐  ┌────┴────┐             │   │
                    │  │   │Master-2 │  │Worker-0 │  │Worker-1 │             │   │
                    │  │   │  .103   │  │  .110   │  │  .111   │             │   │
                    │  │   └────┬────┘  └────┬────┘  └────┬────┘             │   │
                    │  │        │            │            │                   │   │
                    │  │   ─────┴────────────┴────────────┴───────────────   │   │
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
                    │  │ API VIP: .10     │  → forwards to :6443 on masters      │
                    │  │ Ingress VIP: .11 │  → forwards to :443,:80 on workers   │
                    │  └──────────────────┘                                       │
                    │                                                             │
                    └─────────────────────────────────────────────────────────────┘
```

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

```bash
./libvirt/create-network.sh
```

This creates an isolated network with:
- DHCP disabled (we use static IPs)
- NAT for external access
- The gateway at .1

## Step 3: Create libvirt Storage Pool

```bash
./libvirt/create-pool.sh
```

This creates a storage pool for VM disks.

## Step 4: Configure DNS

OpenShift requires specific DNS records. Without them, installation fails.

### Required Records

| Record | Type | Value |
|--------|------|-------|
| `api.ocp4.example.com` | A | 192.168.126.10 (API VIP) |
| `api-int.ocp4.example.com` | A | 192.168.126.10 (API VIP) |
| `*.apps.ocp4.example.com` | A | 192.168.126.11 (Ingress VIP) |
| `bootstrap.ocp4.example.com` | A | 192.168.126.100 |
| `master-0.ocp4.example.com` | A | 192.168.126.101 |
| `master-1.ocp4.example.com` | A | 192.168.126.102 |
| `master-2.ocp4.example.com` | A | 192.168.126.103 |
| `worker-0.ocp4.example.com` | A | 192.168.126.110 |
| `worker-1.ocp4.example.com` | A | 192.168.126.111 |
| `etcd-0.ocp4.example.com` | A | 192.168.126.101 |
| `etcd-1.ocp4.example.com` | A | 192.168.126.102 |
| `etcd-2.ocp4.example.com` | A | 192.168.126.103 |
| `_etcd-server-ssl._tcp.ocp4.example.com` | SRV | 0 10 2380 etcd-X.ocp4.example.com |

### Setup dnsmasq

```bash
./dns/setup-dnsmasq.sh
```

This configures dnsmasq to:
- Serve DNS for the cluster domain
- Forward other queries upstream
- Listen on the libvirt bridge

### Verify DNS

```bash
./dns/verify-dns.sh
```

Expected output:
```
api.ocp4.example.com → 192.168.126.10 ✓
api-int.ocp4.example.com → 192.168.126.10 ✓
test.apps.ocp4.example.com → 192.168.126.11 ✓
bootstrap.ocp4.example.com → 192.168.126.100 ✓
...
```

## Step 5: Configure Load Balancer

OpenShift needs a load balancer for:
- **API** (port 6443): Routes to masters (and bootstrap during install)
- **Machine Config Server** (port 22623): Routes to masters (and bootstrap during install)
- **Ingress HTTP** (port 80): Routes to workers (or masters in compact cluster)
- **Ingress HTTPS** (port 443): Routes to workers (or masters in compact cluster)

### Setup HAProxy

```bash
./haproxy/setup-haproxy.sh
```

This configures HAProxy with:
- API backend: bootstrap + all masters
- MCS backend: bootstrap + all masters
- Ingress backends: all workers (or masters if no workers)

### Verify Load Balancer

```bash
./haproxy/verify-haproxy.sh
```

Check HAProxy stats at http://localhost:9000/stats

## Step 6: Create VMs

Now create the VMs (without booting them yet):

```bash
# Create all VMs
./libvirt/create-vms.sh

# List VMs
virsh list --all
```

Output:
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

## Step 7: Download RHCOS

```bash
./libvirt/download-rhcos.sh
```

This downloads the RHCOS live ISO that we'll use to boot and install nodes.

## Verification Checklist

Run the full verification:

```bash
./verify.sh
```

- [ ] libvirt network `ocp4` exists and is active
- [ ] libvirt pool `ocp4` exists and is active
- [ ] DNS resolves `api.ocp4.example.com` to API VIP
- [ ] DNS resolves `*.apps.ocp4.example.com` to Ingress VIP
- [ ] DNS resolves all node names
- [ ] DNS has SRV records for etcd
- [ ] HAProxy is running
- [ ] HAProxy can reach the API port (6443)
- [ ] All VMs are created
- [ ] RHCOS ISO is downloaded

## Failure Signals

### DNS not resolving
- Check dnsmasq is running: `systemctl status dnsmasq`
- Check dnsmasq config: `/etc/dnsmasq.d/ocp4.conf`
- Check host's `/etc/resolv.conf` uses the DNS server

### HAProxy not starting
- Check config syntax: `haproxy -c -f /etc/haproxy/haproxy.cfg`
- Check port conflicts: `ss -tlnp | grep -E '6443|22623|80|443'`

### VMs not creating
- Check libvirt pool has space: `virsh pool-info ocp4`
- Check permissions on pool directory

## What's Next

In [Stage 03](../03-understanding-the-installer/README.md), we examine what `openshift-install` produces to understand what we need to create manually.
