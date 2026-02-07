# Stage 08: Ignition

Ignition is the configuration system used by RHCOS. It runs once at first boot and configures the entire system.

## Why This Stage Exists

This is where everything comes together. All previous stages produced artifacts:
- Stage 04: MCO rendered ignition (OS-level node config)
- Stage 05: PKI certificates
- Stage 06: Kubeconfigs
- Stage 07: Static pod manifests

Ignition is the delivery mechanism - it packages all these artifacts into a single JSON file that RHCOS applies at first boot.

**Why not just copy files manually?**
1. **Reproducibility**: The ignition config IS the complete system state. Rebuild any node by reapplying ignition.
2. **Atomicity**: Ignition applies everything or nothing. No partial configurations.
3. **No SSH needed**: Nodes configure themselves. No post-boot scripting required.
4. **Immutability**: Once configured, the node shouldn't drift. MCO handles any changes.

All ignition configs are complete — each node has everything it needs. No intermediary (MCS) needed. This is the KTHW approach: you configure each node explicitly.

## What is Ignition?

Ignition:
- Runs before the root filesystem is mounted
- Writes files, creates users, enables systemd units
- Is declarative and immutable
- Only runs once (on first boot)

Ignition is NOT:
- A configuration management tool (no ongoing enforcement)
- Running after boot (that's machine-config-daemon)
- Editable after boot (config is "baked in")

## Ignition Config Structure

```json
{
  "ignition": {
    "version": "3.2.0"
  },
  "passwd": {
    "users": [...]
  },
  "storage": {
    "files": [...],
    "directories": [...]
  },
  "systemd": {
    "units": [...]
  }
}
```

## What We Need to Build

### bootstrap.ign
Largest — contains everything to start the control plane:
- All certificates and keys
- All kubeconfigs
- Static pod manifests
- bootkube.sh script
- kubelet configuration
- Pull secret

### master-N.ign
MCO's rendered master ignition as the base (OVS bridges, kubelet.service, CRI-O config, SELinux, NetworkManager scripts, 30+ files/units), plus our additions:
- Per-node static IP (NetworkManager connection)
- Bootstrap kubeconfig (we skip MCS)
- kube-proxy static pod (ClusterIP routing until OVN takes over)
- CA certificates and pull secret

### worker-N.ign
Same pattern as master but using MCO's worker ignition:
- Per-node static IP
- Bootstrap kubeconfig
- CA certificate and pull secret
- No kube-proxy (masters handle ClusterIP routing)

## Build Ignition Configs

```bash
./build-all.sh
```

This creates:
- `${IGNITION_DIR}/bootstrap.ign`
- `${IGNITION_DIR}/master.ign`
- `${IGNITION_DIR}/worker.ign`

## Build Bootstrap Ignition

```bash
./build-bootstrap.sh
```

### Bootstrap Components

1. **Certificates and Keys**
```json
{
  "path": "/etc/kubernetes/bootstrap-secrets/etcd-ca.crt",
  "contents": { "source": "data:text/plain;base64,..." },
  "mode": 420
}
```

2. **Kubeconfigs**
```json
{
  "path": "/etc/kubernetes/kubeconfig",
  "contents": { "source": "data:text/plain;base64,..." },
  "mode": 384
}
```

3. **Static Pod Manifests**
```json
{
  "path": "/etc/kubernetes/manifests/etcd-pod.yaml",
  "contents": { "source": "data:text/plain;base64,..." },
  "mode": 420
}
```

4. **bootkube.sh**
```json
{
  "path": "/opt/openshift/bootkube.sh",
  "contents": { "source": "data:text/plain;base64,..." },
  "mode": 493
}
```

5. **kubelet.service**
```json
{
  "name": "kubelet.service",
  "enabled": true,
  "contents": "[Unit]\n..."
}
```

6. **CRI-O Pause Image Config**

Every Kubernetes pod is a group of containers sharing a network namespace (same IP, same ports). But someone has to create that namespace before the real containers start. That's the **pause container** — it does nothing except hold the namespace open.

CRI-O must pull the pause image before it can start ANY pod. RHCOS defaults to `registry.k8s.io/pause:3.10` which may be unreachable. We configure CRI-O to use the OpenShift pause image from the release payload:

```ini
# /etc/crio/crio.conf.d/00-pause.conf
[crio.image]
pause_image = "quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:..."
pause_image_auth_file = "/var/lib/kubelet/config.json"
```

Without this, kubelet logs `registry.k8s.io/pause: connection refused` and no pods start.

7. **Pull Secret**
```json
{
  "path": "/var/lib/kubelet/config.json",
  "contents": { "source": "data:text/plain;base64,..." },
  "mode": 384
}
```

## Build Master/Worker Ignition

```bash
./build-master.sh
./build-worker.sh
```

### How MCO ignition merging works

Master and worker ignition uses MCO's rendered output as a base. MCO produces a complete ignition config with 30+ files and 20+ systemd units. We merge our per-node additions on top using `jq`:

```
MCO rendered ignition (base)
  + Static IP NetworkManager config (per-node)
  + Bootstrap kubeconfig (we skip MCS)
  + kube-proxy static pod (masters only)
  + CA certificates and pull secret
  = Final master-N.ign / worker-N.ign
```

MCO handles kubelet.service, CRI-O config, OVS bridges, SELinux, and everything else a RHCOS node needs. We only add what MCO can't know (per-node IPs) and what we need for bootstrapping (kube-proxy, bootstrap kubeconfig).

### How the real installer does it (vs. our approach)

In the real installer, `master.ign` is tiny (~1.7KB) — just a pointer:

```json
{
  "ignition": {
    "config": {
      "merge": [{ "source": "https://api-int:22623/config/master" }]
    }
  }
}
```

**Ignition** (built into RHCOS, runs before any services) sees the `config.merge` directive, fetches the full config from the **MCS** (Machine Config Server) on the bootstrap node, and applies it.

In our KTHW approach, we skip MCS. Each node gets a complete ignition file directly via `coreos-installer`. No fetching, no intermediary. You see exactly what each node gets. The tradeoff: a separate ignition per node (which we already have — `master-0.ign`, `master-1.ign`, etc.).

## File Permissions

Ignition uses octal permissions:
- `420` = `0644` (read for all, write for owner)
- `384` = `0600` (read/write for owner only)
- `493` = `0755` (executable for all)

Private keys should be `384` (0600).

## Directory Structure on Bootstrap

After ignition runs, bootstrap has:
```
/etc/kubernetes/
├── bootstrap-secrets/
│   ├── etcd-ca.crt
│   ├── etcd-peer.crt
│   ├── etcd-peer.key
│   ├── kube-apiserver.crt
│   └── ...
├── manifests/
│   ├── etcd-pod.yaml
│   ├── kube-apiserver-pod.yaml
│   └── ...
├── kubeconfig
└── kubelet.conf

/opt/openshift/
├── bootkube.sh
├── manifests/
│   └── (cluster manifests)
└── tls/
    └── (additional certs)
```

## Verification

```bash
./verify.sh
```

Checks:
- Ignition files are valid JSON
- Required files are embedded
- systemd units are defined
- Permissions are correct

## What's Next

In [Stage 09](../09-rhcos-installation/README.md), we use these Ignition configs to install RHCOS on the nodes.
