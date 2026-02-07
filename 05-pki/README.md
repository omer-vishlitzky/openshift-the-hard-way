# Stage 05: PKI (Public Key Infrastructure)

OpenShift uses extensive PKI for authentication and encryption. This stage explains every certificate and shows how to generate them.

## Why This Stage Exists

OpenShift uses **mutual TLS everywhere**. Every component authenticates to every other component using certificates:

- etcd members authenticate to each other
- API server authenticates to etcd
- kubelets authenticate to API server
- Users authenticate via client certificates
- API server uses a separate CA to proxy requests to extension APIs (like metrics-server)

**Why so many certificates?**

Defense in depth. If one certificate is compromised, the blast radius is limited:
- Compromised etcd peer cert? Can't access API server.
- Compromised kubelet cert? Can't modify etcd.
- Compromised admin cert? Time to rotate, but etcd is still secure.

**Why not use `kubeadm` style auto-generation?**

We generate manually to understand:
1. What each certificate is FOR
2. What SANs (Subject Alternative Names) it needs
3. How CAs chain together
4. Why certificate errors happen

When you debug a "certificate signed by unknown authority" error, you'll know exactly which CA should have signed it.

## Certificate Overview

OpenShift uses multiple Certificate Authorities (CAs) for different purposes:

```
                              ┌─────────────────┐
                              │   Root CA       │
                              │ (cluster trust) │
                              └────────┬────────┘
                                       │
          ┌────────────────────────────┼──────────────────────────┐
          │                            │                          │
          ▼                            ▼                          ▼
   ┌──────────────┐           ┌──────────────┐           ┌──────────────┐
   │   etcd CA    │           │ API Server   │           │  Kubelet CA  │
   │              │           │     CA       │           │              │
   └──────┬───────┘           └──────┬───────┘           └───────┬──────┘
          │                          │                           │
          ▼                          ▼                           ▼
   etcd peer certs            API server cert              kubelet certs
   etcd client certs          front-proxy cert             client certs
```

## Certificate Types

### 1. Root CA
- **Purpose**: Signs other CAs, establishes cluster trust
- **Validity**: 10 years (typically)
- **Files**: `root-ca.crt`, `root-ca.key`

### 2. etcd CA
- **Purpose**: Secures etcd cluster communication
- **Signs**:
  - etcd peer certificates (member-to-member)
  - etcd server certificates (client-to-server)
  - etcd client certificates (API server to etcd)
- **Files**: `etcd-ca.crt`, `etcd-ca.key`

### 3. Kubernetes API CA
- **Purpose**: Secures API server connections
- **Signs**:
  - API server serving certificate
  - Kubelet client certificates
  - Admin kubeconfig certificate
- **Files**: `kubernetes-ca.crt`, `kubernetes-ca.key`

### 4. Service Account Signing Key
- **Purpose**: Signs service account tokens
- **Type**: RSA key pair (not a CA)
- **Used by**: kube-controller-manager (signing), kube-apiserver (verification)
- **Files**: `service-account.key`, `service-account.pub`

### 5. Front Proxy CA
- **Purpose**: When the API server proxies requests to extension APIs (e.g., `kubectl top` goes to metrics-server), it authenticates itself using a cert signed by this CA
- **Signs**: Front proxy client certificate
- **Files**: `front-proxy-ca.crt`, `front-proxy-ca.key`

## Certificate Details

### etcd Certificates

| Certificate | Purpose | SANs |
|-------------|---------|------|
| etcd-peer-{0,1,2} | Member-to-member communication | etcd-{0,1,2}.cluster.local, IP |
| etcd-server | Client connections | localhost, etcd.cluster.local, IPs |
| etcd-client | API server → etcd | system:etcd-client |

### API Server Certificates

| Certificate | Purpose | SANs |
|-------------|---------|------|
| kube-apiserver | API server TLS | api.cluster.local, api-int.cluster.local, kubernetes, kubernetes.default, VIP, all master IPs |
| kube-apiserver-kubelet | API server → kubelet | system:kube-apiserver |
| admin | Admin user | system:admin |

### Kubelet Certificates

| Certificate | Purpose | CN |
|-------------|---------|-----|
| kubelet-bootstrap | Initial TLS bootstrap | system:bootstrappers |
| kubelet-{node} | Node certificate | system:node:{nodename} |

