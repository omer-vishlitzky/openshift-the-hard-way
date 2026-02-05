# OpenShift the Hard Way

A hands-on, from-scratch walkthrough of how OpenShift 4.x actually comes together on bare metal. This repo aims to explain and reproduce the installer logic step by step, with minimal automation, so engineers can understand ignition, RHCOS, OSTree, bootstrapping, etcd, and the control-plane pivot at a deep level.

This is an educational, "see the gears" project. It is not a supported installation method.

**What this is**
- A staged, repeatable path to building a cluster by hand.
- A deep dive into the components and their interactions.
- A reference for Assisted Installer, Agent-based Installer, and UPI internals.

**What this is not**
- A replacement for `openshift-install` or Assisted Installer.
- A production support guide.
- A fast path.

**How to use this repo**
- Start at `stages/00-charter/README.md` and proceed in order.
- Each stage includes prerequisites, steps, expected outputs, and validation checks.
- Scripts are used only when they clarify or automate repetitive, transparent steps.

**Status**
- Early scaffolding. Stages 00 through 02 are complete. The roadmap and upcoming stages are defined in `ROADMAP.md`.
- Baseline version: OpenShift 4.18 (from local documentation set in `../pdfs/openshift`).

**Source material**
- Official OpenShift documentation PDFs in `../pdfs`.
- Upstream and OpenShift repositories (documented per-stage).
- Public docs and references gathered as needed.

If you are here to understand how the installers work, you are in the right place.
