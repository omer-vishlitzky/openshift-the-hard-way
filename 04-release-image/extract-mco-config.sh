#!/bin/bash
# Run MCO bootstrap render to produce rendered MachineConfigs for master and worker pools.
#
# MCO is a template engine: it takes cluster config (networking CIDRs, platform type,
# DNS, etc.) and produces complete node ignition configs. The output includes everything
# a node needs at the OS level: OVS bridge setup, kubelet systemd unit, CRI-O config,
# NetworkManager scripts, SELinux policies, and 30+ other files and services.
#
# This runs two MCO commands:
#   1. `machine-config-operator bootstrap` — renders the ControllerConfig, MachineConfigPools,
#      and the MCC bootstrap pod manifest from cluster config inputs
#   2. `machine-config-controller bootstrap` — reads those templates plus the image-references,
#      generates all component MachineConfigs (kubelet, CRI-O, OVS, etc.), merges them per pool,
#      and writes rendered-master and rendered-worker MachineConfigs with full ignition
#
# The rendered ignition is in each MachineConfig's .spec.config.raw field.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/cluster-vars.sh"
source "${SCRIPT_DIR}/component-images.sh"

MCO_DIR="${ASSETS_DIR}/mco-rendered"
MCO_WORK="${MCO_DIR}/work"
rm -rf "${MCO_DIR}"
mkdir -p "${MCO_WORK}/manifests" "${MCO_WORK}/tls"

echo "=== MCO Bootstrap Render ==="
echo "Output: ${MCO_DIR}"
echo ""

# --- Prepare input files that MCO expects ---

# 1. Root CA (PEM)
cp "${PKI_DIR}/root-ca.crt" "${MCO_WORK}/tls/root-ca.crt"

# 2. Kube API server serving CA bundle (PEM)
# MCO uses this to configure kubelet's server CA. We use the kubernetes CA.
cp "${PKI_DIR}/kubernetes-ca.crt" "${MCO_WORK}/tls/kube-apiserver-complete-client-ca-bundle.crt"

# 3. cluster-config.yaml — the install-config wrapped in a ConfigMap
# MCO reads this to determine platform, networking, replicas, etc.
cat > "${MCO_WORK}/manifests/cluster-config.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-config-v1
  namespace: kube-system
data:
  install-config: |
    apiVersion: v1
    metadata:
      name: ${CLUSTER_NAME}
    baseDomain: ${BASE_DOMAIN}
    networking:
      networkType: OVNKubernetes
      clusterNetwork:
      - cidr: ${CLUSTER_NETWORK_CIDR}
        hostPrefix: ${CLUSTER_NETWORK_HOST_PREFIX}
      serviceNetwork:
      - ${SERVICE_NETWORK_CIDR}
      machineNetwork:
      - cidr: ${MACHINE_NETWORK}
    platform:
      none: {}
    controlPlane:
      replicas: 3
    compute:
    - replicas: 2
EOF

# 4. Pull secret as a Kubernetes Secret manifest
PULL_SECRET_B64=$(base64 -w0 "${PULL_SECRET_FILE}")
cat > "${MCO_WORK}/manifests/openshift-config-secret-pull-secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: pull-secret
  namespace: openshift-config
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: ${PULL_SECRET_B64}
EOF

# 5. Infrastructure CR
cat > "${MCO_WORK}/manifests/cluster-infrastructure-02-config.yml" <<EOF
apiVersion: config.openshift.io/v1
kind: Infrastructure
metadata:
  name: cluster
spec:
  platformSpec:
    type: None
status:
  platform: None
  platformStatus:
    type: None
  apiServerURL: ${API_URL}
  apiServerInternalURL: ${API_INT_URL}
  controlPlaneTopology: HighlyAvailable
  infrastructureTopology: HighlyAvailable
EOF