### Controller Manager Certificates

| Certificate | Purpose | CN |
|-------------|---------|-----|
| kube-controller-manager | KCM client auth | system:kube-controller-manager |

### Scheduler Certificates

| Certificate | Purpose | CN |
|-------------|---------|-----|
| kube-scheduler | Scheduler client auth | system:kube-scheduler |

## Generate Certificates

Every openssl command below follows the same pattern: generate a key, create a CSR (Certificate Signing Request), sign it with a CA. The only things that vary are the CN (Common Name), the CA that signs it, the usage type (server, client, or both), and the SANs (Subject Alternative Names).

```bash
source config/cluster-vars.sh
mkdir -p ${PKI_DIR}
cd ${PKI_DIR}
```

### Certificate Authorities

Root CA — the trust anchor. Everything chains back to this:

```bash
# Generate a 4096-bit RSA private key
openssl genrsa -out root-ca.key 4096

# Create a certificate directly (-x509 outputs a cert instead of a CSR).
# Since we're not passing -CA, this cert is signed by its own key (self-signed).
# That's what makes it a root — nothing above it.
openssl req -x509 -new -nodes \
  -key root-ca.key -sha256 -days 3650 \
  -out root-ca.crt -subj "/CN=root-ca"
```

The intermediate CAs are signed by the root. Each one scopes trust to a different domain — etcd certs can't be used for API server connections and vice versa.

Every non-root certificate follows a two-step process: create a CSR (Certificate Signing Request — contains your public key and identity), then have a CA sign it into a certificate.

```bash
for ca in etcd-ca kubernetes-ca front-proxy-ca; do
  openssl genrsa -out ${ca}.key 4096
  # Step 1: create a CSR — contains the public key and CN, but isn't a certificate yet
  openssl req -new -key ${ca}.key -out ${ca}.csr -subj "/CN=${ca}"
  # Step 2: root CA signs the CSR, producing a trusted certificate
  # CA:TRUE marks it as a CA (can sign other certs), pathlen:0 means it can't create sub-CAs
  openssl x509 -req -in ${ca}.csr \
    -CA root-ca.crt -CAkey root-ca.key -CAcreateserial \
    -out ${ca}.crt -days 3650 -sha256 \
    -extfile <(echo "basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign")
  rm ${ca}.csr
done
```

### Service Account Key Pair

Not a certificate — an RSA key pair. KCM uses the private key to sign ServiceAccount tokens, the API server uses the public key to verify them:

```bash
openssl genrsa -out service-account.key 4096
openssl rsa -in service-account.key -pubout -out service-account.pub
```

### etcd Certificates

etcd peer certificates — one per node. etcd members use these to authenticate to each other. Usage is `both` (serverAuth + clientAuth) because each member is both a server and a client to its peers:

```bash
openssl genrsa -out etcd-peer-bootstrap.key 4096
openssl req -new -key etcd-peer-bootstrap.key -out etcd-peer-bootstrap.csr \
  -subj "/CN=etcd-peer-bootstrap"
# SANs = all the hostnames/IPs this cert is valid for. If a client connects
# to an IP not in the SANs, TLS fails with "certificate is not valid for"
cat > etcd-peer-bootstrap.ext <<EOF
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = bootstrap.${CLUSTER_DOMAIN}
DNS.2 = localhost
IP.1 = ${BOOTSTRAP_IP}
IP.2 = 127.0.0.1
EOF
# Sign with the etcd CA (not root — etcd has its own trust domain)
openssl x509 -req -in etcd-peer-bootstrap.csr \
  -CA etcd-ca.crt -CAkey etcd-ca.key -CAcreateserial \
  -out etcd-peer-bootstrap.crt -days 365 -sha256 \
  -extfile etcd-peer-bootstrap.ext
rm etcd-peer-bootstrap.csr etcd-peer-bootstrap.ext
```

Master etcd peer certificates — repeat for each master:

