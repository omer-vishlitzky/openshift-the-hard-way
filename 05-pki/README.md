# Stage 05: PKI (Public Key Infrastructure)

OpenShift uses extensive PKI for authentication and encryption. This stage explains every certificate and shows how to generate them.

## Certificate Overview

OpenShift uses multiple Certificate Authorities (CAs) for different purposes:

```
                              ┌─────────────────┐
                              │   Root CA       │
                              │ (cluster trust) │
                              └────────┬────────┘
                                       │
          ┌────────────────────────────┼────────────────────────────┐
          │                            │                            │
          ▼                            ▼                            ▼
   ┌──────────────┐           ┌──────────────┐           ┌──────────────┐
   │   etcd CA    │           │ API Server   │           │  Kubelet CA  │
   │              │           │     CA       │           │              │
   └──────┬───────┘           └──────┬───────┘           └──────┬──────┘
          │                          │                          │
          ▼                          ▼                          ▼
   etcd peer certs            API server cert            kubelet certs
   etcd client certs          aggregator cert            client certs
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
- **Purpose**: Aggregation layer authentication
- **Signs**: Aggregator client certificate
- **Used for**: API extension servers, metrics server
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

## Generate All Certificates

```bash
./generate.sh
```

This creates all certificates in `${ASSETS_DIR}/pki/`.

## Manual Generation (Educational)

### Step 1: Create Root CA

```bash
mkdir -p ${PKI_DIR}
cd ${PKI_DIR}

# Generate root CA key
openssl genrsa -out root-ca.key 4096

# Generate root CA certificate
openssl req -x509 -new -nodes \
  -key root-ca.key \
  -sha256 \
  -days 3650 \
  -out root-ca.crt \
  -subj "/CN=root-ca"
```

### Step 2: Create etcd CA

```bash
# Generate etcd CA key
openssl genrsa -out etcd-ca.key 4096

# Create CSR
openssl req -new \
  -key etcd-ca.key \
  -out etcd-ca.csr \
  -subj "/CN=etcd-ca"

# Sign with root CA
openssl x509 -req \
  -in etcd-ca.csr \
  -CA root-ca.crt \
  -CAkey root-ca.key \
  -CAcreateserial \
  -out etcd-ca.crt \
  -days 3650 \
  -sha256 \
  -extfile <(echo "basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign")
```

### Step 3: Create etcd Peer Certificates

For each master (0, 1, 2):

```bash
NODE_NAME="master-0"
NODE_IP="192.168.126.101"

# Generate key
openssl genrsa -out etcd-peer-${NODE_NAME}.key 4096

# Create CSR
openssl req -new \
  -key etcd-peer-${NODE_NAME}.key \
  -out etcd-peer-${NODE_NAME}.csr \
  -subj "/CN=etcd-peer-${NODE_NAME}"

# Create extension file for SANs
cat > etcd-peer-${NODE_NAME}.ext <<EOF
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${NODE_NAME}.${CLUSTER_DOMAIN}
DNS.2 = etcd-0.${CLUSTER_DOMAIN}
DNS.3 = localhost
IP.1 = ${NODE_IP}
IP.2 = 127.0.0.1
EOF

# Sign with etcd CA
openssl x509 -req \
  -in etcd-peer-${NODE_NAME}.csr \
  -CA etcd-ca.crt \
  -CAkey etcd-ca.key \
  -CAcreateserial \
  -out etcd-peer-${NODE_NAME}.crt \
  -days 365 \
  -sha256 \
  -extfile etcd-peer-${NODE_NAME}.ext
```

### Step 4: Create API Server Certificate

```bash
# Generate key
openssl genrsa -out kube-apiserver.key 4096

# Create CSR
openssl req -new \
  -key kube-apiserver.key \
  -out kube-apiserver.csr \
  -subj "/CN=kube-apiserver"

# Create extension file
cat > kube-apiserver.ext <<EOF
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = kubernetes
DNS.2 = kubernetes.default
DNS.3 = kubernetes.default.svc
DNS.4 = kubernetes.default.svc.cluster.local
DNS.5 = api.${CLUSTER_DOMAIN}
DNS.6 = api-int.${CLUSTER_DOMAIN}
IP.1 = ${API_VIP}
IP.2 = ${MASTER0_IP}
IP.3 = ${MASTER1_IP}
IP.4 = ${MASTER2_IP}
IP.5 = 127.0.0.1
IP.6 = 172.30.0.1
EOF

# Sign
openssl x509 -req \
  -in kube-apiserver.csr \
  -CA kubernetes-ca.crt \
  -CAkey kubernetes-ca.key \
  -CAcreateserial \
  -out kube-apiserver.crt \
  -days 365 \
  -sha256 \
  -extfile kube-apiserver.ext
```

### Step 5: Create Service Account Key

```bash
# Generate RSA key pair
openssl genrsa -out service-account.key 4096

# Extract public key
openssl rsa -in service-account.key -pubout -out service-account.pub
```

### Step 6: Create Admin Certificate

```bash
# Generate key
openssl genrsa -out admin.key 4096

# Create CSR
openssl req -new \
  -key admin.key \
  -out admin.csr \
  -subj "/CN=system:admin/O=system:masters"

# Sign
openssl x509 -req \
  -in admin.csr \
  -CA kubernetes-ca.crt \
  -CAkey kubernetes-ca.key \
  -CAcreateserial \
  -out admin.crt \
  -days 365 \
  -sha256 \
  -extfile <(echo "basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth")
```

## Certificate Tree

After generation:
```
${PKI_DIR}/
├── root-ca.crt
├── root-ca.key
├── etcd-ca.crt
├── etcd-ca.key
├── etcd-peer-master-0.crt
├── etcd-peer-master-0.key
├── etcd-peer-master-1.crt
├── etcd-peer-master-1.key
├── etcd-peer-master-2.crt
├── etcd-peer-master-2.key
├── etcd-server.crt
├── etcd-server.key
├── etcd-client.crt
├── etcd-client.key
├── kubernetes-ca.crt
├── kubernetes-ca.key
├── kube-apiserver.crt
├── kube-apiserver.key
├── kube-apiserver-kubelet-client.crt
├── kube-apiserver-kubelet-client.key
├── front-proxy-ca.crt
├── front-proxy-ca.key
├── front-proxy-client.crt
├── front-proxy-client.key
├── service-account.key
├── service-account.pub
├── admin.crt
├── admin.key
├── kube-controller-manager.crt
├── kube-controller-manager.key
├── kube-scheduler.crt
└── kube-scheduler.key
```

## Verification

```bash
./verify.sh
```

Checks:
- All certificates exist
- Certificates are signed by correct CA
- SANs are correct
- Certificates are not expired

## Important Notes

### Certificate Lifetimes
- CAs: 10 years (long-lived)
- Server/client certs: 1 year (rotated by operators)

### Operator Rotation
In a running cluster, operators rotate certificates:
- `cluster-kube-apiserver-operator` rotates API server certs
- `cluster-etcd-operator` rotates etcd certs
- `machine-config-operator` rotates kubelet certs

For manual installation, we generate initial certs. Operators take over after bootstrap.

### Security
- Keep CA keys secure
- Never commit keys to git
- In production, use HSM for CA keys

## What's Next

In [Stage 06](../06-kubeconfigs/README.md), we create kubeconfig files using these certificates.
