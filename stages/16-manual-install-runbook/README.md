# Stage 16: Manual Install Runbook (Hard Way)

This is the core hard-way runbook. It is intentionally explicit and hands-on. Every command is written out, and every artifact is generated in-repo. This is educational and not supported for production.

**Decision notes**
- PKI generation uses `openssl` instead of `cfssl` to avoid extra dependencies.
- All generated secrets are committed as examples by design.
- Release image pinned to the latest 4.18 at the time of writing: `4.18.19`.

**What this runbook does**
- Manually generates PKI and kubeconfigs.
- Manually renders control plane static pod manifests from templates.
- Generates Ignition configs for bootstrap, control plane, and workers.
- Installs RHCOS via `coreos-installer` using those Ignition configs.

**What this runbook does not do yet**
- It does not yet replicate every single installer asset from `openshift-install`. This is a first hard-way baseline that we will iterate on with real hardware.

## 0. Prerequisites

- Complete the network and DNS requirements in `stages/04-lab-and-network-prereqs/README.md`.
- Have a pull secret (for release image access).
- Have `podman`, `oc`, and `coreos-installer` available.

## 1. Set cluster variables

Edit the cluster variables file:

```bash
vi stages/16-manual-install-runbook/config/cluster-vars.sh
```

These values are used by all scripts and artifact generation.

## 2. Generate PKI (manual)

Run the PKI script:

```bash
stages/16-manual-install-runbook/scripts/10-gen-pki.sh
```

Outputs:
- `stages/16-manual-install-runbook/generated/pki/`

## 3. Generate kubeconfigs (manual)

```bash
stages/16-manual-install-runbook/scripts/20-gen-kubeconfigs.sh
```

Outputs:
- `stages/16-manual-install-runbook/generated/kubeconfig/`

## 4. Pull the release image and extract component image refs

Export your pull secret path:

```bash
export PULL_SECRET=/path/to/pull-secret.json
```

Generate image references from the release image:

```bash
stages/16-manual-install-runbook/scripts/25-get-image-refs.sh
```

This writes `stages/16-manual-install-runbook/config/image-refs.sh`.

## 5. Render static pod manifests for control plane nodes

```bash
stages/16-manual-install-runbook/scripts/30-render-manifests.sh
```

Outputs:
- `stages/16-manual-install-runbook/generated/manifests/<node>/`

## 6. Generate Ignition configs

```bash
stages/16-manual-install-runbook/scripts/40-gen-ignition.sh
```

Outputs:
- `stages/16-manual-install-runbook/generated/ignition/bootstrap.ign`
- `stages/16-manual-install-runbook/generated/ignition/master0.ign`
- `stages/16-manual-install-runbook/generated/ignition/master1.ign`
- `stages/16-manual-install-runbook/generated/ignition/master2.ign`
- `stages/16-manual-install-runbook/generated/ignition/worker0.ign`
- `stages/16-manual-install-runbook/generated/ignition/worker1.ign`

## 7. Host Ignition configs

Serve the ignition files over HTTP. Example using Python:

```bash
cd stages/16-manual-install-runbook/generated/ignition
python3 -m http.server 8080
```

## 8. Install RHCOS on each node

Boot each node from the RHCOS live ISO and run `coreos-installer`:

```bash
sudo coreos-installer install \
  --ignition-url=http://<http_server>:8080/<node>.ign \
  --ignition-hash=sha512-<digest> \
  /dev/sda
```

Compute the SHA512 digest for each Ignition file:

```bash
sha512sum stages/16-manual-install-runbook/generated/ignition/*.ign
```

## 9. Bring up the control plane

- Boot the bootstrap node first.
- Boot control plane nodes (master0-2).
- Watch the API VIP on port 6443 for readiness.

Example checks:

```bash
nc -zv api.${CLUSTER_DOMAIN} 6443
```

## 10. Join workers

Boot workers with their Ignition configs. Approve CSRs if needed:

```bash
oc get csr
oc adm certificate approve <csr_name>
```

## 11. Verify cluster health

```bash
oc get nodes
oc get clusterversion
oc get clusteroperators
```

## Artifacts generated in this stage

- PKI in `stages/16-manual-install-runbook/generated/pki/`
- Kubeconfigs in `stages/16-manual-install-runbook/generated/kubeconfig/`
- Static pod manifests in `stages/16-manual-install-runbook/generated/manifests/`
- Ignition configs in `stages/16-manual-install-runbook/generated/ignition/`

These are committed to the repo for educational purposes, including secrets.
