# Stage 07: Ignition and Butane

This stage explains Ignition in detail and introduces Butane as the readable authoring format. We also connect Ignition to the `coreos-installer` workflow used in a manual install.

**Sources used in this stage**
- `../pdfs/openshift/Installing_on_bare_metal.pdf`
- `../pdfs/openshift/Architecture.pdf`

## Ignition deep dive

Ignition runs once, early in the boot process, before the real root filesystem is mounted. It is responsible for making a blank disk into a valid OpenShift node.

Ignition can:
- Partition disks and format filesystems.
- Write files and systemd units.
- Configure users and SSH keys.
- Inject network configuration.

Important properties:
- Ignition only runs on first boot.
- If Ignition is wrong, the node is wrong. There is no interactive recovery.
- To change Ignition, you re-install the node.

## Butane deep dive

Butane is a YAML format that compiles into Ignition JSON. It is easier to read, validate, and version control. For OpenShift, use the `openshift` variant.

Minimal Butane example:

```yaml
variant: openshift
version: 4.18.0
passwd:
  users:
  - name: core
    ssh_authorized_keys:
    - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQ...
storage:
  files:
  - path: /etc/hostname
    mode: 0644
    contents:
      inline: master0
```

Convert to Ignition JSON:

```bash
butane --pretty --strict config.bu > config.ign
```

## Hosting Ignition for a manual install

The bare metal docs describe a simple pattern:

1. Compute a SHA512 digest for each Ignition config.
2. Upload the Ignition files to an HTTP server.
3. Validate the URLs with `curl`.
4. Use `coreos-installer` with `--ignition-url` and `--ignition-hash`.

Example:

```bash
sha512sum bootstrap.ign
curl -k http://<http_server>/bootstrap.ign
sudo coreos-installer install \
  --ignition-url=http://<http_server>/<node_type>.ign \
  --ignition-hash=sha512-<digest> \
  <device>
```

## Verification checks

After first boot on a node:
- `cat /etc/hostname` shows the expected hostname.
- `ssh core@<node_ip>` works using the Ignition-provided key.
- `systemctl is-enabled kubelet` reports enabled on control plane and worker nodes.

**Deliverables for this stage**
- A working mental model for Ignition and Butane.
- A safe path to host and verify Ignition configs for manual installs.
