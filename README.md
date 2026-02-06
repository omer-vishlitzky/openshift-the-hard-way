# OpenShift the Hard Way

A comprehensive, educational guide to installing OpenShift manually. No automation, no magic - just deep understanding.

## Philosophy

This guide exists because:

1. **Understanding beats automation.** When things break, automation can't help you. Understanding can.
2. **The installer is a black box.** `openshift-install` does 1000 things. We do each one manually.
3. **Production debugging requires internals knowledge.** Day 2 operations demand knowing how day 1 worked.

## What You'll Build

A 3-node HA OpenShift cluster:
- 1 Bootstrap node (temporary)
- 3 Master nodes (control plane + etcd)
- 2+ Worker nodes (optional)

## What You'll Learn

- How certificates flow through the cluster
- What bootkube.sh actually does (all 15 stages)
- Why etcd bootstrapping is a dance
- How operators take over from bootstrap
- What triggers the pivot
- Why MachineConfig matters

## Prerequisites

- Linux host with libvirt/KVM (16GB+ RAM, 200GB+ disk)
- Red Hat account (for pull secret)
- Patience - this takes a full day, not an hour

## Approach

Each stage:
1. Explains the **why** before the **how**
2. Shows the actual code/config with line-by-line explanation
3. Provides verification steps
4. Documents common failures and fixes

We use operator containers to render manifests (they encode version-specific logic), but explain exactly what they produce.

## Stages

| Stage | Topic | Description |
|-------|-------|-------------|
| 01 | Prerequisites | Tools, accounts, knowledge |
| 02 | Infrastructure | VMs, networking, DNS, load balancer |
| 03 | Understanding the Installer | What openshift-install produces |
| 04 | Release Image | Release payload structure |
| 05 | PKI | Every certificate explained |
| 06 | Kubeconfigs | Authentication to the API |
| 07 | Static Pod Manifests | etcd, apiserver, kcm, scheduler |
| 08 | Ignition | Building bootstrap, master, worker ignition |
| 09 | RHCOS Installation | Installing the operating system |
| 10 | Bootstrap | The bootstrap process |
| 11 | Control Plane Formation | Masters joining, etcd scaling |
| 12 | The Pivot | Bootstrap to production handoff |
| 13 | Operator Convergence | CVO and operators deploying |
| 14 | MCO Handoff | Machine Config Operator taking over |
| 15 | Worker Join | Adding worker nodes |
| 16 | Cluster Verification | Final checks and smoke tests |

## Progress

See [PROGRESS.md](PROGRESS.md) for current status.

## Non-Goals

- **Production deployment guide.** This is for learning, not production.
- **Fastest path to a cluster.** That's what `openshift-install` is for.
- **Every platform.** We focus on bare metal / libvirt. Concepts transfer.

## Contributing

This guide is tested on real infrastructure. If you find errors:
1. Note the exact stage and step
2. Include the error message
3. Describe your environment

## License

Apache 2.0