# 6. Network CR
cat > "${MCO_WORK}/manifests/cluster-network-02-config.yml" <<EOF
apiVersion: config.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  clusterNetwork:
  - cidr: ${CLUSTER_NETWORK_CIDR}
    hostPrefix: ${CLUSTER_NETWORK_HOST_PREFIX}
  serviceNetwork:
  - ${SERVICE_NETWORK_CIDR}
  networkType: OVNKubernetes
EOF

# 7. DNS CR
cat > "${MCO_WORK}/manifests/cluster-dns-02-config.yml" <<EOF
apiVersion: config.openshift.io/v1
kind: DNS
metadata:
  name: cluster
spec:
  baseDomain: ${BASE_DOMAIN}
EOF

# 8. Proxy CR (empty — no proxy)
cat > "${MCO_WORK}/manifests/cluster-proxy-01-config.yaml" <<EOF
apiVersion: config.openshift.io/v1
kind: Proxy
metadata:
  name: cluster
spec: {}
EOF

# 9. FeatureGate CR (required by MCC bootstrap)
cat > "${MCO_WORK}/manifests/featuregate.yaml" <<'EOF'
apiVersion: config.openshift.io/v1
kind: FeatureGate
metadata:
  name: cluster
spec:
  featureSet: ""
EOF

# 10. Image references — extract from the release image
echo "Extracting image-references from release image..."
podman run --rm --quiet --net=none \
  --authfile "${PULL_SECRET_FILE}" \
  --entrypoint cat \
  "${OCP_RELEASE_IMAGE}" \
  /release-manifests/image-references > "${MCO_WORK}/image-references"

# Get the release version
VERSION=$(podman run --rm --quiet --net=none \
  --authfile "${PULL_SECRET_FILE}" \
  --entrypoint cat \
  "${OCP_RELEASE_IMAGE}" \
  /release-manifests/release-metadata | jq -r '.version')
echo "Release version: ${VERSION}"

# --- Step 1: machine-config-operator bootstrap ---
# Renders ControllerConfig, MachineConfigPools, and the bootstrap pod manifest.

echo ""
echo "Step 1: Rendering MCO bootstrap templates..."
podman run --rm \
  --user 0 \
  --authfile "${PULL_SECRET_FILE}" \
  --volume "${MCO_WORK}:/assets:z" \
  "${MACHINE_CONFIG_OPERATOR_IMAGE}" \
  bootstrap \
    --root-ca=/assets/tls/root-ca.crt \
    --kube-ca=/assets/tls/kube-apiserver-complete-client-ca-bundle.crt \
    --config-file=/assets/manifests/cluster-config.yaml \
    --dest-dir=/assets/mco-bootstrap \
    --pull-secret=/assets/manifests/openshift-config-secret-pull-secret.yaml \
    --release-image="${OCP_RELEASE_IMAGE}" \
    --image-references=/assets/image-references \
    --payload-version="${VERSION}"

echo "  ControllerConfig, MachineConfigPools written to mco-bootstrap/"

# --- Step 2: machine-config-controller bootstrap ---
# Reads the ControllerConfig + MachineConfigPools from step 1, generates all
# component MachineConfigs (kubelet config, CRI-O, OVS, etc.), merges them
# per pool, and writes fully rendered MachineConfigs with complete ignition.

echo ""
echo "Step 2: Rendering MachineConfigs (this produces the actual ignition)..."

# MCC expects all manifests in a single directory. Combine the MCO bootstrap
# output with our cluster manifests.
MCC_INPUT="${MCO_WORK}/mcc-input"
mkdir -p "${MCC_INPUT}"
cp "${MCO_WORK}/mco-bootstrap/bootstrap/manifests/"* "${MCC_INPUT}/"
cp "${MCO_WORK}/manifests/featuregate.yaml" "${MCC_INPUT}/"
cp "${MCO_WORK}/image-references" "${MCC_INPUT}/"

