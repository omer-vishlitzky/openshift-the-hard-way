# Stage 01: Prerequisites

Before starting, you need:
1. The right tools installed
2. Access to Red Hat resources
3. Understanding of what we're building

## Tools Required

### Container Runtime

```bash
# Podman (preferred) or Docker
sudo dnf install -y podman

# Verify
podman --version
```

We use podman to:
- Extract the release image
- Run operator render containers
- Build Ignition files

### OpenShift CLI

```bash
# Download from Red Hat
curl -L https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz | \
  sudo tar -xz -C /usr/local/bin oc kubectl

# Verify
oc version --client
```

### OpenShift Installer (for reference)

We won't use `openshift-install` to install the cluster, but we'll use it to:
- Examine what it produces
- Extract manifests for comparison

```bash
curl -L https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-install-linux.tar.gz | \
  sudo tar -xz -C /usr/local/bin openshift-install

# Verify
openshift-install version
```

### libvirt/KVM

```bash
# Install libvirt and dependencies
sudo dnf install -y \
  libvirt \
  libvirt-devel \
  qemu-kvm \
  virt-install \
  virt-manager \
  bridge-utils

# Start and enable libvirtd
sudo systemctl enable --now libvirtd

# Add your user to libvirt group
sudo usermod -aG libvirt $USER

# Verify (may need to log out and back in)
virsh list --all
```

### HAProxy (for load balancer)

```bash
sudo dnf install -y haproxy

# We'll configure it in stage 02
```

### dnsmasq (for DNS)

```bash
sudo dnf install -y dnsmasq

# We'll configure it in stage 02
```

### OpenSSL

```bash
# Usually pre-installed
openssl version

# We need 1.1.1+ for some certificate operations
```

### jq (JSON processing)

```bash
sudo dnf install -y jq
```

### Other utilities

```bash
sudo dnf install -y \
  nmstate \
  coreos-installer \
  butane \
  wget \
  curl \
  git
```

## Red Hat Account

### Pull Secret

Required to pull OpenShift container images.

1. Go to https://console.redhat.com/openshift/install/pull-secret
2. Download the pull secret
3. Save to `~/pull-secret.json`

```bash
# Verify pull secret is valid JSON
jq . ~/pull-secret.json > /dev/null && echo "Pull secret valid"
```

### RHCOS Images

We'll download these in stage 02, but verify access:

```bash
curl -I https://mirror.openshift.com/pub/openshift-v4/dependencies/rhcos/4.14/latest/rhcos-live.x86_64.iso
```

## SSH Key

You need an SSH key to access the nodes:

```bash
# Generate if you don't have one
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""

# Verify
cat ~/.ssh/id_rsa.pub
```

## System Requirements

### Host Machine

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| CPU | 8 cores | 16+ cores |
| RAM | 32 GB | 64+ GB |
| Disk | 200 GB | 500+ GB SSD |

The host runs:
- 1 Bootstrap VM (16 GB RAM, 4 vCPU)
- 3 Master VMs (16 GB RAM each, 4 vCPU)
- 2 Worker VMs (8 GB RAM each, 4 vCPU)
- DNS and load balancer services

### Network

Your host needs:
- A network bridge or NAT network for VMs
- Ability to run dnsmasq (or existing DNS)
- Ability to run HAProxy (or existing LB)
- No firewall blocking VM traffic

## Knowledge Prerequisites

This guide assumes you understand:

### Kubernetes Basics
- Pods, Deployments, Services
- Static pods vs regular pods
- API server, etcd, controller-manager, scheduler
- kubelet, container runtime

### Networking
- IP addressing, CIDR notation
- DNS (A records, PTR records, SRV records)
- Load balancing (Layer 4 vs Layer 7)
- TLS/certificates

### Linux
- systemd services
- File permissions
- SELinux basics
- Firewall basics

If you're missing any of these, Kubernetes the Hard Way is an excellent prerequisite.

## Verification Script

Run this to check all prerequisites:

```bash
./verify.sh
```

## What's Next

In [Stage 02](../02-infrastructure/README.md), we set up:
- libvirt network and storage pool
- VMs for all nodes
- DNS with dnsmasq
- Load balancer with HAProxy
