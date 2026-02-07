# Stage 04: Release Image

The OpenShift release image is a container that contains references to all component images. Understanding it is essential for manual installation.

## What is a Release Image?

A release image is:
- A container image tagged with a version (e.g., `4.14.0-x86_64`)
- Contains a manifest of all component images
- Contains the CVO (Cluster Version Operator) binary
- Acts as the "bill of materials" for an OpenShift version

Location: `quay.io/openshift-release-dev/ocp-release:VERSION-ARCH`

## Step 1: Configure

```bash
source ../config/cluster-vars.sh
echo "Release image: ${OCP_RELEASE_IMAGE}"
```

## Step 2: Examine Release Info

```bash
oc adm release info ${OCP_RELEASE_IMAGE}
```

Output:
```
Name:           4.14.0
Digest:         sha256:abc123...
Created:        2023-10-27T...
OS/Arch:        linux/amd64
Manifests:      665
Metadata files: 1

Pull From: quay.io/openshift-release-dev/ocp-release@sha256:...

Release Metadata:
  Version:  4.14.0
  Upgrades: 4.13.x -> 4.14.0
  Metadata:
    url: https://access.redhat.com/errata/RHSA-2023:...

Component Versions:
  kubernetes 1.27.x
  machine-os 414.92...

Images:
  NAME                                           DIGEST
  aws-cloud-controller-manager                   sha256:...
  aws-cluster-api-controllers                    sha256:...
  aws-ebs-csi-driver                             sha256:...
  ...
  cluster-version-operator                       sha256:...
  ...
  etcd                                           sha256:...
  ...
  (100+ images)
```

## Step 3: Extract Component Images

We need specific component images to write static pod manifests, ignition configs, and cluster manifests. The release image contains 100+ images — we extract the ones we use into a shell file we can source later.

Fetch the release info as JSON:

```bash
RELEASE_JSON=$(oc adm release info "${OCP_RELEASE_IMAGE}" \
    --registry-config="${PULL_SECRET_FILE}" \
    -o json)
```

Each component image is a tag in `.references.spec.tags[]`. Extract a specific one:

```bash
echo "${RELEASE_JSON}" | jq -r '.references.spec.tags[] | select(.name == "etcd") | .from.name'
```

That gives you a pinned image reference like `quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:abc123...`. Every image in a release is pinned by digest — never by tag — so the exact binary is reproducible.

Write all the images we need to a sourceable file:

```bash
get_image() {
    echo "${RELEASE_JSON}" | jq -r ".references.spec.tags[] | select(.name == \"$1\") | .from.name"
}

RELEASE_DIGEST=$(echo "${RELEASE_JSON}" | jq -r '.digest')

cat > 04-release-image/component-images.sh <<EOF
#!/bin/bash
# Component images for OpenShift ${OCP_VERSION}
# Generated from: ${OCP_RELEASE_IMAGE}

export RELEASE_IMAGE="${OCP_RELEASE_IMAGE}"
export RELEASE_DIGEST="${RELEASE_DIGEST}"

# Control Plane Components
export ETCD_IMAGE="$(get_image etcd)"
export HYPERKUBE_IMAGE="$(get_image hyperkube)"
# apiserver, kcm, scheduler all come from hyperkube — no separate image tags exist
export KUBE_APISERVER_IMAGE="\${HYPERKUBE_IMAGE}"
export KUBE_CONTROLLER_MANAGER_IMAGE="\${HYPERKUBE_IMAGE}"
export KUBE_SCHEDULER_IMAGE="\${HYPERKUBE_IMAGE}"

# Operator Images
export CLUSTER_ETCD_OPERATOR_IMAGE="$(get_image cluster-etcd-operator)"
export CLUSTER_KUBE_APISERVER_OPERATOR_IMAGE="$(get_image cluster-kube-apiserver-operator)"
export CLUSTER_KUBE_CONTROLLER_MANAGER_OPERATOR_IMAGE="$(get_image cluster-kube-controller-manager-operator)"
export CLUSTER_KUBE_SCHEDULER_OPERATOR_IMAGE="$(get_image cluster-kube-scheduler-operator)"
export CLUSTER_CONFIG_OPERATOR_IMAGE="$(get_image cluster-config-operator)"
export CLUSTER_NETWORK_OPERATOR_IMAGE="$(get_image cluster-network-operator)"
export CLUSTER_INGRESS_OPERATOR_IMAGE="$(get_image cluster-ingress-operator)"
export MACHINE_CONFIG_OPERATOR_IMAGE="$(get_image machine-config-operator)"
export CLUSTER_VERSION_OPERATOR_IMAGE="$(get_image cluster-version-operator)"
export CLUSTER_BOOTSTRAP_IMAGE="$(get_image cluster-bootstrap)"
export AUTHENTICATION_OPERATOR_IMAGE="$(get_image cluster-authentication-operator)"

# Infrastructure Components
export MACHINE_CONFIG_SERVER_IMAGE="$(get_image machine-config-server)"
export HAPROXY_ROUTER_IMAGE="$(get_image haproxy-router)"
export COREDNS_IMAGE="$(get_image coredns)"
export CLUSTER_DNS_OPERATOR_IMAGE="$(get_image cluster-dns-operator)"
export KEEPALIVED_IPFAILOVER_IMAGE="$(get_image keepalived-ipfailover)"

# Additional Components
export CLI_IMAGE="$(get_image cli)"
export POD_IMAGE="$(get_image pod)"
export OAUTH_PROXY_IMAGE="$(get_image oauth-proxy)"
export OAUTH_SERVER_IMAGE="$(get_image oauth-server)"
export OAUTH_APISERVER_IMAGE="$(get_image oauth-apiserver)"
export KUBE_PROXY_IMAGE="$(get_image kube-proxy)"
export MACHINE_OS_CONTENT_IMAGE="$(get_image machine-os-content)"
EOF

chmod +x 04-release-image/component-images.sh
```

