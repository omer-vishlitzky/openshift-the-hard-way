# Manual Commands (No Wrapper Scripts)

This file provides the explicit commands that the scripts in this stage execute. Use it if you want a fully manual, step-by-step flow without running the helper scripts.

## 0. Load variables

```bash
source stages/16-manual-install-runbook/config/cluster-vars.sh
```

## 1. PKI (OpenSSL)

```bash
OUT_DIR=stages/16-manual-install-runbook/generated/pki
ETCD_DIR=${OUT_DIR}/etcd
mkdir -p "$OUT_DIR" "$ETCD_DIR"

# Cluster CA
openssl genrsa -out "${OUT_DIR}/ca.key" 4096
openssl req -x509 -new -nodes -key "${OUT_DIR}/ca.key" -subj "/CN=kubernetes" -days 3650 -out "${OUT_DIR}/ca.crt"

# Front-proxy CA
openssl genrsa -out "${OUT_DIR}/front-proxy-ca.key" 4096
openssl req -x509 -new -nodes -key "${OUT_DIR}/front-proxy-ca.key" -subj "/CN=kubernetes-front-proxy" -days 3650 -out "${OUT_DIR}/front-proxy-ca.crt"

# etcd CA
openssl genrsa -out "${ETCD_DIR}/ca.key" 4096
openssl req -x509 -new -nodes -key "${ETCD_DIR}/ca.key" -subj "/CN=etcd-ca" -days 3650 -out "${ETCD_DIR}/ca.crt"

# Service account signing key
openssl genrsa -out "${OUT_DIR}/sa.key" 2048
openssl rsa -in "${OUT_DIR}/sa.key" -pubout -out "${OUT_DIR}/sa.pub"
```

### API server certs

```bash
APISERVER_SAN="DNS:api.${CLUSTER_DOMAIN},DNS:api-int.${CLUSTER_DOMAIN},DNS:kubernetes,DNS:kubernetes.default,DNS:kubernetes.default.svc,DNS:kubernetes.default.svc.cluster.local,IP:${API_VIP},IP:${KUBERNETES_SERVICE_IP},IP:127.0.0.1"

openssl genrsa -out "${OUT_DIR}/apiserver.key" 2048
openssl req -new -key "${OUT_DIR}/apiserver.key" -subj "/CN=kube-apiserver/O=kubernetes" -out "${OUT_DIR}/apiserver.csr"
cat > /tmp/apiserver.ext <<EOFEXT
[ v3_req ]
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = ${APISERVER_SAN}
EOFEXT
openssl x509 -req -in "${OUT_DIR}/apiserver.csr" -CA "${OUT_DIR}/ca.crt" -CAkey "${OUT_DIR}/ca.key" -CAcreateserial -out "${OUT_DIR}/apiserver.crt" -days 3650 -extensions v3_req -extfile /tmp/apiserver.ext
rm -f /tmp/apiserver.ext "${OUT_DIR}/apiserver.csr"

openssl genrsa -out "${OUT_DIR}/apiserver-kubelet-client.key" 2048
openssl req -new -key "${OUT_DIR}/apiserver-kubelet-client.key" -subj "/CN=kube-apiserver-kubelet-client/O=system:masters" -out "${OUT_DIR}/apiserver-kubelet-client.csr"
cat > /tmp/apiserver-kubelet.ext <<EOFEXT
[ v3_req ]
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = DNS:kube-apiserver
EOFEXT
openssl x509 -req -in "${OUT_DIR}/apiserver-kubelet-client.csr" -CA "${OUT_DIR}/ca.crt" -CAkey "${OUT_DIR}/ca.key" -CAcreateserial -out "${OUT_DIR}/apiserver-kubelet-client.crt" -days 3650 -extensions v3_req -extfile /tmp/apiserver-kubelet.ext
rm -f /tmp/apiserver-kubelet.ext "${OUT_DIR}/apiserver-kubelet-client.csr"
```

### Front proxy client

```bash
openssl genrsa -out "${OUT_DIR}/front-proxy-client.key" 2048
openssl req -new -key "${OUT_DIR}/front-proxy-client.key" -subj "/CN=front-proxy-client/O=kubernetes" -out "${OUT_DIR}/front-proxy-client.csr"
cat > /tmp/front-proxy.ext <<EOFEXT
[ v3_req ]
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = DNS:front-proxy-client
EOFEXT
openssl x509 -req -in "${OUT_DIR}/front-proxy-client.csr" -CA "${OUT_DIR}/front-proxy-ca.crt" -CAkey "${OUT_DIR}/front-proxy-ca.key" -CAcreateserial -out "${OUT_DIR}/front-proxy-client.crt" -days 3650 -extensions v3_req -extfile /tmp/front-proxy.ext
rm -f /tmp/front-proxy.ext "${OUT_DIR}/front-proxy-client.csr"
```

### Admin, controller-manager, scheduler certs

