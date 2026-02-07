# OpenShift the Hard Way

## What This Is

A KTHW-equivalent guide for OpenShift. You build the core by hand: PKI, kubeconfigs, etcd, apiserver, kubelet bootstrap, node join, CSR approval. CVO handles the 50+ operators nobody learns anything from hand-writing.

## Rules

1. **One way.** Never present multiple options. Pick the simplest way that works. No "alternatively", no "or you could also", no branches.

2. **Simplicity over correctness.** Scripts convey the idea clearly. No defensive programming, no excessive error handling, no if/else fallbacks. Fail fast.

3. **No black boxes.** Every manifest is hand-written. No operator containers rendering things. If we can't explain every field, we don't use it.

4. **No spoon-feeding.** The reader is a developer. "Run `oc get pods`" is enough. Don't explain how to set KUBECONFIG or what a namespace is.

5. **Nothing unnecessary.** If it can be removed, remove it. No comments on obvious code. No docs nobody reads. No tools we don't use.

6. **Hand-write what matters, delegate what doesn't.** etcd, apiserver, kubelet, certificates, RBAC — by hand. Prometheus, console, image-registry — CVO handles it.
