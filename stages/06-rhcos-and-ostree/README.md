# Stage 06: RHCOS and OSTree Deep Dive

This stage explains what RHCOS is, how OSTree works, and why OpenShift uses an immutable OS. It also introduces the `coreos-installer` workflow used to place RHCOS on disk.

**Sources used in this stage**
- `../pdfs/openshift/Architecture.pdf`
- `../pdfs/openshift/Installing_on_bare_metal.pdf`

## Why RHCOS exists

OpenShift expects the operating system to be treated as a versioned artifact, not as a mutable, package-by-package build. RHCOS delivers this by using OSTree and rpm-ostree. The result is an OS that is updated atomically and configured declaratively.

Practical consequences:
- You do not `yum install` packages on nodes.
- Most of the OS is read-only, with writes limited to `/etc` and `/var`.
- OS updates are applied as new deployments and require a reboot.

## OSTree, rpm-ostree, and the filesystem layout

**OSTree model**
- The OS is stored as commits in an OSTree repository.
- A deployment is a bootable snapshot of a specific commit.
- Updates create a new deployment alongside the current one.

**Filesystem model**
- `/usr` is read-only and comes from the OSTree commit.
- `/etc` is writable and uses a 3-way merge on updates.
- `/var` is writable and persists application and container state.

**rpm-ostree**
- `rpm-ostree status` shows the current deployment and update history.
- A node reboots into a new deployment after an update.

## What `coreos-installer` does

`coreos-installer` is the tool that writes the RHCOS image to disk and associates an Ignition config with the installed system. It can install from a live ISO or PXE environment.

At minimum, the install step requires:
- The Ignition config URL for the node type.
- The target block device.

The bare metal docs show this pattern:

```bash
sudo coreos-installer install \
  --ignition-url=http://<http_server>/<node_type>.ign \
  --ignition-hash=sha512-<digest> \
  <device>
```

## Hands-on: inspect the live RHCOS environment

These commands are safe to run in the live ISO environment and help you build intuition for the OS model.

1. Boot a host from the RHCOS live ISO and log in as `core`.
2. Inspect the OS identity:

```bash
cat /etc/os-release
rpm-ostree status
```

3. Inspect disks and mounts:

```bash
lsblk
findmnt / /usr /etc /var
```

4. Inspect the OSTree repository:

```bash
ostree refs
ostree log $(ostree refs --list | head -n 1)
```

## Verification checks

- `rpm-ostree status` shows a deployment and a clean state.
- `/usr` is mounted read-only.
- `/etc` and `/var` are writable.

**Deliverables for this stage**
- A correct mental model for RHCOS and OSTree.
- A safe, repeatable inspection routine for RHCOS in a live environment.