```bash
for pair in \
  "admin system:admin system:masters" \
  "kube-controller-manager system:kube-controller-manager system:kube-controller-manager" \
  "kube-scheduler system:kube-scheduler system:kube-scheduler"; do
  set -- $pair
  name=$1 cn=$2 org=$3
  openssl genrsa -out "${OUT_DIR}/${name}.key" 2048
  openssl req -new -key "${OUT_DIR}/${name}.key" -subj "/CN=${cn}/O=${org}" -out "${OUT_DIR}/${name}.csr"
  cat > /tmp/${name}.ext <<EOFEXT
[ v3_req ]
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = DNS:${name}
EOFEXT
  openssl x509 -req -in "${OUT_DIR}/${name}.csr" -CA "${OUT_DIR}/ca.crt" -CAkey "${OUT_DIR}/ca.key" -CAcreateserial -out "${OUT_DIR}/${name}.crt" -days 3650 -extensions v3_req -extfile /tmp/${name}.ext
  rm -f /tmp/${name}.ext "${OUT_DIR}/${name}.csr"
done
```

### Kubelet client certs

```bash
for node in bootstrap master0 master1 master2 worker0 worker1; do
  openssl genrsa -out "${OUT_DIR}/kubelet-${node}.key" 2048
  openssl req -new -key "${OUT_DIR}/kubelet-${node}.key" -subj "/CN=system:node:${node}.${CLUSTER_DOMAIN}/O=system:nodes" -out "${OUT_DIR}/kubelet-${node}.csr"
  cat > /tmp/kubelet-${node}.ext <<EOFEXT
[ v3_req ]
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = DNS:${node}.${CLUSTER_DOMAIN}
EOFEXT
  openssl x509 -req -in "${OUT_DIR}/kubelet-${node}.csr" -CA "${OUT_DIR}/ca.crt" -CAkey "${OUT_DIR}/ca.key" -CAcreateserial -out "${OUT_DIR}/kubelet-${node}.crt" -days 3650 -extensions v3_req -extfile /tmp/kubelet-${node}.ext
  rm -f /tmp/kubelet-${node}.ext "${OUT_DIR}/kubelet-${node}.csr"
done
```

### etcd certs

```bash
for node in bootstrap master0 master1 master2; do
  node_fqdn=${node}.${CLUSTER_DOMAIN}
  node_ip_var=$(echo ${node} | tr '[:lower:]' '[:upper:]')_IP
  node_ip=${!node_ip_var}
  san="DNS:${node_fqdn},IP:${node_ip},IP:127.0.0.1"

  for role in server peer client; do
    openssl genrsa -out "${ETCD_DIR}/${node}-${role}.key" 2048
    openssl req -new -key "${ETCD_DIR}/${node}-${role}.key" -subj "/CN=etcd-${role}/O=etcd" -out "${ETCD_DIR}/${node}-${role}.csr"
    cat > /tmp/${node}-${role}.ext <<EOFEXT
[ v3_req ]
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = ${san}
EOFEXT
    openssl x509 -req -in "${ETCD_DIR}/${node}-${role}.csr" -CA "${ETCD_DIR}/ca.crt" -CAkey "${ETCD_DIR}/ca.key" -CAcreateserial -out "${ETCD_DIR}/${node}-${role}.crt" -days 3650 -extensions v3_req -extfile /tmp/${node}-${role}.ext
    rm -f /tmp/${node}-${role}.ext "${ETCD_DIR}/${node}-${role}.csr"
  done
done

# API server etcd client cert
openssl genrsa -out "${ETCD_DIR}/apiserver-etcd-client.key" 2048
openssl req -new -key "${ETCD_DIR}/apiserver-etcd-client.key" -subj "/CN=kube-apiserver/O=kubernetes" -out "${ETCD_DIR}/apiserver-etcd-client.csr"
cat > /tmp/apiserver-etcd-client.ext <<EOFEXT
[ v3_req ]
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = DNS:apiserver-etcd-client
EOFEXT
openssl x509 -req -in "${ETCD_DIR}/apiserver-etcd-client.csr" -CA "${ETCD_DIR}/ca.crt" -CAkey "${ETCD_DIR}/ca.key" -CAcreateserial -out "${ETCD_DIR}/apiserver-etcd-client.crt" -days 3650 -extensions v3_req -extfile /tmp/apiserver-etcd-client.ext
rm -f /tmp/apiserver-etcd-client.ext "${ETCD_DIR}/apiserver-etcd-client.csr"
```

## 2. Kubeconfigs

The helper script creates kubeconfigs with embedded certs. You can use it or recreate with your own kubeconfig template.

```bash
stages/16-manual-install-runbook/scripts/20-gen-kubeconfigs.sh
```

## 3. Image references and manifests

```bash
stages/16-manual-install-runbook/scripts/05-resolve-release.sh
export PULL_SECRET=/path/to/pull-secret.json
stages/16-manual-install-runbook/scripts/25-get-image-refs.sh
stages/16-manual-install-runbook/scripts/30-render-manifests.sh
```

## 4. Ignition

```bash
stages/16-manual-install-runbook/scripts/40-gen-ignition.sh
```

## 5. Cluster config resources and CVO bootstrap

```bash
stages/16-manual-install-runbook/scripts/45-gen-cluster-configs.sh
stages/16-manual-install-runbook/scripts/35-extract-release-manifests.sh
oc apply -f stages/16-manual-install-runbook/generated/cluster-config/
oc apply -f stages/16-manual-install-runbook/generated/release-manifests/0000_00_cluster-version-operator_*.yaml
oc apply -f stages/16-manual-install-runbook/generated/cluster-config/clusterversion.yaml
```
