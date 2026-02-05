# Stage 00: Charter and Scope

This stage defines the purpose, boundaries, and working standards for the project.

**Purpose**
- Provide a from-scratch, step-by-step explanation of how an OpenShift 4.x cluster is assembled on bare metal.
- Explain the mechanisms behind ignition, RHCOS, OSTree, bootstrapping, etcd, and the control-plane pivot.
- Map Assisted Installer and Agent-based Installer behavior to concrete, observable system steps.

**Scope**
- OpenShift 4.x on bare metal.
- Manual, transparent steps that mirror what automated installers do.
- Both HA and SNO flows, where they differ.

**Out of scope**
- Cloud IPI specifics.
- Production hardening beyond what is required to understand the installation mechanics.
- Support statements or guarantees.

**Audience**
- OpenShift installer engineers.
- SREs and platform engineers who need a mental model of the install pipeline.

**Definitions (short)**
- RHCOS: Red Hat Enterprise Linux CoreOS, the immutable OS OpenShift runs on.
- Ignition: First-boot provisioning tool for RHCOS.
- OSTree: Image-based OS delivery model used by RHCOS.
- Bootkube: The bootstrap process that brings up the temporary control plane.
- MCO: Machine Config Operator, which takes over node configuration post-install.
- ABI: Agent-based Installer (local, embedded assisted-service).
- AI: Assisted Installer (service-driven, agent-based install).

**Quality bar**
- Every critical operational step has a verification check.
- Version-specific behavior is explicitly pinned and documented.
- Any non-obvious behavior is backed by a cited source or code pointer.

**Repo conventions**
- Stages live under `stages/NN-name/`.
- Each stage has its own README and references.
- Each stage is committed separately.
- Scripts are kept minimal and transparent.

**Safety**
- Many steps are destructive to disks and networking. Always validate targets.
- This is an educational process and not a supported install path.

**Deliverables for this stage**
- Project charter and roadmap.
- A stage-based structure for iterative build-out.