Verify it worked:

```bash
source 04-release-image/component-images.sh
echo "etcd: ${ETCD_IMAGE}"
echo "apiserver: ${KUBE_APISERVER_IMAGE}"
```

Every later stage sources this file to get the right image for each component.

## Step 4: Examine CVO Manifests

The release image also contains all the YAML manifests that CVO applies to deploy operators. You can extract and browse them:

```bash
mkdir -p /tmp/release-extract
oc adm release extract --to=/tmp/release-extract ${OCP_RELEASE_IMAGE} \
    --registry-config="${PULL_SECRET_FILE}"

ls /tmp/release-extract/ | head -20
```

```
0000_00_cluster-version-operator_00_namespace.yaml
0000_00_cluster-version-operator_01_deployment.yaml
0000_03_config-operator_01_namespace.yaml
0000_03_config-operator_01_deployment.yaml
...
```

You don't need to modify these — CVO handles them. But it's worth knowing they're inside the release image, and this is what CVO reads when it deploys operators.

## Key Images We Use

Of the 100+ images in the release, we directly reference these in our manifests:

| Image Tag | Purpose |
|-----------|---------|
| `etcd` | etcd static pod |
| `hyperkube` | API server, controller manager, scheduler static pods (all three binaries are in this image) |
| `kube-proxy` | kube-proxy static pod (bootstraps ClusterIP routing) |
| `pod` | Pause container (holds network namespace open for every pod) |
| `machine-config-operator` | MCO render (produces node OS configuration) |
| `cluster-version-operator` | CVO static pod (deploys all operators from the release image) |

The operator images (`cluster-etcd-operator`, `cluster-network-operator`, etc.) are referenced in CVO's manifests — CVO deploys them, not us.

## Understanding the CVO

CVO (Cluster Version Operator) is the one operator we deploy manually. It deploys everything else.

**At bootstrap**: CVO runs as a static pod on the bootstrap node. It must use the **release image** as its container image (not a separate CVO operator image) because the release image contains `/release-manifests/` — the directory of YAML files CVO reads.

**What it does**: CVO reads all manifests from `/release-manifests/` inside its container, sorts them by filename (which encodes dependency order), and applies them to the API server. This deploys all other operators — networking, ingress, monitoring, console, etc.

**After bootstrap**: One of the manifests CVO applies is its own Deployment. Once masters join and become schedulable nodes, the CVO Deployment runs on a master, and the bootstrap static pod is no longer needed.

**Ongoing**: CVO continuously reconciles — if someone deletes or modifies an operator manifest, CVO re-applies it. It also handles upgrades: update the `ClusterVersion` CR to point to a new release image, and CVO extracts the new manifests and rolls out the update.

## Verification

```bash
# Verify release image is accessible
oc adm release info ${OCP_RELEASE_IMAGE} -o json | jq '.digest'

# Verify component images extracted
source 04-release-image/component-images.sh
echo "etcd: ${ETCD_IMAGE}"
echo "API server: ${KUBE_APISERVER_IMAGE}"

# Verify images are pullable (with auth)
podman pull --authfile ~/pull-secret.json ${ETCD_IMAGE}
```

## What's Next

In [Stage 05](../05-pki/README.md), we generate all the certificates needed for the cluster.
