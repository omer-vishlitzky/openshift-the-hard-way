# OpenShift Assisted Installer: a complete technical deep-dive

The Assisted Installer is a service-based OpenShift installation system that replaces the traditional bootstrap VM pattern with an agent-driven, API-orchestrated workflow. **Hosts boot a discovery ISO, run an agent that inventories hardware and validates readiness, then receive installation commands from a central service that generates Ignition configs, coordinates disk writes, and monitors cluster formation** — all without requiring a separate bootstrap node, BMC access, or Terraform. This document traces the entire journey from CRD creation through cluster readiness, explaining every binary, API call, state transition, and systemd unit involved.

The Assisted Installer matters because it collapses what was historically a complex, error-prone, multi-tool process into a single API-driven workflow with comprehensive pre-flight validation. Before a single byte is written to disk, every host has been inventoried, connectivity-tested, DNS-validated, and NTP-synchronized. This pre-flight rigor is something neither IPI nor UPI provides.

---

## 1. Architecture: how the pieces fit together

The Assisted Installer is not a single binary — it is a distributed system of five cooperating components, each in its own repository under the `openshift` GitHub organization.

**assisted-service** (`openshift/assisted-service`) is the brain. Written in Go, it exposes a REST API defined in a Swagger/OpenAPI spec (`swagger.yaml`), backed by a **PostgreSQL** database that persists cluster and host state. It implements two state machines — one for clusters, one for hosts — that drive the entire installation lifecycle. It caches extracted `openshift-baremetal-install` binaries (in `$WORK_DIR/installercache/`) for each OCP version, and uses them to generate Ignition configs. The V2 API lives under `/api/assisted-install/v2/` with key endpoints including `/v2/clusters`, `/v2/infra-envs`, and `/v2/infra-envs/{id}/hosts/{id}/instructions`.

**assisted-image-service** (`openshift/assisted-image-service`) generates and serves discovery ISOs. On startup, it downloads RHCOS base ISOs (configured via the `OS_IMAGES` JSON environment variable) into `DATA_DIR`. When a client requests an ISO, the service fetches the InfraEnv's discovery Ignition from the assisted-service, then **patches the Ignition into the RHCOS ISO on-the-fly during HTTP streaming** using a Go implementation in `pkg/isoeditor/` — no external `coreos-installer` binary needed.

**assisted-installer-agent** (`openshift/assisted-installer-agent`) runs on each discovered host. Its container image (`quay.io/edge-infrastructure/assisted-installer-agent`) contains multiple Go executables at `/usr/bin/`: `agent` (entry point), `next_step_runner` (polls for instructions), `inventory` (hardware collection), `connectivity_check` (L2/L3 network tests), `free_addresses` (IP conflict detection), `logs_sender`, `dhcp_lease_allocate`, and `apivip_check`.

**assisted-installer** (`openshift/assisted-installer`) is the binary that performs the actual disk write on each host during installation. It runs as a privileged container and calls `coreos-installer` to write RHCOS to the target disk.

**assisted-installer-controller** (same repo) is a pod deployed **inside the cluster being installed** during bootstrap. It monitors ClusterOperator CRs, approves CSRs, and reports progress back to the assisted-service.

### Three deployment modes

The Assisted Installer runs in three distinct modes, all sharing the same codebase:

**SaaS mode** runs on `console.redhat.com` (API at `api.openshift.com`). Red Hat hosts the assisted-service as a multi-tenant managed service. Users authenticate via OpenShift Cluster Manager API tokens and interact through the web UI or REST API. ISOs are generated and served from Red Hat's infrastructure.

**On-premises operator mode** deploys the assisted-service onto a hub cluster via **Multicluster Engine (MCE)** or **Advanced Cluster Management (ACM)**. The **infrastructure-operator** (also called `assisted-service-operator`) watches Kubernetes CRDs on the hub cluster and translates them into internal assisted-service API calls. The `AgentServiceConfig` CR (a singleton named `agent`) triggers deployment of PostgreSQL, the assisted-service Deployment, and the assisted-image-service StatefulSet, each with their own PVCs for database storage, filesystem storage, and image storage.

**Agent-based installer mode** uses `openshift-install agent create image` to produce a self-contained bootable ISO that embeds the assisted-service itself, the agent, all cluster configuration, and RHCOS images. The **rendezvous host** (specified by `rendezvousIP`) starts the assisted-service ephemerally during boot. All other hosts register with it. No external service, no hub cluster — fully disconnected-capable. Introduced in OCP 4.11.

