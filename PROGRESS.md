# Progress

## Current Status

**Phase**: MCO integrated. Master/worker ignition uses MCO rendered base + per-node additions. Next: rebuild and boot masters.

## Approach

KTHW-style: every manifest is hand-written with explanations. No black-box operator containers.
Each node gets its own complete ignition config. CVO is the explicit handoff point to automation.

## Testing Progress

| Stage | Tested | Notes |
|-------|--------|-------|
| 01 | PASS | Prerequisites verified |
| 02 | PASS | libvirt network (with DNS + DHCP + NAT), HAProxy, VMs with CDROM |
| 04 | PASS | Release image extraction (4.18.0), CRD extraction, MCO rendered ignition |
| 05 | PASS | PKI generation (etcd-server cert needs `both` usage, apiserver needs `localhost` SAN) |
| 06 | PASS | Kubeconfig generation (8 kubeconfigs) |
| 07 | PASS | Static pod manifests (5 pods: etcd, apiserver, kcm, scheduler, CVO) |
| 07 | PASS | Cluster manifests (namespaces, RBAC, CRDs, secrets, FeatureGate, CVO static pod) |
| 08 | PASS | Ignition building (bootstrap 3.9MB with CRDs, master/worker use MCO base + per-node static IPs + kube-proxy) |
| 09 | PASS | RHCOS installation via coreos-installer + ignition URL |
| 10 | PASS | Bootstrap: 5 static pods running, API healthy, CVO syncing 902 manifests |
| 11 | PASS | 3 masters registered, CSRs approved, kube-proxy running, operators deploying |
| 12 | IN PROGRESS | etcd-operator deployed, waiting for static pods on masters |
| 13 | - | Pivot (remove bootstrap) |
| 14 | - | Boot workers |
| 15 | - | Worker CSRs |
| 16 | - | Operator convergence |
| 17 | - | Final verification |

## Key Learnings (bugs found during testing)

### PKI
- etcd-server cert needs `extendedKeyUsage = serverAuth, clientAuth` (both), not just serverAuth. etcd connects to itself for health checks using the same cert.
- kube-apiserver cert needs `localhost` and bootstrap IP in SANs. bootkube.sh connects via localhost.

### Bootstrap kubelet
- Bootstrap kubelet must NOT use `--kubeconfig` or `--bootstrap-kubeconfig`. It only runs static pods via `--pod-manifest-path`. Same as the real installer's kubelet.sh.template.
- Regular Kubernetes Deployments can't schedule on bootstrap because it's not a registered node.

### CRI-O
- Must configure CRI-O to use the OpenShift pause image (not registry.k8s.io/pause). Add `/etc/crio/crio.conf.d/00-pause.conf` to ignition.

### CVO (Cluster Version Operator)
- Runs as a **static pod** on bootstrap, not a Deployment (no registered node to schedule on).
- Must use the **release image** (`ocp-release:4.18.0`), not the CVO operator image. The release image contains `/release-manifests/` which CVO reads.
- Needs `--listen=` (empty) to disable metrics endpoint (otherwise requires TLS cert).
- Needs `CLUSTER_PROFILE=self-managed-high-availability` env var.
- Needs `securityContext: privileged: true`.

### CRDs
- OpenShift API CRDs must be applied BEFORE CVO starts. They come from two sources:
  1. `cluster-config-api` image: 95 CRDs (Infrastructure, Network, DNS, etc.)
  2. CVO render: 2 CRDs (ClusterVersion, ClusterOperator)
- A **FeatureGate** CR must exist before CVO starts. Without it, CVO detects a feature mismatch and shuts down.
- ClusterVersion CR must NOT have `desiredUpdate` for initial install. CVO reads the version from its own release image.

