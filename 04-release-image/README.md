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
  (300+ images)
```

## Step 3: Extract Component Images

We need specific component images for rendering manifests. Extract them:

```bash
./extract.sh
```

This creates `component-images.sh` with:
```bash
export ETCD_IMAGE="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:..."
export KUBE_APISERVER_OPERATOR_IMAGE="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:..."
export MACHINE_CONFIG_OPERATOR_IMAGE="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:..."
# ... all component images
```

## Step 4: Examine Release Contents

The release image contains:

### 1. Image References

```bash
oc adm release info ${OCP_RELEASE_IMAGE} --output=json | jq '.references.spec.tags'
```

Each tag maps a component name to its image digest.

### 2. Manifests

```bash
# Extract the release payload
mkdir -p /tmp/release-extract
oc adm release extract --to=/tmp/release-extract ${OCP_RELEASE_IMAGE}

ls /tmp/release-extract/
```

Contents:
```
0000_00_cluster-version-operator_00_namespace.yaml
0000_00_cluster-version-operator_01_deployment.yaml
0000_03_config-operator_01_namespace.yaml
0000_03_config-operator_01_deployment.yaml
...
image-references
release-metadata
```

These manifests are what CVO applies to create the cluster.

### 3. Image References File

```bash
cat /tmp/release-extract/image-references
```

This YAML file maps component names to images:
```yaml
kind: ImageStream
apiVersion: image.openshift.io/v1
metadata:
  name: "4.14.0"
spec:
  tags:
  - name: aws-cloud-controller-manager
    from:
      kind: DockerImage
      name: quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:...
  - name: etcd
    from:
      kind: DockerImage
      name: quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:...
  # ... all components
```

## Step 5: Key Component Images

For manual installation, we need these images:

| Component | Purpose |
|-----------|---------|
| `etcd` | etcd database |
| `kube-apiserver` | API server |
| `kube-controller-manager` | Controller manager |
| `kube-scheduler` | Scheduler |
| `cluster-kube-apiserver-operator` | Renders API server config |
| `cluster-kube-controller-manager-operator` | Renders KCM config |
| `cluster-kube-scheduler-operator` | Renders scheduler config |
| `cluster-etcd-operator` | Renders etcd config |
| `machine-config-operator` | Renders MachineConfigs |
| `cluster-version-operator` | Orchestrates operators |
| `cluster-bootstrap` | Bootstrap orchestration |
| `machine-config-server` | Serves Ignition to nodes |
| `haproxy-router` | Ingress router |

## Step 6: Pull Required Images

For offline use, pull the images we'll need:

```bash
./pull-images.sh
```

This pulls:
- Operator images (for rendering)
- Control plane images (for static pods)
- Bootstrap images

## Understanding the CVO

The Cluster Version Operator (CVO) is special:

1. **At bootstrap**: CVO manifests are applied manually
2. **After bootstrap**: CVO runs as a Deployment
3. **Ongoing**: CVO ensures all operators match the release

CVO reads the release image and:
1. Extracts all manifests
2. Applies them in order (respecting dependencies)
3. Monitors for drift
4. Handles upgrades

## Manifest Ordering

Manifests in the release payload are ordered by filename:
```
0000_00_cluster-version-operator_00_namespace.yaml
0000_00_cluster-version-operator_01_deployment.yaml
0000_03_config-operator_01_namespace.yaml
```

Format: `NNNN_MM_component_NN_resource.yaml`
- `NNNN`: Run level (lower runs first)
- `MM`: Sub-ordering
- `component`: Component name
- `NN`: Resource order within component
- `resource`: Resource type

Run levels:
- `0000`: CVO itself and core resources
- `0001-0009`: Critical infrastructure (networking, storage)
- `0010-0099`: Core operators
- `0100+`: Optional operators

## Verification

```bash
# Verify release image is accessible
oc adm release info ${OCP_RELEASE_IMAGE} -o json | jq '.digest'

# Verify component images extracted
source component-images.sh
echo "etcd: ${ETCD_IMAGE}"
echo "API server: ${KUBE_APISERVER_IMAGE}"

# Verify images are pullable (with auth)
podman pull --authfile ~/pull-secret.json ${ETCD_IMAGE}
```

## What's Next

In [Stage 05](../05-pki/README.md), we generate all the certificates needed for the cluster.
