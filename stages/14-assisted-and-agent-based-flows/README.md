# Stage 14: Assisted and Agent-based Flows

This stage explains how the Assisted Installer and Agent-based Installer work under the hood. The goal is to map their convenience back to the same manual artifacts and bootstrap phases.

**Sources used in this stage**
- `../pdfs/openshift/Installation_overview.pdf`
- `../pdfs/openshift/Installing_on-premise_with_Assisted_Installer.pdf`
- `../pdfs/openshift/Installing_an_on-premise_cluster_with_the_Agent-based_Installer.pdf`

## Shared mechanics

Both Assisted and Agent-based installers:
- Collect hardware inventory from hosts.
- Validate cluster requirements before installation.
- Generate Ignition configs dynamically.
- Use `coreos-installer` to write RHCOS to disk.
- Run the same bootstrap and pivot phases as any other OpenShift installation.

## Assisted Installer (service-driven)

- A central Assisted service manages clusters, hosts, and state.
- You create cluster settings via UI or API.
- The service generates a discovery ISO that embeds its identity.
- Hosts boot the ISO, run the agent, and report inventory.
- The service validates and generates per-host Ignition.

## Agent-based Installer (embedded service)

- You download the Agent-based installer locally.
- It generates a discovery image and embeds the service locally.
- Hosts boot the image and register to the local service.
- This is ideal for disconnected environments.

## Why this matters for the hard way

These flows hide the same core mechanics:
- Discovery ISO is just a RHCOS live environment with an agent.
- Ignition is still the source of truth for node configuration.
- Bootstrap and pivot are unchanged.

## Verification checks

When using Assisted or Agent-based installation:
- The discovery ISO boots and reports inventory.
- All hosts reach `Known` or `Ready` state before install.
- Ignition is generated per-host.
- The bootstrap phase completes and the control plane becomes `Ready`.

**Deliverables for this stage**
- A clear mapping from Assisted flows to manual artifacts.
- A baseline mental model for how the agent works.
