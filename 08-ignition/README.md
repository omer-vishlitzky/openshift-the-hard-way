# Stage 08: Ignition

Ignition is the configuration system used by RHCOS. It runs once at first boot and configures the entire system.

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
Large (~280KB), contains everything to bootstrap:
- All certificates and keys
- All kubeconfigs
- Static pod manifests
- bootkube.sh script
- Machine Config Server
- kubelet configuration
- Pull secret

### master.ign
Small (~1.7KB), contains:
- Root CA certificate
- Pointer to MCS for full config
- SSH authorized keys

### worker.ign
Small (~1.7KB), contains:
- Root CA certificate
- Pointer to MCS for full config
- SSH authorized keys

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

6. **Pull Secret**
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

Master and worker ignition are simple - they fetch their real config from the Machine Config Server:

```json
{
  "ignition": {
    "version": "3.2.0",
    "config": {
      "merge": [{
        "source": "https://api-int.ocp4.example.com:22623/config/master"
      }]
    },
    "security": {
      "tls": {
        "certificateAuthorities": [{
          "source": "data:text/plain;base64,<root-ca>"
        }]
      }
    }
  },
  "passwd": {
    "users": [{
      "name": "core",
      "sshAuthorizedKeys": ["ssh-rsa ..."]
    }]
  }
}
```

## Systemd Units

Key systemd units in bootstrap ignition:

### kubelet.service
```ini
[Unit]
Description=Kubernetes Kubelet
Wants=rpc-statd.service network-online.target
After=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/kubelet \
  --config=/etc/kubernetes/kubelet.conf \
  --bootstrap-kubeconfig=/etc/kubernetes/kubeconfig \
  --kubeconfig=/var/lib/kubelet/kubeconfig \
  --container-runtime-endpoint=/var/run/crio/crio.sock \
  --runtime-cgroups=/system.slice/crio.service \
  --node-labels=node-role.kubernetes.io/master=,node.openshift.io/os_id=rhcos
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

### bootkube.service
```ini
[Unit]
Description=Bootstrap the OpenShift cluster
Wants=kubelet.service
After=kubelet.service

[Service]
Type=oneshot
ExecStart=/opt/openshift/bootkube.sh
Restart=on-failure
RestartSec=5
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
```

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

## Using Butane

Butane is a human-friendly way to write Ignition configs:

```yaml
# bootstrap.bu
variant: fcos
version: 1.4.0
passwd:
  users:
    - name: core
      ssh_authorized_keys:
        - ssh-rsa AAAA...
storage:
  files:
    - path: /etc/kubernetes/kubeconfig
      mode: 0600
      contents:
        local: kubeconfig
systemd:
  units:
    - name: kubelet.service
      enabled: true
      contents: |
        [Unit]
        Description=Kubernetes Kubelet
        ...
```

Convert to Ignition:
```bash
butane bootstrap.bu -o bootstrap.ign
```

We use raw Ignition JSON for transparency, but Butane is available.

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
