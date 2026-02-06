# Disconnected (Air-Gapped) Installation

This appendix covers installing OpenShift in environments without internet access.

## Overview

Disconnected installation requires:
1. Mirror registry with all images
2. Modified install-config with mirror info
3. Additional CA certificates (if using self-signed)
4. Catalog mirroring for OperatorHub

## Prerequisites

### Mirror Registry

Set up a container registry accessible from the cluster:

```bash
# Example: Deploy mirror registry
podman run -d \
  -p 5000:5000 \
  -v /opt/registry/data:/var/lib/registry:z \
  --name mirror-registry \
  docker.io/library/registry:2
```

### Download Tools

On a connected machine:
```bash
# oc-mirror plugin
curl -L https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/oc-mirror.tar.gz | tar -xz
sudo mv oc-mirror /usr/local/bin/

# Verify
oc-mirror version
```

## Step 1: Mirror Release Image

### Create ImageSetConfiguration

```yaml
# imageset-config.yaml
apiVersion: mirror.openshift.io/v1alpha2
kind: ImageSetConfiguration
storageConfig:
  local:
    path: /opt/mirror-data
mirror:
  platform:
    channels:
    - name: stable-4.14
      minVersion: 4.14.0
      maxVersion: 4.14.0
```

### Run oc-mirror

```bash
oc-mirror --config imageset-config.yaml \
  docker://mirror.example.com:5000/ocp4
```

This downloads:
- Release images
- Operator images from release
- ~20-50GB of data

## Step 2: Mirror Operators (Optional)

For OperatorHub:

```yaml
# Add to imageset-config.yaml
mirror:
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.14
    packages:
    - name: elasticsearch-operator
    - name: cluster-logging
```

## Step 3: Transfer to Air-Gap

If truly air-gapped:

1. Mirror to local disk: `oc-mirror --config ... file:///path/to/archive`
2. Transfer archive to air-gapped network
3. Load into air-gap registry: `oc-mirror --from /path/to/archive docker://mirror.internal:5000`

## Step 4: Configure Installation

### ImageContentSourcePolicy

oc-mirror generates ICSP yaml:

```yaml
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: ocp4-mirror
spec:
  repositoryDigestMirrors:
  - mirrors:
    - mirror.example.com:5000/ocp4/openshift-release-dev
    source: quay.io/openshift-release-dev
  - mirrors:
    - mirror.example.com:5000/ocp4/openshift-release-dev
    source: registry.redhat.io/openshift-release-dev
```

### install-config.yaml

```yaml
apiVersion: v1
baseDomain: example.com
metadata:
  name: ocp4
# ... other config ...

# Add mirror registry CA
additionalTrustBundle: |
  -----BEGIN CERTIFICATE-----
  MIIDxTCCA...
  -----END CERTIFICATE-----

# Add image content sources
imageContentSources:
- mirrors:
  - mirror.example.com:5000/ocp4/openshift-release-dev
  source: quay.io/openshift-release-dev
- mirrors:
  - mirror.example.com:5000/ocp4/openshift-release-dev
  source: registry.redhat.io/openshift-release-dev

# Modified pull secret (includes mirror registry auth)
pullSecret: '<merged pull secret with mirror auth>'
```

### Merge Pull Secret

```bash
# Original pull secret
cat ~/pull-secret.json

# Add mirror registry auth
cat <<EOF > mirror-auth.json
{
  "auths": {
    "mirror.example.com:5000": {
      "auth": "$(echo -n 'user:password' | base64)"
    }
  }
}
EOF

# Merge
jq -s '.[0] * .[1]' ~/pull-secret.json mirror-auth.json > merged-pull-secret.json
```

## Step 5: Modify Component Images

Update `config/cluster-vars.sh`:

```bash
export OCP_RELEASE_IMAGE="mirror.example.com:5000/ocp4/openshift-release-dev/ocp-release:4.14.0-x86_64"
```

When extracting component images, they'll point to the mirror.

## Step 6: Build Ignition

Build ignition as normal, but:
- Pull secret includes mirror auth
- Certificate bundle includes mirror CA
- Release image points to mirror

## Step 7: Serve RHCOS

Mirror RHCOS images to local web server:

```bash
# Download RHCOS
curl -O https://mirror.openshift.com/pub/.../rhcos-live.x86_64.iso
curl -O https://mirror.openshift.com/pub/.../rhcos-metal.x86_64.raw.gz

# Serve locally
python3 -m http.server 8080
```

## Verification

### Check mirroring

```bash
# List mirrored images
curl -s https://mirror.example.com:5000/v2/_catalog | jq

# Check specific image
skopeo inspect docker://mirror.example.com:5000/ocp4/openshift-release-dev/ocp-release:4.14.0-x86_64
```

### Check cluster uses mirror

After installation:

```bash
# Check ICSP
oc get imagecontentsourcepolicy

# Check image pulls
oc get pods -A -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' | sort -u | head
```

## Common Issues

### Certificate errors

```bash
# Add CA to nodes via MachineConfig
# Or use --insecure on registry
```

### Image not found

```bash
# Verify image exists in mirror
skopeo inspect docker://mirror.example.com:5000/path/to/image:tag
```

### Pull secret not working

```bash
# Test auth
podman login mirror.example.com:5000
```

## Storage Requirements

| Component | Size |
|-----------|------|
| Release images | 10-15 GB |
| Operators (full catalog) | 50-100 GB |
| RHCOS images | 2-3 GB |
| Buffer | 20% |

Plan for 100-200 GB for mirror storage.

## Future Addition

A complete disconnected walkthrough may be added as a separate track.
