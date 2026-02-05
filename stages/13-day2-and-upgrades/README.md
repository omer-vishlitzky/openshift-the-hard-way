# Stage 13: Day 2 Operations and Upgrades

This stage explains how OpenShift updates itself and what day-2 operations look like in a cluster that manages its own OS and configuration.

**Sources used in this stage**
- `../pdfs/openshift/Updating_clusters.pdf`
- `../pdfs/openshift/Architecture.pdf`

## Update model in OpenShift

- Red Hat hosts an update graph that defines valid upgrade paths.
- The CVO reads this graph and presents valid targets.
- Updates are applied by setting a new desired version in the `ClusterVersion` resource.
- The CVO applies the release payload in runlevels and waits for Operators to reconcile.
- After control plane updates, the MCO updates node OS and configuration.

## Update channels

OpenShift exposes update channels such as candidate, fast, stable, and eus. A release typically appears in candidate first, then fast, and later stable. EUS provides a longer support window.

## Hands-on: inspect and initiate an upgrade

```bash
oc adm upgrade
oc adm upgrade channel
oc adm upgrade --to=<version>
```

Track progress:

```bash
oc get clusterversion
oc get clusteroperators
oc get mcp
```

## Verification checks

- `oc get clusterversion` shows `Progressing=False` after the update.
- `oc get mcp` shows pools `Updated=True`.
- `rpm-ostree status` on nodes shows the new deployment.

**Deliverables for this stage**
- A clear understanding of the OpenShift update pipeline.
- A safe command sequence for upgrades.
