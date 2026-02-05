# Stage 01: Sources and Version Pin

This stage establishes the baseline OpenShift version for the guide and enumerates the authoritative sources we will use throughout the project.

**Baseline version**
- The local OpenShift documentation set in `../pdfs/openshift` is for OpenShift Container Platform **4.18**.
Evidence:
- `../pdfs/openshift/Installing_on_bare_metal.txt` begins with "OpenShift Container Platform 4.18" and shows "Last Updated: 2025-06-16".
- `../pdfs/openshift/Installation_overview.pdf` metadata title contains "OpenShift Container Platform 4.18 Installation overview" (creation date 2025-06-16).

**Version policy**
- This guide will be **pinned to 4.18** as the baseline.
- When behavior differs in newer releases, we will call out the delta explicitly.
- We will avoid hard-coding an installer "path"; instead, we will explain the underlying mechanics so knowledge transfers across HA and SNO.

**Primary local sources (PDFs)**
- `../pdfs/openshift/Architecture.pdf`
- `../pdfs/openshift/Installation_overview.pdf`
- `../pdfs/openshift/Installation_configuration.pdf`
- `../pdfs/openshift/Installing_on_bare_metal.pdf`
- `../pdfs/openshift/Installing_on-premise_with_Assisted_Installer.pdf`
- `../pdfs/openshift/Installing_an_on-premise_cluster_with_the_Agent-based_Installer.pdf`
- `../pdfs/openshift/Networking.pdf`
- `../pdfs/openshift/Nodes.pdf`
- `../pdfs/openshift/Machine_configuration.pdf`
- `../pdfs/openshift/Storage.pdf`
- `../pdfs/openshift/Security_and_compliance.pdf`
- `../pdfs/openshift/Validation_and_troubleshooting.pdf`

**Primary upstream codebases (to be referenced with exact versions)**
- OpenShift installer: `openshift/installer`
- Assisted Installer service: `openshift/assisted-service`
- Assisted Installer agent: `openshift/assisted-installer-agent`
- Assisted Installer worker: `openshift/assisted-installer`
- Assisted image service: `openshift/assisted-image-service`
- Bootstrapping: `openshift/cluster-bootstrap`
- Machine Config Operator: `openshift/machine-config-operator`
- Cluster Version Operator: `openshift/cluster-version-operator`
- Etcd operator: `openshift/cluster-etcd-operator`

**Outcomes of this stage**
- Version baseline is pinned to 4.18.
- Source inventory is defined for use in later stages.
