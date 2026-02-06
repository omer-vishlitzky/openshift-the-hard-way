# Stage 03: Understanding the Installer

Before we build things manually, let's understand what `openshift-install` produces. This gives us a reference for what we need to create.

## What the Installer Does

The `openshift-install` command:
1. Takes your `install-config.yaml`
2. Generates manifests, certificates, and ignition configs
3. Produces three Ignition files: `bootstrap.ign`, `master.ign`, `worker.ign`

We'll dissect each step.

## Step 1: Generate Reference Assets

Create a reference directory and generate assets:

```bash
mkdir -p /tmp/ocp-reference && cd /tmp/ocp-reference

# Create install-config.yaml
cat > install-config.yaml <<'EOF'
apiVersion: v1
baseDomain: example.com
metadata:
  name: ocp4
compute:
- name: worker
  replicas: 2
controlPlane:
  name: master
  replicas: 3
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 192.168.126.0/24
  serviceNetwork:
  - 172.30.0.0/16
platform:
  none: {}
pullSecret: '<your-pull-secret>'
sshKey: '<your-ssh-key>'
EOF

# Save a copy (install-config.yaml gets consumed)
cp install-config.yaml install-config.yaml.bak

# Generate manifests (doesn't consume install-config)
openshift-install create manifests --dir=.

# Look at what was generated
find . -type f | head -50
```

## Step 2: Examine Manifests

The `manifests/` directory contains Kubernetes resources that will be applied to the cluster:

```
manifests/
├── cluster-config.yaml              # Cluster config (scheduler, etc)
├── cluster-dns-02-config.yml        # DNS operator config
├── cluster-infrastructure-02-config.yml
├── cluster-ingress-02-config.yml
├── cluster-network-01-crd.yml       # Network CRD
├── cluster-network-02-config.yml    # Network operator config
├── cluster-proxy-01-config.yaml
├── cluster-scheduler-02-config.yml
├── cvo-overrides.yaml               # ClusterVersionOperator config
└── ... (many more)
```

Key files to understand:
- `cluster-config.yaml`: Sets cluster identity
- `cvo-overrides.yaml`: Tells CVO what to deploy
- `cluster-network-02-config.yml`: Network plugin configuration

The `openshift/` directory contains OpenShift-specific resources:
```
openshift/
├── 99_kubeadmin-password-secret.yaml
├── 99_openshift-cluster-api_master-machines-*.yaml
├── 99_openshift-cluster-api_master-user-data-secret.yaml
├── 99_openshift-cluster-api_worker-machineset-*.yaml
├── 99_openshift-machineconfig_99-*.yaml
├── 99_role-cloud-creds-secret-reader.yaml
└── ...
```

## Step 3: Generate Ignition Configs

Now generate the Ignition files:

```bash
# Generate ignition (consumes install-config.yaml)
cp install-config.yaml.bak install-config.yaml
openshift-install create ignition-configs --dir=.

ls -la *.ign
```

Output:
```
-rw-r-----. 1 user user 292339 Feb  1 12:00 bootstrap.ign
-rw-r-----. 1 user user   1720 Feb  1 12:00 master.ign
-rw-r-----. 1 user user   1720 Feb  1 12:00 worker.ign
```

Notice the sizes:
- `bootstrap.ign`: ~280KB - contains everything needed to bootstrap
- `master.ign`: ~1.7KB - contains a pointer to fetch config from MCS
- `worker.ign`: ~1.7KB - contains a pointer to fetch config from MCS

## Step 4: Dissect bootstrap.ign

The bootstrap Ignition is huge because it contains:
- All certificates
- All kubeconfigs
- All static pod manifests
- bootkube.sh and related scripts
- The entire release payload reference

Let's examine its structure:

```bash
# Pretty-print the structure
jq 'keys' bootstrap.ign
```

Output:
```json
[
  "ignition",
  "passwd",
  "storage",
  "systemd"
]
```

### Ignition Section

```bash
jq '.ignition' bootstrap.ign
```

Contains version and config source information.

