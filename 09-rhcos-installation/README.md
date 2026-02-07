# Stage 09: RHCOS Installation

RHCOS is the immutable OS that OpenShift runs on. It ships with kubelet and CRI-O baked in — you can't install packages on it. Configuration happens entirely through Ignition at first boot.

## Prerequisites

Before installing any node, you need:

1. **HTTP server** serving ignition files from your host:
   ```bash
   cd assets/ignition
   python3 -m http.server 8080 --bind 0.0.0.0
   ```

2. **Firewall** allowing port 8080 from the VM network:
   ```bash
   sudo firewall-cmd --zone=libvirt --add-port=8080/tcp
   ```

3. **VMs created** with RHCOS ISO attached (Stage 02):
   ```bash
   sudo ./02-infrastructure/libvirt/create-vms.sh
   ```

## Installing a Node

Every node follows the same flow. The only difference is which ignition file you point to.

### Step 1: Start the VM

```bash
sudo virsh start ocp4-bootstrap
```

The VM boots from the RHCOS live ISO. DHCP gives it a temporary IP.

### Step 2: Install to disk

Open the VM console (virt-manager or `sudo virt-viewer ocp4-bootstrap`) and run:

```bash
sudo coreos-installer install /dev/vda \
  --ignition-url=http://192.168.126.1:8080/bootstrap.ign \
  --insecure-ignition
sudo reboot
```

The VM shuts off after reboot (CDROM boot behavior).

### Step 3: Start from disk

```bash
sudo virsh start ocp4-bootstrap
```

The node now boots from disk with ignition applied. It has its static IP, certificates, kubelet config — everything baked in.

## Node-specific ignition files

| Node | Ignition file | Static IP |
|------|--------------|-----------|
| bootstrap | `bootstrap.ign` | 192.168.126.100 |
| master-0 | `master-0.ign` | 192.168.126.101 |
| master-1 | `master-1.ign` | 192.168.126.102 |
| master-2 | `master-2.ign` | 192.168.126.103 |
| worker-0 | `worker-0.ign` | 192.168.126.110 |
| worker-1 | `worker-1.ign` | 192.168.126.111 |

## Installation order

1. **Bootstrap first.** Wait for API server to be healthy before booting masters.
2. **Masters next.** They register with the bootstrap API server.
3. **Workers last.** After the control plane is up and operators are converging.

## Verification

After a node boots from disk:

```bash
ssh core@<node-ip>
sudo crictl pods          # static pods running?
sudo journalctl -u kubelet  # kubelet healthy?
```

## What's Next

In [Stage 10](../10-bootstrap/README.md), we verify the bootstrap control plane and apply cluster manifests.
