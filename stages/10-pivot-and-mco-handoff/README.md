# Stage 10: Pivot and MCO Handoff

This stage explains the pivot from the temporary bootstrap control plane to the production control plane, and how the Machine Config Operator takes over node configuration.

**Sources used in this stage**
- `../pdfs/openshift/Installation_overview.pdf`
- `../pdfs/openshift/Installing_on_bare_metal.pdf`
- `../pdfs/openshift/Machine_configuration.pdf`

## What the pivot means

The bootstrap control plane is temporary. Once the production control plane is running and etcd has quorum, the bootstrap control plane shuts down and the cluster becomes self-hosted.

Pivot outcomes:
- Bootstrap machine is removed from the API and MCS load balancer pools.
- The production control plane serves the API and manages all Operators.
- The Machine Config Operator begins enforcing node configuration.

## MCO handoff in plain terms

Before pivot, Ignition is responsible for initial node configuration. After pivot:
- The Machine Config Operator reconciles node configuration based on MachineConfig objects.
- The Machine Config Daemon (MCD) applies changes on each node.
- OS updates are delivered as new OSTree deployments.

## Hands-on: observe the handoff

```bash
oc get clusterversion
oc get clusteroperators
oc get nodes
oc get mcp
oc -n openshift-machine-config-operator get pods
```

On a control plane node:

```bash
systemctl status machine-config-daemon
journalctl -b -u machine-config-daemon
```

## Verification checks

- Bootstrap host removed from the LB pools.
- `oc get mcp` shows `Updated=True` for `master` and `worker` pools.
- `oc -n openshift-machine-config-operator get pods` shows MCO components running.

**Deliverables for this stage**
- A clear understanding of the pivot and when bootstrap can be removed.
- Practical commands to confirm MCO takeover.
