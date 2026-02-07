#!/bin/bash
# bootkube.sh - Bootstrap orchestrator for OpenShift
#
# This script runs on the bootstrap node at first boot (via systemd).
#
# By the time this runs, kubelet has already started the static pods
# (etcd, apiserver, kcm, scheduler) from /etc/kubernetes/manifests/.
# Our job is to:
#   1. Wait for them to become healthy
#   2. Apply cluster manifests (namespaces, RBAC, CRDs, operators)
#   3. Wait for masters to join
#
# The manifests were written by hand in Stage 07 and embedded in Stage 08.
# Nothing is rendered at runtime — everything is pre-baked.

set -euo pipefail

ASSET_DIR=/opt/openshift
KUBECONFIG=/etc/kubernetes/kubeconfigs/localhost.kubeconfig

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

wait_for() {
    local name=$1
    local cmd=$2
    local timeout=${3:-300}

    log "Waiting for ${name}..."
    local start=$(date +%s)
    until eval "$cmd" &>/dev/null; do
        local elapsed=$(($(date +%s) - start))
        if [[ $elapsed -gt $timeout ]]; then
            log "TIMEOUT: ${name} not ready after ${timeout}s"
            return 1
        fi
        sleep 5
    done
    log "${name} is ready"
}

log "=== OpenShift Bootstrap ==="

# Step 1: Wait for etcd
# etcd has an HTTPS /health endpoint. We use curl with client certs.
wait_for "etcd" \
    "curl -sk --cacert /etc/kubernetes/bootstrap-secrets/etcd-ca.crt --cert /etc/kubernetes/bootstrap-secrets/etcd-server.crt --key /etc/kubernetes/bootstrap-secrets/etcd-server.key https://localhost:2379/health | grep -q true" \
    180

# Step 2: Wait for API server
# The API server connects to etcd. It's healthy when /healthz returns ok.
wait_for "kube-apiserver" \
    "curl -sk https://localhost:6443/healthz" \
    180

# Step 3: Apply OpenShift CRDs
# These define the API types (Infrastructure, Network, etc.) that CVO needs.
log "Applying OpenShift CRDs..."
for crd in ${ASSET_DIR}/crds/*.yaml; do
    [[ -f "$crd" ]] && oc --kubeconfig=${KUBECONFIG} apply -f "$crd" 2>&1 || true
done
log "CRDs applied"

# Step 4: Apply cluster manifests
# These are the namespaces, RBAC rules, CRDs, and operator definitions
# that turn a bare Kubernetes cluster into an OpenShift cluster.
log "Applying cluster manifests..."

for manifest in ${ASSET_DIR}/manifests/*.yaml; do
    if [[ -f "$manifest" ]]; then
        log "  $(basename $manifest)"
        oc --kubeconfig=${KUBECONFIG} apply -f "$manifest" 2>&1 || true
    fi
done

log "Manifests applied"

# Step 4: Wait for masters to join
# Each master has its own complete ignition config (no MCS intermediary).
# They boot, start kubelet, and register as nodes.
log "Waiting for masters to register..."

TIMEOUT=1800
START=$(date +%s)
while true; do
    READY=$(oc --kubeconfig=${KUBECONFIG} get nodes -l node-role.kubernetes.io/master --no-headers 2>/dev/null | grep -c " Ready ") || READY=0
    log "  Ready masters: ${READY}/3"

    [[ "$READY" -ge 3 ]] && break

    ELAPSED=$(($(date +%s) - START))
    if [[ $ELAPSED -gt $TIMEOUT ]]; then
        log "TIMEOUT: only ${READY}/3 masters after ${TIMEOUT}s"
        exit 1
    fi
    sleep 30
done

log ""
log "=== Bootstrap Complete ==="
log "All 3 masters joined. You can now:"
log "  1. Remove bootstrap from HAProxy"
log "  2. Shut down the bootstrap node"

touch ${ASSET_DIR}/.bootkube.done