### kube-proxy (critical discovery)
- **Every operator** deployed by CVO reaches the API server via the `kubernetes` Service ClusterIP (`172.30.0.1:443`). This is a virtual IP that doesn't exist on any network interface — it requires iptables rules to translate it to the real API server IP.
- **kube-proxy** programs these iptables rules. Without it, all operators timeout trying to reach `172.30.0.1:443` and crash in CrashLoopBackOff.
- **OVN-Kubernetes** eventually replaces kube-proxy, but OVN is itself an operator that needs kube-proxy to bootstrap. Chicken-and-egg: kube-proxy bootstraps ClusterIP routing → operators can start → network operator deploys OVN → OVN takes over routing.
- **Solution**: add a kube-proxy static pod to master ignition. Uses the dedicated `kube-proxy` image from the release (NOT hyperkube — hyperkube has a wrapper entrypoint that fails with "ID cannot be empty").
- kube-proxy needs `system:node-proxier` ClusterRole bound to `system:bootstrapper` so it can watch Services, Endpoints, and Nodes.
- kube-proxy needs `securityContext: privileged: true` to write iptables rules.
- Masters also need `/etc/kubernetes/apiserver-url.env` — operators read this to find the API server URL.

### MCO (Machine Config Operator) — integrated as a render step
- MCO is a template engine: takes cluster config → produces complete node ignition with 30+ files and 20+ systemd units.
- Running MCO render requires TWO commands: `machine-config-operator bootstrap` (produces templates) then `machine-config-controller bootstrap` (merges MachineConfigs into rendered ignition with `.spec.config.raw`).
- MCO handles: OVS bridge setup (`configure-ovs.sh`), `openvswitch.service`, `nodeip-configuration.service`, kubelet.service, CRI-O config, SELinux restorecon, `/etc/kubernetes/apiserver-url.env`, NetworkManager dispatcher scripts, and 20+ more.
- We keep: kube-proxy (MCO doesn't provide it — needed until OVN takes over), per-node static IP (MCO doesn't know our IPs), bootstrap kubeconfig (we skip MCS).
- MCC bootstrap expects: ControllerConfig, MachineConfigPools, FeatureGate CR, pull secret (as K8s Secret YAML), and image-references ImageStream in the manifest dir.

### Cluster manifests applied during bootstrap
- **Infrastructure CR status** must have `controlPlaneTopology: HighlyAvailable` and `infrastructureTopology: HighlyAvailable` in the `status` field. The config-operator validates this and goes Degraded if empty. Fix: patch the status subresource after initial creation.
- **Network operator CR** (`operator.openshift.io/v1 Network cluster`) must be created separately from the `config.openshift.io/v1 Network cluster`. The network operator watches `operator.openshift.io/v1` — without it, it reports "No networks.operator.openshift.io cluster found" and can't deploy OVN.
- **`cluster-config-v1` ConfigMap** in `kube-system` — contains the install-config YAML. The network operator reads this to configure OVN. Without it: "configmaps cluster-config-v1 not found".
- **`etcd-endpoints` ConfigMap** in `openshift-etcd` — tells the etcd-operator where the bootstrap etcd is. Without it, the operator tries to connect to master IPs (where etcd isn't running yet) and fails.
- **FeatureGate CR** must exist before CVO starts (already documented above).

### HAProxy
- HTTP health checks (`option httpchk`) don't work in TCP mode against HTTPS backends. HAProxy marks all backends as DOWN (400 Bad Request). Solution: remove HTTP health checks, use TCP checks only.
- Firewall must allow ports 6443, 22623, 80, 443 from the libvirt zone (`firewall-cmd --zone=libvirt --add-port=...`).
- API VIP and Ingress VIP must be added to the bridge interface (`ip addr add`).

### Infrastructure
- libvirt NAT requires iptables MASQUERADE rules (firewalld overrides libvirt's default rules).
- DHCP needed for live ISO environment (installed system uses static IPs from ignition).
- RHCOS ISO and ignition files must be in the libvirt pool path (qemu can't read from home directory).
- Boot order `hd,cdrom`: empty disk falls through to CDROM first boot, boots from disk after install.
- bootkube.sh must be at `/usr/local/bin/` (not `/opt/openshift/`) for correct SELinux exec context.