### How it differs from IPI and UPI architecturally

The critical architectural distinction is **no separate bootstrap node**. IPI creates a dedicated bootstrap VM (via Terraform on clouds, or via libvirt for bare metal with Ironic/Metal3). UPI requires the user to provision a bootstrap machine manually. The Assisted Installer uses **bootstrap-in-place**: one of the actual cluster master nodes temporarily acts as bootstrap, then pivots to become a regular master. No Terraform, no BMC/IPMI access required, no provisioning network, no extra machine to destroy afterward.

---

## 2. CRDs: the Kubernetes-native control plane

When using the on-premises operator mode, five CRDs orchestrate the installation. Understanding their relationships and reconciliation behavior is essential.

### InfraEnv: the discovery environment

The `InfraEnv` CR (`agent-install.openshift.io/v1beta1`) represents a discovery infrastructure environment. When you create one, the **InfraEnvReconciler** adds a finalizer (`infraenv.agent-install.openshift.io/ai-deprovision`), collects all matching `NMStateConfig` resources via `spec.nmStateConfigLabelSelector`, builds a `StaticNetworkConfig` parameter, and calls the assisted-service internal function `RegisterInfraEnvInternal`. The service generates a discovery Ignition config, and the image service makes the ISO available. The reconciler sets `status.isoDownloadURL` to the download endpoint.

Key spec fields include `clusterRef` (linking to a `ClusterDeployment`), `pullSecretRef`, `sshAuthorizedKey`, `cpuArchitecture`, `proxy` (HTTP/HTTPS/NO_PROXY), `ignitionConfigOverride` (arbitrary Ignition JSON merged into the discovery config), and `nmStateConfigLabelSelector`. The reconciler watches InfraEnv resources, NMStateConfigs, ClusterDeployments, and Secrets — any change triggers re-reconciliation and potentially ISO regeneration.

### ClusterDeployment and AgentClusterInstall: the cluster definition

The `ClusterDeployment` CR (`hive.openshift.io/v1`) represents the target cluster. It specifies `baseDomain`, `clusterName`, a reference to the pull secret, and critically, a `clusterInstallRef` pointing to an `AgentClusterInstall`. The `spec.platform.agentBareMetal.agentSelector` uses label selectors to match Agent CRs to this cluster.

The `AgentClusterInstall` CR (`extensions.hive.openshift.io/v1beta1`) contains the actual installation parameters: `apiVIP` and `ingressVIP` (for HA clusters), `networking` (clusterNetwork CIDR with hostPrefix, serviceNetwork CIDR, machineNetwork CIDR, networkType), and `provisionRequirements` specifying `controlPlaneAgents` (1 for SNO, 3 for HA) and `workerAgents`. The `imageSetRef` points to a `ClusterImageSet` CR that carries the release image reference (e.g., `registry.ci.openshift.org/ocp/release:4.14.0`). Install-config overrides can be injected via the annotation `agent-install.openshift.io/install-config-overrides`.

**Installation triggers automatically** when the required number of approved, validated agents are bound to the cluster. Once installation starts, spec changes are rejected.

### NMStateConfig: per-host static networking

`NMStateConfig` CRs define static network configuration in NMState YAML format, linked to InfraEnvs through labels matching `nmStateConfigLabelSelector`. Each NMStateConfig includes a `config` block (interfaces, DNS resolvers, routes) and an `interfaces` block mapping NIC names to MAC addresses for per-host targeting. **Create NMStateConfigs before the InfraEnv** — the InfraEnv reconciler doesn't know how many to expect and re-generates the ISO when new ones appear. There is a practical limit of ~3960 NMStateConfigs per InfraEnv due to a 256KiB Ignition content length limit.

### Agent: the discovered host representation

`Agent` CRs are **auto-created** by the assisted-service when a host boots the discovery ISO and registers. Named by the host's UUID, they appear in the InfraEnv's namespace. The user sets `spec.approved: true` to allow the host to participate in installation, and can override `spec.hostname`, `spec.role` (master/worker), and `spec.installationDiskID`. The status contains the full hardware inventory, validation results (`status.validationsInfo`), and conditions including `Connected`, `RequirementsMet`, `Validated`, `Installed`, and `Bound`.

---

## 3. ISO generation: what's inside the discovery image

### The base image and customization

