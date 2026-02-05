# Roadmap

This project will be built in stages. Each stage is a self-contained directory under `stages/` with its own README, references, and (if needed) scripts. Each stage will be committed separately.

**Guiding principles**
- Accuracy over speed.
- Reproducibility over convenience.
- Explicit verification of each critical step.

**Planned stages**
1. `00-charter` (done)
2. `01-sources-and-version-pin` (done)
3. `02-architecture-map` (done)
4. `03-lab-and-network-prereqs` (done)
5. `04-release-payload-and-tools` (done)
6. `05-rhcos-and-ostree` (planned)
7. `06-ignition-and-butane` (planned)
8. `07-bootstrap-and-bootkube` (planned)
9. `08-etcd-and-control-plane` (planned)
10. `09-pivot-and-mco-handoff` (planned)
11. `10-worker-join-and-csr-flow` (planned)
12. `11-cluster-operators-and-cvo` (planned)
13. `12-day2-and-upgrades` (planned)
14. `13-assisted-and-agent-based-flows` (planned)
15. `14-validation-and-troubleshooting` (planned)

**Open questions**
- Baseline version pinned to 4.18 (from local PDFs). Decide how to present deltas for newer versions.
- Which path(s) to validate first on the provided bare metal (manual UPI-like or Assisted/ABI internals).