### Passwd Section

```bash
jq '.passwd' bootstrap.ign
```

Contains SSH authorized keys for the `core` user.

### Storage Section

This is the bulk of the file. Contains all files to be written to disk:

```bash
# Count files
jq '.storage.files | length' bootstrap.ign
# ~150+ files

# List file paths
jq -r '.storage.files[].path' bootstrap.ign | head -30
```

Key files:
```
/etc/kubernetes/manifests/etcd-pod.yaml
/etc/kubernetes/manifests/kube-apiserver-pod.yaml
/etc/kubernetes/manifests/kube-controller-manager-pod.yaml
/etc/kubernetes/manifests/kube-scheduler-pod.yaml
/opt/openshift/bootkube.sh
/opt/openshift/manifests/*.yaml
/etc/kubernetes/bootstrap-secrets/*.pem
...
```

### Systemd Section

```bash
jq '.systemd' bootstrap.ign
```

Contains systemd units to enable/start:
- `kubelet.service`
- `bootkube.service`
- `approve-csr.service`
- Various other services

## Step 5: Understanding bootkube.sh

The heart of bootstrap is `bootkube.sh`. Extract it:

```bash
jq -r '.storage.files[] | select(.path == "/opt/openshift/bootkube.sh") | .contents.source' bootstrap.ign | \
  sed 's/data:,//' | python3 -c "import sys, urllib.parse; print(urllib.parse.unquote(sys.stdin.read()))" > bootkube.sh
```

This ~656 line script orchestrates the entire bootstrap. See [dissect-bootkube.md](dissect-bootkube.md) for a complete breakdown.

## Step 6: Examine master.ign and worker.ign

These are tiny because they just point to the Machine Config Server:

```bash
jq '.' master.ign
```

```json
{
  "ignition": {
    "version": "3.2.0",
    "config": {
      "merge": [
        {
          "source": "https://api-int.ocp4.example.com:22623/config/master"
        }
      ]
    },
    "security": {
      "tls": {
        "certificateAuthorities": [
          {
            "source": "data:text/plain;charset=utf-8;base64,..."
          }
        ]
      }
    }
  }
}
```

The master fetches its real config from `https://api-int.<cluster>:22623/config/master`.

The MCS (Machine Config Server) runs on:
1. Bootstrap (during bootstrap phase)
2. Masters (after bootstrap completes)

## Step 7: Examine auth/

```bash
ls -la auth/
```

```
-rw-------. 1 user user 23 Feb  1 12:00 kubeadmin-password
-rw-------. 1 user user 8462 Feb  1 12:00 kubeconfig
```

- `kubeadmin-password`: Generated admin password
- `kubeconfig`: Admin kubeconfig with cluster CA and client cert

## What We Need to Create Manually

Based on this analysis, to install OpenShift manually we need:

### Certificates (Stage 05)
- Root CA
- etcd CA and certs
- API server CA and certs
- Kubelet certs
- Service account signing key

### Kubeconfigs (Stage 06)
- admin.kubeconfig
- kubelet bootstrap kubeconfig
- controller-manager kubeconfig
- scheduler kubeconfig

### Static Pod Manifests (Stage 07)
- etcd-pod.yaml
- kube-apiserver-pod.yaml
- kube-controller-manager-pod.yaml
- kube-scheduler-pod.yaml

### Bootstrap Scripts (Stage 08)
- bootkube.sh equivalent
- Various helper scripts

### Manifests (Stage 08)
- All cluster manifests
- CVO manifests
- MCO manifests

## Verification

```bash
# List all certificate files in bootstrap.ign
jq -r '.storage.files[].path' bootstrap.ign | grep -E '\.(pem|crt|key)$'

# List all manifest files
jq -r '.storage.files[].path' bootstrap.ign | grep '\.yaml$' | head -20

# List all systemd units
jq -r '.systemd.units[].name' bootstrap.ign
```

## What's Next

In [Stage 04](../04-release-image/README.md), we examine the release image to understand what container images are used and how operators render manifests.
