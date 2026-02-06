# Stage 09: RHCOS Installation

Red Hat CoreOS (RHCOS) is the operating system for OpenShift nodes. This stage covers installing RHCOS using our Ignition configs.

## What is RHCOS?

RHCOS is:
- An immutable, container-focused OS
- Based on Fedora CoreOS / RHEL
- Configured entirely via Ignition at first boot
- Updated atomically via rpm-ostree
- Managed by the Machine Config Operator after bootstrap

RHCOS is NOT:
- A general-purpose Linux distribution
- Configured via package managers (yum/dnf disabled)
- Modified manually (changes are overwritten)

## Installation Methods

### Method 1: Live ISO with coreos-installer

Boot the RHCOS live ISO and run coreos-installer:

```bash
# On the live system
sudo coreos-installer install /dev/sda \
  --ignition-url=http://webserver.example.com/bootstrap.ign \
  --insecure-ignition
```

### Method 2: PXE Boot

Boot via PXE with kernel arguments:

```
kernel: rhcos-live-kernel
initrd: rhcos-live-initramfs.img
args: coreos.inst.install_dev=/dev/sda \
      coreos.inst.ignition_url=http://webserver.example.com/bootstrap.ign \
      coreos.live.rootfs_url=http://webserver.example.com/rhcos-live-rootfs.img
```

### Method 3: Pre-installed disk image

For VMs, you can use the QCOW2 image directly:

```bash
# Download QCOW2
curl -O https://mirror.openshift.com/.../rhcos-qemu.x86_64.qcow2.gz

# Decompress
gunzip rhcos-qemu.x86_64.qcow2.gz

# Create VM disk from base image
qemu-img create -f qcow2 -F qcow2 -b rhcos-qemu.x86_64.qcow2 node-disk.qcow2 100G
```

## Installing Bootstrap

### Step 1: Attach Live ISO

```bash
virsh attach-disk ${CLUSTER_NAME}-bootstrap \
  ${ASSETS_DIR}/rhcos/rhcos-live.x86_64.iso \
  sda --type cdrom --mode readonly
```

### Step 2: Start VM and connect

```bash
virsh start ${CLUSTER_NAME}-bootstrap
virsh console ${CLUSTER_NAME}-bootstrap
```

### Step 3: Install to disk

On the live system:

```bash
# Set network (if DHCP not available)
sudo nmcli con add type ethernet con-name eth0 ifname eth0 \
  ipv4.addresses 192.168.126.100/24 \
  ipv4.gateway 192.168.126.1 \
  ipv4.dns 192.168.126.1 \
  ipv4.method manual

sudo nmcli con up eth0

# Install RHCOS
sudo coreos-installer install /dev/vda \
  --ignition-url=http://192.168.126.1:8080/bootstrap.ign \
  --insecure-ignition

# Reboot
sudo reboot
```

### Step 4: Verify bootstrap starts

After reboot, SSH in:

```bash
ssh core@192.168.126.100

# Check kubelet
sudo systemctl status kubelet

# Check bootkube
sudo journalctl -u bootkube -f

# Check static pods
sudo crictl pods
```

## Installing Masters

Repeat for each master (master-0, master-1, master-2):

### Step 1: Boot live ISO

### Step 2: Configure network

```bash
# master-0 example
sudo nmcli con add type ethernet con-name eth0 ifname eth0 \
  ipv4.addresses 192.168.126.101/24 \
  ipv4.gateway 192.168.126.1 \
  ipv4.dns 192.168.126.1 \
  ipv4.method manual

sudo nmcli con up eth0
```

### Step 3: Install with master ignition

```bash
sudo coreos-installer install /dev/vda \
  --ignition-url=http://192.168.126.1:8080/master.ign \
  --insecure-ignition

sudo reboot
```

### Step 4: Verify master joins

```bash
ssh core@192.168.126.101

# Check kubelet
sudo systemctl status kubelet

# Check for node registration (from bootstrap or working master)
export KUBECONFIG=/etc/kubernetes/kubeconfig
oc get nodes
```

## Installing Workers

After the control plane is up:

### Step 1: Boot live ISO on worker

### Step 2: Configure network and install

```bash
sudo coreos-installer install /dev/vda \
  --ignition-url=http://192.168.126.1:8080/worker.ign \
  --insecure-ignition

sudo reboot
```

### Step 3: Approve CSRs

Workers require CSR approval:

```bash
# On a machine with admin kubeconfig
export KUBECONFIG=${ASSETS_DIR}/kubeconfigs/admin.kubeconfig

# List pending CSRs
oc get csr

# Approve all pending
oc get csr -o name | xargs oc adm certificate approve
```

## Serving Ignition Files

You need a web server to serve ignition files:

```bash
# Simple Python server
cd ${IGNITION_DIR}
python3 -m http.server 8080

# Or use nginx/apache
```

For production, use HTTPS and authentication.

## Kernel Arguments

Common kernel arguments for RHCOS:

| Argument | Purpose |
|----------|---------|
| `coreos.inst.install_dev=/dev/vda` | Target disk |
| `coreos.inst.ignition_url=http://...` | Ignition URL |
| `coreos.inst.insecure` | Allow HTTP ignition |
| `ip=...` | Static IP configuration |
| `rd.neednet=1` | Enable networking in initrd |
| `console=tty0` | Console output |

## Static IP via Kernel Arguments

For static IP during install:

```
ip=192.168.126.100::192.168.126.1:255.255.255.0:bootstrap.ocp4.example.com:eth0:none nameserver=192.168.126.1
```

Format: `ip=<ip>::<gateway>:<netmask>:<hostname>:<interface>:none`

## Verification

After installation:

```bash
# Check ignition ran
sudo journalctl -u ignition-firstboot-complete

# Check RHCOS version
rpm-ostree status

# Check network
ip addr

# Check DNS resolution
dig api.${CLUSTER_DOMAIN}
```

## Troubleshooting

### Ignition fails to fetch
- Check network connectivity
- Verify ignition URL is accessible
- Check firewall rules

### Node doesn't register
- Verify DNS resolves API endpoint
- Check kubelet logs: `journalctl -u kubelet`
- Verify certificates are correct

### Disk not found
- Use correct device name (`/dev/vda` for virtio, `/dev/sda` for SATA)
- Check disk is attached

## What's Next

In [Stage 10](../10-bootstrap/README.md), we monitor the bootstrap process and verify the control plane starts.