The discovery ISO starts with a **RHCOS live ISO** (`rhcos-<version>-live.x86_64.iso`) containing the Linux kernel (`vmlinuz`), initramfs (`initrd.img`), and a squashfs-compressed root filesystem (`rootfs.img`). The assisted-image-service patches a discovery Ignition config into the ISO's reserved embed area — the same region that `coreos-installer iso customize` writes to — using its Go implementation in `pkg/isoeditor/`. This happens at serving time: the ISO is streamed to the client with the Ignition injected on-the-fly.

### Discovery Ignition config contents

The discovery Ignition (version 3.1.0) is generated by `FormatDiscoveryIgnitionFile()` in `internal/ignition/discovery.go`. It contains:

**The primary systemd unit `agent.service`** launches `podman run` with the agent container image using `--privileged --net=host --pid=host`, mounting `/dev`, `/run/udev`, `/proc`, `/sys`, and `/var/log`. Environment variables include `INFRA_ENV_ID`, `SERVICE_URL`, and proxy settings. The agent binary inside receives `--url=<SERVICE_BASE_URL>` and `--infra-env-id=<INFRA_ENV_ID>`.

**Files delivered via Ignition** include the pull secret at `/root/.docker/config.json` (for pulling the agent container image), SSH authorized keys for the `core` user, proxy environment variables, custom CA certificates at `/etc/pki/ca-trust/source/anchors/`, container registry mirror configuration at `/etc/containers/registries.conf`, and NMState-derived NetworkManager connection files for static IP configuration.

### Full ISO versus minimal ISO

The **full ISO** (~1 GB+) includes the rootfs and requires no network connectivity beyond agent-to-service communication. The **minimal ISO** (~100–300 MB) strips the rootfs and adds the kernel parameter `coreos.live.rootfs_url=<URL>` so the initramfs downloads it over the network at boot. For iPXE boot, the image service provides an iPXE script endpoint at `/api/assisted-install/v2/infra-envs/{id}/downloads/files?file_name=ipxe-script` that chains kernel, initrd (with Ignition appended), and rootfs URLs with appropriate kernel parameters.

---

## 4. Discovery phase: from power-on to validated host

### Boot sequence step by step

When a bare-metal machine boots the discovery ISO, the bootloader (GRUB or isolinux) loads the RHCOS kernel and initramfs. **Ignition runs in the initramfs**: it reads the embedded config from the ISO's embed area, applies it (creates files, configures systemd units, sets up networking via NetworkManager), and if using a minimal ISO, downloads the rootfs via `coreos.live.rootfs_url`. The squashfs rootfs is mounted read-only with a tmpfs overlay for writes, then `switch_root` pivots into the RHCOS live environment. **The entire system runs in RAM** — no disk writes occur during discovery.

Systemd starts `agent.service`, which pulls and runs the agent container. The `agent` binary registers the host with the assisted-service via `POST /api/assisted-install/v2/infra-envs/{infra_env_id}/hosts` with the host's UUID (derived from DMI/SMBIOS system UUID via the `ghw` Go library) and agent version. It then starts `next_step_runner`, which enters a polling loop.

### The next-step polling loop

`next_step_runner` calls `GET /api/assisted-install/v2/infra-envs/{infra_env_id}/hosts/{host_id}/instructions` at a configurable interval (default **60 seconds**). The service returns a `Steps` object — an array of step commands, each with a `step_type`, `step_id`, `command`, and `args`. The runner executes each step as a subprocess or podman command, then posts results back via `POST .../instructions/{instruction_id}`. Step types include `inventory`, `connectivity-check`, `free-addresses-check`, `ntp-synchronizer`, `installation-disk-speed-check`, `container-image-availability`, `domain-resolution`, and eventually `install`.

### Hardware inventory collection

The `inventory` binary uses the **ghw** (Go HardWare) library and system commands to collect comprehensive hardware data:

**CPU**: model name, architecture, core/thread count, frequency, and flags (from `/proc/cpuinfo`). **Memory**: physical and usable bytes (from `/proc/meminfo`). **Disks**: device name, size, model, vendor, serial, WWN, drive type (HDD/SSD), path, by-id, by-path, SMART status, holders, and installation eligibility — collected via `lsblk` and ghw. **Network interfaces**: name, MAC address, IPv4/IPv6 addresses, speed, MTU, type (physical/bond/vlan/bridge), carrier status, and vendor — from `/sys/class/net/` and `ip addr`. **System vendor**: manufacturer, product name, serial number, and whether the system is virtual (from DMI/SMBIOS). **GPUs**: PCI address, vendor/device ID, name, filtered by PCI class (0x0300 for VGA, 0x0302 for 3D controllers). **Boot mode**: UEFI or BIOS (checking for `/sys/firmware/efi`). **TPM version**, **BMC address** (via `ipmitool`), and **routing table** entries are also collected.