```bash
for i in 0 1 2; do
  node_ip_var="MASTER${i}_IP"
  node_ip="${!node_ip_var}"

  openssl genrsa -out etcd-peer-master-${i}.key 4096
  openssl req -new -key etcd-peer-master-${i}.key -out etcd-peer-master-${i}.csr \
    -subj "/CN=etcd-peer-master-${i}"
  cat > etcd-peer-master-${i}.ext <<EOF
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = master-${i}.${CLUSTER_DOMAIN}
DNS.2 = etcd-${i}.${CLUSTER_DOMAIN}
DNS.3 = localhost
IP.1 = ${node_ip}
IP.2 = 127.0.0.1
EOF
  openssl x509 -req -in etcd-peer-master-${i}.csr \
    -CA etcd-ca.crt -CAkey etcd-ca.key -CAcreateserial \
    -out etcd-peer-master-${i}.crt -days 365 -sha256 \
    -extfile etcd-peer-master-${i}.ext
  rm etcd-peer-master-${i}.csr etcd-peer-master-${i}.ext
done
```

etcd server certificate — clients (like the API server) connect to etcd using this. SANs include all nodes that run etcd:

```bash
openssl genrsa -out etcd-server.key 4096
openssl req -new -key etcd-server.key -out etcd-server.csr \
  -subj "/CN=etcd-server"
cat > etcd-server.ext <<EOF
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = localhost
DNS.2 = etcd.${CLUSTER_DOMAIN}
IP.1 = ${BOOTSTRAP_IP}
IP.2 = ${MASTER0_IP}
IP.3 = ${MASTER1_IP}
IP.4 = ${MASTER2_IP}
IP.5 = 127.0.0.1
EOF
openssl x509 -req -in etcd-server.csr \
  -CA etcd-ca.crt -CAkey etcd-ca.key -CAcreateserial \
  -out etcd-server.crt -days 365 -sha256 \
  -extfile etcd-server.ext
rm etcd-server.csr etcd-server.ext
```

etcd client certificate — the API server presents this when connecting to etcd:

```bash
openssl genrsa -out etcd-client.key 4096
openssl req -new -key etcd-client.key -out etcd-client.csr \
  -subj "/CN=system:etcd-client"
# clientAuth only — this cert proves identity to etcd, it doesn't serve connections
openssl x509 -req -in etcd-client.csr \
  -CA etcd-ca.crt -CAkey etcd-ca.key -CAcreateserial \
  -out etcd-client.crt -days 365 -sha256 \
  -extfile <(echo "basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth")
rm etcd-client.csr
```

### API Server Certificates

API server serving certificate — this is what clients see when they connect to `https://api.ocp4.example.com:6443`. The SANs must include every name and IP the API server can be reached at, including `172.30.0.1` (the `kubernetes` Service ClusterIP):

```bash
openssl genrsa -out kube-apiserver.key 4096
openssl req -new -key kube-apiserver.key -out kube-apiserver.csr \
  -subj "/CN=kube-apiserver"
# SANs are critical here — every hostname and IP the API server can be reached at.
# Missing a SAN = "x509: certificate is valid for X, not Y" errors.
cat > kube-apiserver.ext <<EOF
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = kubernetes
DNS.2 = kubernetes.default
DNS.3 = kubernetes.default.svc
DNS.4 = kubernetes.default.svc.cluster.local
DNS.5 = api.${CLUSTER_DOMAIN}
DNS.6 = api-int.${CLUSTER_DOMAIN}
DNS.7 = localhost
IP.1 = ${API_VIP}
IP.2 = ${BOOTSTRAP_IP}
IP.3 = ${MASTER0_IP}
IP.4 = ${MASTER1_IP}
IP.5 = ${MASTER2_IP}
IP.6 = 127.0.0.1
IP.7 = 172.30.0.1
EOF
openssl x509 -req -in kube-apiserver.csr \
  -CA kubernetes-ca.crt -CAkey kubernetes-ca.key -CAcreateserial \
  -out kube-apiserver.crt -days 365 -sha256 \
  -extfile kube-apiserver.ext
rm kube-apiserver.csr kube-apiserver.ext
```

API server → kubelet client certificate. The API server presents this when connecting to kubelet (for `kubectl logs`, `kubectl exec`, etc.):

```bash
openssl genrsa -out kube-apiserver-kubelet-client.key 4096
openssl req -new -key kube-apiserver-kubelet-client.key -out kube-apiserver-kubelet-client.csr \
  -subj "/CN=system:kube-apiserver"
openssl x509 -req -in kube-apiserver-kubelet-client.csr \
  -CA kubernetes-ca.crt -CAkey kubernetes-ca.key -CAcreateserial \
  -out kube-apiserver-kubelet-client.crt -days 365 -sha256 \
  -extfile <(echo "basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth")
rm kube-apiserver-kubelet-client.csr
```

