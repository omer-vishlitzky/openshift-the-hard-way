# Stage 15: Validation and Troubleshooting

This stage collects practical validation checks and troubleshooting patterns. It is intentionally repetitive, because reliable installs are built on repeatable verification.

**Sources used in this stage**
- `../pdfs/openshift/Validation_and_troubleshooting.pdf`
- `../pdfs/openshift/Installing_on_bare_metal.pdf`

## Pre-install validation

DNS:
- Forward resolution for `api`, `api-int`, `*.apps`, and all nodes.
- Reverse resolution for API VIP and all nodes.

Load balancers:
- API VIP reachable on 6443 and 22623.
- Ingress VIP reachable on 80 and 443.
- No session persistence on API LB.

Time sync:
- NTP reachable on UDP 123.

## Bootstrap validation

- Bootstrap node answers on 6443 and 22623.
- `journalctl -b -u bootkube.service` shows progress.
- Control plane nodes fetch Ignition and start static pods.

## Control plane validation

- `oc get nodes` shows all control plane nodes `Ready`.
- `oc -n openshift-etcd get pods` shows etcd running.
- `oc get clusterversion` shows `Available=True`.

## Worker validation

- `oc get nodes` shows workers `Ready`.
- `oc get csr` shows no pending CSRs.

## Common failure patterns and first checks

DNS failures:
- Check forward and reverse resolution on all nodes.

API unreachable:
- Verify LB pool membership and health checks.
- Confirm that port 6443 is open end to end.

Bootstrap stuck:
- Check `journalctl -b -u bootkube.service` on bootstrap.
- Check `journalctl -b -u kubelet` on control plane nodes.

etcd unhealthy:
- Verify port 2379-2380 connectivity between control plane nodes.
- Check disk latency and IOPS.

## Must-gather (when cluster is reachable)

```bash
oc adm must-gather
```

**Deliverables for this stage**
- A single checklist for validation across all phases.
- First-response troubleshooting patterns.