### Network connectivity checks

The `connectivity_check` binary tests reachability between all discovered hosts. **L2 connectivity** uses ARP/nmap to verify MAC-level reachability for hosts on the same machine network CIDR. **L3 connectivity** uses ICMP ping (`ping -c 10 -W 3 -q -I <interface> <address>`) to measure packet loss and latency between all host pairs, compared against configurable thresholds. **Port connectivity** uses nmap to verify that cluster-required ports are reachable.

### Host validations: the pre-flight gate

The assisted-service runs validations server-side (in `internal/host/validator.go`) after receiving inventory and connectivity data. These validations are the reason the Assisted Installer catches problems before installation, something no other method does. Minimum hardware requirements scale by role:

- **Control plane**: ≥4 CPU cores, ≥16,384 MiB RAM, ≥100 GB disk
- **Worker**: ≥2 CPU cores, ≥8,192 MiB RAM, ≥100 GB disk
- **SNO**: ≥8 CPU cores, ≥16,384 MiB RAM, ≥100 GB disk (requirements increase further when ODF or CNV operators are selected)

Network validations check that machine CIDR is defined, the host has an interface in that CIDR, the host belongs to the network majority group, API VIP is reachable, a default route exists, latency and packet loss are within thresholds, and no IP collisions exist. DNS validations verify that `api.<cluster>.<domain>` and `*.apps.<cluster>.<domain>` resolve correctly (for user-managed networking). The `ntp-synced` validation checks clock offset against the service. The `container-images-available` validation confirms that required container images can be pulled from configured registries.

A host transitions from `discovering` → `insufficient` (if validations fail) or → `known` (if all pass). The Agent CR's `status.validationsInfo` exposes the detailed pass/fail breakdown for every validation.

---

## 5. Pre-installation: generating the configs

### Role assignment and network parameters

When the user does not explicitly assign roles, the assisted-service auto-assigns: it selects the **three hosts with the best hardware profile as masters** based on CPU, RAM, and disk. One master is internally designated as the **bootstrap node** — this choice is made by the service and is not directly user-controllable. For networking, three CIDRs are configured: **machine network** (the physical host subnet, auto-detected or user-specified), **cluster network** (default `10.128.0.0/14` with `/23` host prefix, for pod-to-pod overlay), and **service network** (default `172.30.0.0/16`, for Kubernetes ClusterIP services).

The **API VIP** and **Ingress VIP** are floating virtual IPs from the machine network, mapped to `api.<cluster>.<domain>` and `*.apps.<cluster>.<domain>` respectively. When cluster-managed networking is selected, the install-config uses `platform: baremetal`, which configures **keepalived** (VRRP) and **HAProxy** as static pods on control plane nodes. Two VRRP instances are created — one for API, one for Ingress — with auto-generated VRRP IDs derived from the cluster name. Health checks run every second: the API check curls `https://localhost:6443/readyz`, the Ingress check curls `http://localhost:1936/healthz`. The `baremetal-runtimecfg` container dynamically generates `/etc/keepalived/keepalived.conf`.

### Ignition config generation

The assisted-service constructs an `install-config.yaml` internally from cluster and host data, then runs the `openshift-baremetal-install` binary (extracted from the OCP release image via `oc adm release extract` and cached in `$WORK_DIR/installercache/`). The process is:

1. Write the generated `install-config.yaml` to a temporary directory
2. Inject any user-uploaded custom manifests into `manifests/` or `openshift/` subdirectories
3. Run `openshift-baremetal-install create manifests --dir=<tmpdir>`
4. Run `openshift-baremetal-install create ignition-configs --dir=<tmpdir>`
5. Store the resulting files: `bootstrap.ign`, `master.ign`, `worker.ign`, `auth/kubeconfig`, and `auth/kubeadmin-password` in S3-compatible object storage

**`bootstrap.ign`** (~25–50 MB) is massive and self-contained: it includes all bootstrap static pod manifests (etcd, kube-apiserver, kube-controller-manager, kube-scheduler), the `bootkube.service` systemd unit, the machine-config-server binary, all TLS certificates and keys (root CA, etcd CA, API server certs, kubelet certs), container image references for every OCP component, `approve-csr.service`, and `progress.service`.

