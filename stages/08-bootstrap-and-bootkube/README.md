# Stage 08: Bootstrap and Bootkube

This stage explains how the temporary bootstrap control plane is created and how it hands off to the production control plane. It also anchors this phase to real services and logs you can inspect.

**Sources used in this stage**
- `../pdfs/openshift/Installation_overview.pdf`
- `../pdfs/openshift/Installing_on_bare_metal.pdf`

## The bootstrap role

Bootstrap is a temporary control plane whose only job is to bring up the real control plane. It exists to break the chicken-and-egg problem of needing a control plane to create a control plane.

Key properties:
- Runs a single-node etcd.
- Runs a temporary kube-apiserver and controllers.
- Serves Ignition to control plane nodes through the Machine Config Server.

## Bootkube in plain terms

Bootkube is the bootstrap process that writes static pod manifests to `/etc/kubernetes/manifests` on the bootstrap node. The kubelet watches that directory and launches the control plane pods.

Static pods matter because:
- They do not require a running API server to exist.
- They are the API server and etcd for the first phase of the cluster.

## Timeline (HA)

1. Bootstrap node boots from RHCOS with `bootstrap.ign`.
2. Bootstrap starts a temporary etcd and API server as static pods.
3. Control plane nodes boot with their Ignition configs and contact the Machine Config Server.
4. Control plane nodes start their own static pods.
5. The temporary control plane schedules the production control plane.
6. The Cluster Version Operator starts applying the release payload.
7. The bootstrap control plane shuts down and hands off to the production control plane.

## Hands-on: observe bootstrap on a real node

On the bootstrap node:

```bash
systemctl status bootkube.service
journalctl -b -u bootkube.service
ls /etc/kubernetes/manifests
ss -ltnp | egrep '6443|22623'
```

On a control plane node:

```bash
journalctl -b -u kubelet
ls /etc/kubernetes/manifests
```

## Verification checks

- The API VIP answers on port 6443 during bootstrap.
- The Machine Config Server answers on port 22623 during bootstrap.
- Static pod manifests exist on the bootstrap node and control plane nodes.

**Deliverables for this stage**
- A clear mental model of bootstrap and bootkube.
- A concrete set of logs and files to verify during this phase.