### Control Plane Client Certificates

KCM, scheduler, and admin all need client certificates to authenticate to the API server. The CN determines the identity — Kubernetes RBAC uses it for authorization:

```bash
# Controller manager — the CN (system:kube-controller-manager) is the RBAC identity.
# Kubernetes maps the CN from the client cert to a user for authorization.
openssl genrsa -out kube-controller-manager.key 4096
openssl req -new -key kube-controller-manager.key -out kube-controller-manager.csr \
  -subj "/CN=system:kube-controller-manager"
openssl x509 -req -in kube-controller-manager.csr \
  -CA kubernetes-ca.crt -CAkey kubernetes-ca.key -CAcreateserial \
  -out kube-controller-manager.crt -days 365 -sha256 \
  -extfile <(echo "basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth")
rm kube-controller-manager.csr

# Scheduler
openssl genrsa -out kube-scheduler.key 4096
openssl req -new -key kube-scheduler.key -out kube-scheduler.csr \
  -subj "/CN=system:kube-scheduler"
openssl x509 -req -in kube-scheduler.csr \
  -CA kubernetes-ca.crt -CAkey kubernetes-ca.key -CAcreateserial \
  -out kube-scheduler.crt -days 365 -sha256 \
  -extfile <(echo "basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth")
rm kube-scheduler.csr

# Admin — O=system:masters is a special group in Kubernetes RBAC
# that's bound to cluster-admin. The CN is the username, O is the group.
openssl genrsa -out admin.key 4096
openssl req -new -key admin.key -out admin.csr \
  -subj "/CN=system:admin/O=system:masters"
openssl x509 -req -in admin.csr \
  -CA kubernetes-ca.crt -CAkey kubernetes-ca.key -CAcreateserial \
  -out admin.crt -days 365 -sha256 \
  -extfile <(echo "basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth")
rm admin.csr
```

### Front Proxy Client Certificate

The API server uses this when proxying requests to extension APIs:

```bash
openssl genrsa -out front-proxy-client.key 4096
openssl req -new -key front-proxy-client.key -out front-proxy-client.csr \
  -subj "/CN=front-proxy-client"
openssl x509 -req -in front-proxy-client.csr \
  -CA front-proxy-ca.crt -CAkey front-proxy-ca.key -CAcreateserial \
  -out front-proxy-client.crt -days 365 -sha256 \
  -extfile <(echo "basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth")
rm front-proxy-client.csr
```

### Bootstrap Certificate

Kubelet uses this for its initial connection to the API server to request a real node certificate (via CSR):

```bash
openssl genrsa -out kubelet-bootstrap.key 4096
openssl req -new -key kubelet-bootstrap.key -out kubelet-bootstrap.csr \
  -subj "/CN=system:bootstrapper"
openssl x509 -req -in kubelet-bootstrap.csr \
  -CA kubernetes-ca.crt -CAkey kubernetes-ca.key -CAcreateserial \
  -out kubelet-bootstrap.crt -days 365 -sha256 \
  -extfile <(echo "basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth")
rm kubelet-bootstrap.csr
```

### Verify

Check that all certificates were generated and are signed by the correct CA:

```bash
ls ${PKI_DIR}/*.crt | wc -l

# Verify a cert is signed by its CA. Since intermediate CAs are signed by root,
# openssl needs the full chain (root + intermediate) to verify leaf certs.
openssl verify -CAfile <(cat ${PKI_DIR}/root-ca.crt ${PKI_DIR}/etcd-ca.crt) ${PKI_DIR}/etcd-server.crt
openssl verify -CAfile <(cat ${PKI_DIR}/root-ca.crt ${PKI_DIR}/kubernetes-ca.crt) ${PKI_DIR}/kube-apiserver.crt
```

## Important Notes

### Certificate Lifetimes
- CAs: 10 years (long-lived)
- Server/client certs: 1 year (rotated by operators after bootstrap)

### Operator Rotation
In a running cluster, operators rotate certificates automatically. We generate the initial set — operators take over after bootstrap.

## What's Next

In [Stage 06](../06-kubeconfigs/README.md), we create kubeconfig files using these certificates.