**`master.ign`** and **`worker.ign`** (~1.5 KB each) are tiny **pointer configs**: they contain only a `source` URL pointing to the Machine Config Server (`https://api-int.<cluster>.<domain>:22623/config/master` or `/config/worker`) and the root CA certificate to validate the TLS connection. On first boot, the node fetches the full rendered config from the MCS.

---

## 6. The installation process: what happens on every host

### Triggering installation

When the user calls `POST /api/assisted-install/v2/clusters/{cluster_id}/actions/install` (or installation auto-triggers in operator mode), the service validates all hosts are in `known` state, generates Ignition configs as described above, transitions the cluster to `preparing-for-installation` then `installing`, and begins issuing installation commands to each host via the next-steps mechanism.

The installation step tells the agent to run a privileged container:

```
sudo podman run -e CLUSTER_ID=<id> -e DEVICE=<boot disk> \
  -v /dev:/dev:rw --privileged --pid=host \
  quay.io/openshift/assisted-installer:latest -r <role>
```

### Coordination order across hosts

The assisted-service coordinates a specific installation sequence: **non-bootstrap control plane nodes install first** (they write RHCOS to disk and reboot), then **worker nodes install**, and the **bootstrap node installs last** — only after two other master nodes are ready. This ordering ensures the bootstrap's temporary control plane is available for the other masters to fetch their configs from.

### Disk write: coreos-installer in action

The `coreos-installer install` command writes the RHCOS "metal" raw disk image to the target device. The RHCOS image is optimized to be sourced from the live CD itself when possible, avoiding re-download. The resulting GPT partition table contains:

- **Partition 1** (BIOS-BOOT, ~1 MiB): GRUB stage 2 for legacy BIOS systems
- **Partition 2** (EFI-SYSTEM, ~127 MiB): EFI System Partition with GRUB EFI bootloader
- **Partition 3** (boot, ~384 MiB, ext4): kernel, initramfs, GRUB config
- **Partition 4** (root, remaining space, XFS): the OSTree root filesystem at `/sysroot/ostree/deploy/rhcos/`, with `/var` as a bind mount from this same partition

After writing the image, `coreos-installer` injects the Ignition config into the boot partition so Ignition can find it on first boot. The root partition is automatically grown to fill remaining disk space on first boot by `ignition-ostree-growfs.service`.

### First boot: Ignition takes over

After reboot from the installed disk, the sequence is: GRUB loads kernel + initramfs → **Ignition runs in the initramfs** before pivot to real root. For master/worker nodes with pointer Ignition configs, Ignition follows the `source` URL to fetch the full rendered config from the MCS at `https://api-int.<cluster>.<domain>:22623/config/master`. This is the critical **stage-2 fetch**. Ignition then creates disk partitions (if specified), writes files to disk (certificates, kubelet config, pull secret at `/var/lib/kubelet/config.json`, static pod manifests to `/etc/kubernetes/manifests/`), creates the `core` user with SSH keys, enables systemd units (`kubelet.service`, `crio.service`), and configures networking. After Ignition completes, systemd starts CRI-O and kubelet, which reads static pod manifests and begins pulling container images.

### The bootstrap process in detail

Unlike IPI's separate bootstrap VM, the Assisted Installer's bootstrap runs on an actual master node. Here is the exact sequence:

**Phase 1 — Bootstrap services start.** The designated bootstrap node boots with `bootstrap.ign` written directly to disk. `bootkube.service` starts and brings up the temporary control plane: a **single-member etcd** as a static pod, then **kube-apiserver**, **kube-controller-manager**, and **kube-scheduler** — all as static pods managed by kubelet from manifests in `/etc/kubernetes/manifests/`. The **machine-config-server (MCS)** starts on port 22623, serving rendered Ignition configs. The API VIP is active on this node via keepalived.

**Phase 2 — Other masters join.** The non-bootstrap masters boot from their installed disks with the pointer Ignition. They contact the MCS via the API VIP, receive their full rendered master config, configure themselves, and start kubelet + CRI-O. Each master starts its own etcd member.

**Phase 3 — etcd cluster formation.** The **cluster-etcd-operator** manages the etcd member lifecycle. Starting from the single bootstrap member, it adds the other masters' etcd instances as members, scaling from 1 to 3. For OCP ≥4.7, the etcd operator handles this natively; older versions required the assisted-installer to patch etcd config to allow fewer than 3 members.

**Phase 4 — Bootstrap completion.** The bootstrap is complete when: etcd quorum is achieved (3 healthy members), the API server is running on all 3 masters, critical cluster operators report `Available`, and `bootkube.service` completes successfully.

