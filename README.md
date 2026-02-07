# OpenShift the Hard Way

A comprehensive, educational guide to installing OpenShift manually. No automation, no magic - just deep understanding.

## Philosophy

This guide exists because:

1. **Understanding beats automation.** When things break, automation can't help you. Understanding can.
2. **The installer is a black box.** `openshift-install` does 1000 things. We do each one manually.
3. **Production debugging requires internals knowledge.** Day 2 operations demand knowing how day 1 worked.

---

### What you do by hand vs. what CVO does

**OpenShift is not Kubernetes.** You cannot install it fully manually the way KTHW installs Kubernetes — and this guide is honest about that.

**You build the core by hand** — the parts that matter, the parts you need to understand when things break at 3am:

| What | How |
|------|-----|
| PKI (every certificate) | Hand-generated with openssl, every cert explained |
| Kubeconfigs | Hand-written, every field explained |
| etcd | Hand-written static pod manifest |
| kube-apiserver | Hand-written static pod manifest, every flag explained |
| kube-controller-manager | Hand-written static pod manifest |
| kube-scheduler | Hand-written static pod manifest |
| Ignition configs | Hand-built JSON, every node gets its own complete config |
| Cluster identity | Hand-written Infrastructure, Network, DNS resources |
| kube-proxy | Hand-written static pod on masters, enables ClusterIP routing |
| Node bootstrap & CSR approval | Done manually |
| RBAC for node join | Hand-written |
| Kubeadmin credential | Hand-generated |

**CVO handles the rest** — the 50+ operators (prometheus, console, image-registry, ingress, oauth, etc.) that no human would hand-write and no one learns anything from typing out:

| What | Why not by hand |
|------|-----------------|
| Prometheus operator | Zero value in hand-writing its deployment |
| Console operator | It's a web UI, not cluster infrastructure |
| Image registry operator | Standard operator pattern, nothing unique |
| 47 more operators | Same — they all follow the same pattern |

**The boundary is CVO.** You write its Deployment manifest by hand (you understand how it starts), you write the ClusterVersion CR (you understand how it knows what to install), and then CVO reads the release image and deploys everything else. That's the honest handoff point.

---

## Start Here

**New to OpenShift?** Start with [Stage 00: OpenShift Fundamentals](00-openshift-fundamentals/README.md). It explains:
- What OpenShift is and how it differs from Kubernetes
- Why OpenShift installation is more complex
- Key concepts you must understand (Ignition, RHCOS, bootstrap, pivot, CVO, MCO)
- The complete bootstrap timeline

## What You'll Build

A production-like HA OpenShift cluster:
- 1 Bootstrap node (temporary, removed after pivot)
- 3 Master nodes (control plane + etcd)
- 2 Worker nodes

## What You'll Learn

- How certificates flow through the cluster
- What bootkube.sh actually does (rendering, waiting, applying)
- Why etcd bootstrapping requires a temporary node
- How operators take over from bootstrap
- What triggers the pivot
- Why MachineConfig matters

## Prerequisites

- Linux host with libvirt/KVM (16GB+ RAM, 200GB+ disk)
- Red Hat account (for pull secret)
- Kubernetes knowledge (pods, deployments, services)
- Patience - this takes a full day, not an hour

## Approach

Each stage:
1. Explains the **why** before the **how**
2. Shows the actual code/config with explanation
3. Provides verification steps and scripts
4. Documents common failures and fixes

Every manifest is hand-written. No black-box operator containers. You understand every field because you wrote it.

## Stages

| Stage | Topic | Description | Scripts |
|-------|-------|-------------|---------|
| 00 | [OpenShift Fundamentals](00-openshift-fundamentals/README.md) | What is OpenShift? Why is it complex? | - |
| 01 | [Prerequisites](01-prerequisites/README.md) | Tools, accounts, knowledge | verify.sh |
| 02 | [Infrastructure](02-infrastructure/README.md) | VMs, networking, DNS, load balancer | create-*.sh, setup-*.sh |
| 03 | [Understanding the Installer](03-understanding-the-installer/README.md) | What openshift-install produces | - |
| 04 | [Release Image](04-release-image/README.md) | Release payload structure | extract.sh |
| 05 | [PKI](05-pki/README.md) | Every certificate explained | generate.sh, verify.sh |
| 06 | [Kubeconfigs](06-kubeconfigs/README.md) | Authentication to the API | generate.sh, verify.sh |
| 07 | [Static Pod Manifests](07-static-pod-manifests/README.md) | etcd, apiserver, kcm, scheduler | generate.sh |
| 08 | [Ignition](08-ignition/README.md) | Building bootstrap, master, worker ignition | build-*.sh |
| 09 | [RHCOS Installation](09-rhcos-installation/README.md) | Installing the operating system | install.sh |
| 10 | [Bootstrap](10-bootstrap/README.md) | The bootstrap process | wait-bootstrap.sh |
| 11 | [Control Plane Formation](11-control-plane-formation/README.md) | Masters joining, etcd scaling | wait-masters.sh |
| 12 | [The Pivot](12-the-pivot/README.md) | Bootstrap to production handoff | execute-pivot.sh |
| 13 | [Operator Convergence](13-operator-convergence/README.md) | CVO and operators deploying | wait-convergence.sh |
| 14 | [MCO Handoff](14-mco-handoff/README.md) | Machine Config Operator taking over | - |
| 15 | [Worker Join](15-worker-join/README.md) | Adding worker nodes | approve-csrs.sh |
| 16 | [Cluster Verification](16-cluster-verification/README.md) | Final checks and smoke tests | smoke-test.sh |

## Quick Start

```bash
# 1. Configure your cluster
vim config/cluster-vars.sh

# 2. Verify prerequisites
./01-prerequisites/verify.sh

# 3. Create infrastructure
./02-infrastructure/libvirt/create-network.sh
./02-infrastructure/libvirt/create-vms.sh
./02-infrastructure/haproxy/setup-haproxy.sh

# 4. Generate assets
./04-release-image/extract.sh
./04-release-image/extract-crds.sh
./05-pki/generate.sh
./06-kubeconfigs/generate.sh
./07-static-pod-manifests/generate.sh
./07-static-pod-manifests/generate-cluster-manifests.sh

# 5. Build ignition
./08-ignition/build-bootstrap.sh
./08-ignition/build-master.sh
./08-ignition/build-worker.sh

# 6. Install RHCOS and bootstrap
./09-rhcos-installation/install.sh  # Follow instructions
./10-bootstrap/wait-bootstrap.sh

# 7. Form control plane
./11-control-plane-formation/wait-masters.sh
./12-the-pivot/execute-pivot.sh
./13-operator-convergence/wait-convergence.sh

# 8. Add workers
./15-worker-join/approve-csrs.sh -w

# 9. Verify
./16-cluster-verification/smoke-test.sh
./scripts/verify-all.sh
```

## End-to-End Verification

Run the comprehensive verification script at any point:

```bash
./scripts/verify-all.sh
```

This checks DNS, HAProxy, bootstrap, masters, API, operators, and ingress.

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
