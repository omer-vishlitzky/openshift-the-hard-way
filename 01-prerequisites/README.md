# Stage 01: Prerequisites

Before starting, you need:
1. The right tools installed
2. Access to Red Hat resources
3. Understanding of what we're building

## Why This Stage Exists

Unlike `kubeadm` which works with minimal setup, OpenShift installation requires specific tools and resources:

- **podman**: Used to extract component images from the release payload.
- **Pull secret**: OpenShift images are hosted in authenticated registries. Without a valid pull secret, you can't pull any images.
- **OpenSSL**: We generate many certificates manually. Understanding PKI is essential for debugging certificate errors.
- **libvirt**: VMs are the simplest way to simulate bare metal. Real installations work identically.

Skipping prerequisites leads to cryptic failures later. Spending time here saves debugging time later.

## Tools Required

### Container Runtime

```bash
# Podman (preferred) or Docker
sudo dnf install -y podman

# Verify
podman --version
```

We use podman to:
- Extract component image references from the release image

### OpenShift CLI

```bash
# Download from Red Hat
curl -L https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz | \
  sudo tar -xz -C /usr/local/bin oc kubectl

# Verify
oc version --client
```

### libvirt/KVM

```bash
# Install libvirt and dependencies
sudo dnf install -y \
  libvirt \
  qemu-kvm \
  virt-install

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

### OpenSSL

```bash
# Usually pre-installed
openssl version

# We need 1.1.1+ for some certificate operations
```

### jq, bind-utils

```bash
sudo dnf install -y jq bind-utils
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
| Disk | 100 GB | |

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
