# Roadmap

This project will be built in stages. Each stage is a self-contained directory under `stages/` with its own README, references, and (if needed) scripts. Each stage will be committed separately.

**Guiding principles**
- Accuracy over speed.
- Reproducibility over convenience.
- Explicit verification of each critical step.

**Planned stages**
1. `00-charter` (done)
2. `01-sources-and-version-pin` (done)
3. `02-foundations` (done)
4. `03-architecture-map` (done)
5. `04-lab-and-network-prereqs` (done)
6. `05-release-payload-and-tools` (done)
7. `06-rhcos-and-ostree` (done)
8. `07-ignition-and-butane` (done)
9. `08-bootstrap-and-bootkube` (done)
10. `09-etcd-and-control-plane` (done)
11. `10-pivot-and-mco-handoff` (done)
12. `11-worker-join-and-csr-flow` (done)
13. `12-cluster-operators-and-cvo` (done)
14. `13-day2-and-upgrades` (done)
15. `14-assisted-and-agent-based-flows` (done)
16. `15-validation-and-troubleshooting` (done)
17. `16-manual-install-runbook` (done)

**Open questions**
- Baseline version pinned to 4.18 (from local PDFs). Decide how to present deltas for newer versions.
- Which path(s) to validate first on the provided bare metal (manual UPI-like or Assisted/ABI internals).
- How far to go in manual asset generation before using any installer as a reference.