**Phase 5 — Bootstrap pivot.** The assisted-installer on the bootstrap node waits for 2 ready master nodes and `bootkube.service` completion. It then **pivots**: fetches `master.ign`, runs `coreos-installer` to write RHCOS + master Ignition to disk, and reboots. On reboot, the node fetches its full config from the MCS (now served by the other masters), joins the cluster as a regular master, and the temporary bootstrap control plane is gone.

### The assisted-installer-controller: in-cluster monitoring

During bootstrap, an **assisted-installer-controller** pod is deployed into the nascent cluster in the `assisted-installer` namespace. Built from `Dockerfile.assisted-installer-controller` in the `openshift/assisted-installer` repo, it serves as the bridge between the forming cluster and the external assisted-service. It monitors all ClusterOperator CRs for Available/Progressing/Degraded conditions, approves pending CSRs for nodes joining the cluster, uploads installation logs, applies node labels (only when nodes are Ready), and ultimately calls the `completeInstallation` endpoint on the assisted-service when all operators are healthy. It communicates back via REST API calls authenticated with the cluster ID and pull-secret token.

---

## 7. SNO: bootstrap-in-place without the pivot

Single Node OpenShift follows a fundamentally different bootstrap flow. The `install-config.yaml` uses `platform: none` (no keepalived/VIPs needed — the node's IP is the API and ingress endpoint directly), `controlPlane.replicas: 1`, `compute[0].replicas: 0` (making the control plane schedulable), and `bootstrapInPlace.installationDisk: /dev/disk/by-id/<disk_id>`.

The bootstrap runs **from the live ISO in RAM**: a single-member etcd starts, the full temporary control plane comes up, and the `cluster-bootstrap` binary (invoked with `--bootstrap-in-place` flag) takes the master Ignition as input and **enriches** it with control plane static pod manifests and an etcd database snapshot. `coreos-installer` writes RHCOS + this enriched Ignition to disk. On reboot, etcd starts from the snapshot (not from scratch), the production control plane static pods start, and the node registers with its own API server. No pivot is needed since the node is already the only master.

---

## 8. State machines and orchestration

### Host state transitions

The host state machine (implemented in `internal/host/statemachine.go` using the `stateswitch` Go library) drives every host through a defined lifecycle:

`discovering` → `insufficient` (validations fail) or → `known` (all pass) → `preparing-for-installation` → `installing` → `installing-in-progress` → `installed`

Additional states include `pending-for-input` (awaiting user configuration), `binding` (late-binding to a cluster), `installing-pending-user-action` (e.g., wrong boot order — host rebooted from ISO instead of disk), `error`, `cancelled`, `resetting`, and `added-to-existing-cluster` (for day-2 workers). A background **host monitor goroutine** on the leader instance of the assisted-service periodically re-evaluates validations and drives transitions.

### Cluster state transitions

The cluster state machine (in `internal/cluster/statemachine.go`) tracks:

`pending-for-input` → `insufficient` → `ready` → `preparing-for-installation` → `installing` → `finalizing` → `installed`

The `ready` → `preparing-for-installation` transition fires when the user triggers installation. `preparing-for-installation` → `installing` fires when all hosts have prepared successfully. `installing` → `finalizing` fires when sufficient masters and workers reach installing/installed status (`enoughMastersAndWorkers` check). **`finalizing` → `installed`** requires: all hosts in `done` state, all ClusterOperators reporting Available, the console operator specifically available (for AMS subscription console URL update), and the `completeInstallation` API call succeeding. Timeout conditions (`IsInstallationTimedOut`, `IsFinalizingTimedOut`, `IsPreparingTimedOut`) can drive transitions to `error`.

### Error handling and retries

If a host fails during installation, it transitions to `error`. When a cluster enters `error`, hosts are set to `resetting-pending-user-action`. Users can **reset** the installation, moving the cluster back to `ready` and resetting host states. The service includes configurable timeout deadlines for each phase. If monitoring exceeds deadlines, clusters are temporarily blacklisted to prevent liveness probe failures. Log collection via the `logs gather` step command and `logs_sender` binary ensures diagnostic data is preserved even on failure.

---

## 9. Cluster operators: from API server to fully ready

### The ClusterVersion Operator drives everything

The **Cluster Version Operator (CVO)** runs as a Deployment in `openshift-cluster-version`. It pulls the release payload image (e.g., `quay.io/openshift-release-dev/ocp-release:4.14.6-x86_64`), extracts manifests from `/release-manifests/` inside the image, and systematically reconciles all resources to match. Manifests are ordered by **runlevels** encoded in filename prefixes (e.g., `0000_05_` for early infrastructure, `0000_50_` for mid-level operators, `0000_70_` for higher-level services). The CVO applies all manifests at a given runlevel, waits for stability (all ClusterOperators at that level report `Available=True, Degraded=False`), then advances to the next runlevel.

### Critical operators and their roles

**cluster-etcd-operator** (namespace: `openshift-etcd-operator`): manages the etcd cluster post-bootstrap — member lifecycle, scaling, backup recommendations. Without healthy etcd, nothing else works.

**machine-config-operator** (namespace: `openshift-machine-config-operator`): manages OS-level configuration via MachineConfig CRs. Deploys the machine-config-server (port 22623 for serving Ignition to new nodes), machine-config-controller (renders MachineConfigs, manages MachineConfigPools), and machine-config-daemon (DaemonSet on every node that applies configurations).

**cluster-network-operator** (namespace: `openshift-network-operator`): deploys **OVN-Kubernetes** (default since OCP 4.12+) or OpenShiftSDN. Sets up pod networking, service networking, and network policy enforcement. Manages DaemonSets like `ovnkube-node`.

**dns-operator** (namespace: `openshift-dns-operator`): deploys **CoreDNS** as a DaemonSet in `openshift-dns` for in-cluster DNS resolution.

**ingress-operator** (namespace: `openshift-ingress-operator`): deploys HAProxy-based router pods in `openshift-ingress`. Handles Routes, TLS termination, and wildcard `*.apps` domain routing. The Ingress VIP migrates to schedulable nodes.

Every operator reports status via a `ClusterOperator` CR (`config.openshift.io/v1`) with three conditions: **Available** (operand is functional), **Progressing** (actively reconciling), and **Degraded** (error preventing normal function). The healthy state is `Available=True, Progressing=False, Degraded=False`.

### When is the cluster actually "ready"?

From the CVO's perspective: all ClusterOperators report Available and the `ClusterVersion` resource shows `Available=True, Progressing=False`. From the **assisted-service's perspective**, the bar is higher: the `finalizing` → `installed` transition requires all hosts in `done` state, all ClusterOperators available, console operator specifically available, CSRs approved, AMS subscription updated, and logs uploaded. The assisted-service tracks a richer completion definition than the CVO alone.

---

## 10. Comparing every installation method

All OpenShift installation methods converge on the same fundamental flow: **Ignition → bootstrap → temporary control plane → etcd formation → CVO → cluster operators → production control plane → workers → cluster ready**. The differences lie in how each method bootstraps and provisions infrastructure.

**IPI** uses `openshift-install create cluster`, which runs an embedded Terraform provider to create cloud resources (VPC, subnets, security groups, load balancers, EC2 instances on AWS; VMs on vSphere). A **separate bootstrap VM** is created, hosts the temporary control plane, then is **destroyed automatically** after bootstrap completes. For bare metal IPI, a provisioner node runs Ironic/Metal3 for BMC-based provisioning over a dedicated provisioning network.

**UPI** has the user run `openshift-install create ignition-configs` to produce the three Ignition files, then **manually** provision infrastructure, configure DNS, set up load balancers, distribute Ignition configs, boot machines, wait for bootstrap completion (`openshift-install wait-for bootstrap-complete`), destroy the bootstrap node, and approve worker CSRs. Same bootstrap flow, maximum user responsibility.

**Agent-based installer** uses `openshift-install agent create image` to produce a self-contained ISO embedding the assisted-service, agent, cluster config, and RHCOS images. The rendezvous host runs the service ephemerally. Same agent, same service codebase as the hosted Assisted Installer — but fully disconnected-capable with no external dependencies. After validation, non-bootstrap nodes reboot first; the rendezvous/bootstrap host reboots last. Monitoring via `openshift-install agent wait-for install-complete`.

**The Assisted Installer** (SaaS or operator mode) provides the same agent-driven discovery and validation as the agent-based installer, but with a persistent external service for multi-cluster management, a web UI, event tracking, and log collection. Bootstrap-in-place eliminates the extra node. Pre-flight validation catches problems before disk writes begin.

---

## 11. RHCOS and Machine Config: the immutable OS layer

### What RHCOS actually is

Red Hat Enterprise Linux CoreOS is an **immutable, image-based OS** built on `rpm-ostree` and `libostree`. The root filesystem under `/usr` is **read-only** — managed by OSTree, which maintains atomic filesystem deployments under `/sysroot/ostree/deploy/rhcos/deploy/<hash>/`. Only `/var` and `/etc` are writable (`/etc` gets three-way merged during updates). **CRI-O** is the container runtime (not Docker). Podman, skopeo, and crictl are available for container operations.

The disk partition layout: partition 1 is BIOS-BOOT (~1 MiB), partition 2 is EFI-SYSTEM (~127 MiB), partition 3 is boot (~384 MiB, ext4, containing kernel/initramfs/GRUB), and partition 4 is root (remaining space, XFS, the OSTree deployment). `/var/lib/containers` holds container image storage, `/var/lib/kubelet` holds kubelet data, and `/var/lib/etcd` holds etcd data on control plane nodes. `rpm-ostree status` shows current and previous deployments; only 2 are kept by default for atomic rollback via `rpm-ostree rollback`.

### Machine Config Operator: day-2 OS management

The MCO consists of four components in `openshift-machine-config-operator`: the **machine-config-operator** pod (main controller), **machine-config-server** (DaemonSet on control plane, serves Ignition on port 22623), **machine-config-controller** (renders MachineConfigs, manages pools), and **machine-config-daemon** (DaemonSet on every node, applies configs).

`MachineConfig` CRs use Ignition format internally and can specify files (`spec.config.storage.files[]`), systemd units (`spec.config.systemd.units[]`), kernel arguments (`spec.kernelArguments[]`), extensions (`spec.extensions[]`), and an OS image URL (`spec.osImageURL`). `MachineConfigPool` CRs group nodes by role labels (e.g., `node-role.kubernetes.io/master`). The MCC selects all MachineConfigs matching a pool's selector, **renders** them into a single merged config (e.g., `rendered-worker-a1b2c3d4...`), and the MCD on each node detects when its current config differs from the desired rendered config.

The MCD update flow: **calculate diff** → **cordon and drain the node** → **apply file changes** → **apply systemd unit changes** → **apply kernel arguments** → **perform OS update if osImageURL changed** → **reboot**. For OS updates, the MCD extracts the `machine-os-content` container image (which contains an OSTree repository at `/srv/repo`) and calls `rpm-ostree rebase` to create a new deployment. The bootloader is updated to point to the new deployment, and the node reboots. Node annotations (`machineconfiguration.openshift.io/currentConfig`, `desiredConfig`, `state`) track progress.

### Ignition versus MachineConfig

**Ignition is first-boot only**: it runs once in the initramfs, creates partitions, writes files, enables services, and never runs again (detected by a flag file on the boot partition). **MachineConfig is day-2 ongoing**: the MCD continuously reconciles the node against the desired rendered config. After first boot, the MCO "adopts" the Ignition-applied state: `machine-config-daemon-firstboot.service` reads the encapsulated MachineConfig from `/etc/machine-config-daemon/currentconfig`, performs any necessary OS update if the boot image differs from the target, and reconciles. From that point forward, the MCD owns all configuration. As of OCP 4.10+, the MCD includes a **Config Drift Monitor** using `fsnotify` that watches all managed files and marks the node `Degraded` if external modifications are detected.

---

## Conclusion

The Assisted Installer's power lies in its **separation of discovery from installation**. By running an agent on a live-in-RAM environment that reports hardware inventory and validates readiness against a rich set of server-side checks — before any disk writes occur — it catches misconfigurations that IPI and UPI only surface as cryptic bootstrap failures. The bootstrap-in-place approach eliminates the extra bootstrap node that every other method requires, reducing the minimum hardware footprint.

The architecture is deceptively modular: the same `assisted-service` and `assisted-installer-agent` codebase runs identically whether hosted on `console.redhat.com`, deployed as an operator on a hub cluster, or running ephemerally on a rendezvous host for the agent-based installer. The CRD layer (InfraEnv, ClusterDeployment, AgentClusterInstall, Agent) is a Kubernetes-native translation layer that the infrastructure-operator reconciles into internal API calls — not a separate system.

The key insight for anyone working on this codebase: **every state transition in the host and cluster state machines has explicit preconditions defined in `internal/host/statemachine.go` and `internal/cluster/transition.go`**. These are the source of truth for what can happen and when. The next-step polling mechanism is the heartbeat of the system — every action the agent takes, from inventory collection through disk writes, flows through `GET .../instructions` → execute → `POST .../instructions/{id}`. Understanding this request-response cycle and the state machines that drive it is understanding the Assisted Installer.