podman run --rm \
  --user 0 \
  --authfile "${PULL_SECRET_FILE}" \
  --volume "${MCO_WORK}:/assets:z" \
  --entrypoint /usr/bin/machine-config-controller \
  "${MACHINE_CONFIG_OPERATOR_IMAGE}" \
  bootstrap \
    --manifest-dir=/assets/mcc-input \
    --dest-dir=/assets/mcc-output \
    --pull-secret=/assets/mco-bootstrap/bootstrap/manifests/machineconfigcontroller-pull-secret

echo "  Rendered MachineConfigs written to mcc-output/"

# --- Step 3: Extract rendered ignition from MachineConfigs ---
# The rendered MachineConfig's .spec.config.raw contains the complete ignition JSON.

echo ""
echo "Step 3: Extracting rendered ignition configs..."

MCC_OUTPUT="${MCO_WORK}/mcc-output"

# Find the rendered master and worker MachineConfig files
MASTER_MC=$(ls "${MCC_OUTPUT}/machine-configs/rendered-master-"*.yaml 2>/dev/null | head -1)
WORKER_MC=$(ls "${MCC_OUTPUT}/machine-configs/rendered-worker-"*.yaml 2>/dev/null | head -1)

if [[ -z "${MASTER_MC}" ]] || [[ -z "${WORKER_MC}" ]]; then
    echo "ERROR: Rendered MachineConfigs not found in ${MCC_OUTPUT}/machine-configs/"
    ls -la "${MCC_OUTPUT}/machine-configs/" 2>/dev/null || echo "  Directory does not exist"
    exit 1
fi

# Extract .spec.config.raw (which is the Ignition JSON)
python3 -c "
import yaml, json, sys
with open('${MASTER_MC}') as f:
    mc = yaml.safe_load(f)
raw = mc['spec']['config']['raw']
if isinstance(raw, str):
    ign = json.loads(raw)
else:
    ign = raw
json.dump(ign, sys.stdout, indent=2)
" > "${MCO_DIR}/master-ignition.json"

python3 -c "
import yaml, json, sys
with open('${WORKER_MC}') as f:
    mc = yaml.safe_load(f)
raw = mc['spec']['config']['raw']
if isinstance(raw, str):
    ign = json.loads(raw)
else:
    ign = raw
json.dump(ign, sys.stdout, indent=2)
" > "${MCO_DIR}/worker-ignition.json"

echo "  Master ignition: ${MCO_DIR}/master-ignition.json ($(du -h "${MCO_DIR}/master-ignition.json" | cut -f1))"
echo "  Worker ignition: ${MCO_DIR}/worker-ignition.json ($(du -h "${MCO_DIR}/worker-ignition.json" | cut -f1))"

# --- Show what MCO produced ---

echo ""
echo "=== MCO Rendered Content ==="
echo ""
echo "Files MCO puts on master nodes:"
python3 -c "
import json
with open('${MCO_DIR}/master-ignition.json') as f:
    ign = json.load(f)
files = ign.get('storage', {}).get('files', [])
units = ign.get('systemd', {}).get('units', [])
print(f'  {len(files)} files:')
for f in sorted(files, key=lambda x: x['path']):
    print(f'    {f[\"path\"]}')
print(f'  {len(units)} systemd units:')
for u in sorted(units, key=lambda x: x['name']):
    enabled = u.get('enabled', False)
    marker = '●' if enabled else '○'
    print(f'    {marker} {u[\"name\"]}')
"

echo ""
echo "=== MCO Bootstrap Render Complete ==="
echo ""
echo "These ignition configs contain everything a RHCOS node needs:"
echo "  - OVS bridge setup (configure-ovs.sh, br-ex)"
echo "  - kubelet.service with OpenShift flags"
echo "  - CRI-O configuration"
echo "  - nodeip-configuration.service"
echo "  - SELinux policies and restorecon"
echo "  - NetworkManager dispatcher scripts"
echo "  - 20+ more systemd units and config files"
echo ""
echo "Next: build-master.sh and build-worker.sh will merge these"
echo "with per-node config (static IP, kube-proxy, bootstrap kubeconfig)."
