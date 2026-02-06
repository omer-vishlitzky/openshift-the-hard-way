# Manual vs Operator-Rendered Manifests

This document compares what you'd write manually vs what the operator produces.

## Why the Difference Matters

A minimal API server pod might be 50 lines. The operator produces 500+ lines. Here's why:

## etcd Example

### Minimal Manual etcd Pod
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: etcd
  namespace: openshift-etcd
spec:
  hostNetwork: true
  containers:
  - name: etcd
    image: quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:...
    command:
    - etcd
    - --name=etcd-0
    - --data-dir=/var/lib/etcd
    - --listen-peer-urls=https://0.0.0.0:2380
    - --listen-client-urls=https://0.0.0.0:2379
    - --advertise-client-urls=https://etcd-0.example.com:2379
    - --initial-advertise-peer-urls=https://etcd-0.example.com:2380
    - --initial-cluster=etcd-0=https://etcd-0.example.com:2380
    - --cert-file=/etc/kubernetes/secrets/etcd-server.crt
    - --key-file=/etc/kubernetes/secrets/etcd-server.key
    - --peer-cert-file=/etc/kubernetes/secrets/etcd-peer.crt
    - --peer-key-file=/etc/kubernetes/secrets/etcd-peer.key
    - --trusted-ca-file=/etc/kubernetes/secrets/etcd-ca.crt
    - --peer-trusted-ca-file=/etc/kubernetes/secrets/etcd-ca.crt
    volumeMounts:
    - name: data
      mountPath: /var/lib/etcd
    - name: certs
      mountPath: /etc/kubernetes/secrets
  volumes:
  - name: data
    hostPath:
      path: /var/lib/etcd
  - name: certs
    hostPath:
      path: /etc/kubernetes/etcd-secrets
```

### What the Operator Adds

1. **Health checks**
```yaml
livenessProbe:
  httpGet:
    host: 127.0.0.1
    path: /health
    port: 2381
    scheme: HTTP
  initialDelaySeconds: 45
  timeoutSeconds: 10
readinessProbe:
  httpGet:
    host: 127.0.0.1
    path: /readyz
    port: 2381
```

2. **Resource limits**
```yaml
resources:
  requests:
    cpu: 100m
    memory: 600Mi
```

3. **Security context**
```yaml
securityContext:
  privileged: true
```

4. **Environment variables for tuning**
```yaml
env:
- name: ETCD_QUOTA_BACKEND_BYTES
  value: "8589934592"
- name: ETCD_HEARTBEAT_INTERVAL
  value: "100"
- name: ETCD_ELECTION_TIMEOUT
  value: "1000"
```

5. **Init containers for waiting on dependencies**
```yaml
initContainers:
- name: setup
  image: ...
  command: ["/bin/sh", "-c", "..."]
```

6. **Metrics endpoint**
```yaml
- name: etcd-metrics
  containerPort: 2381
```

## kube-apiserver Example

### What Operators Add

1. **Many admission controllers**
```yaml
- --enable-admission-plugins=NodeRestriction,PodSecurity,...
```

2. **Audit logging**
```yaml
- --audit-log-path=/var/log/kube-apiserver/audit.log
- --audit-policy-file=/etc/kubernetes/audit/policy.yaml
- --audit-log-maxage=30
- --audit-log-maxbackup=10
```

3. **Feature gates**
```yaml
- --feature-gates=APIPriorityAndFairness=true,...
```

4. **API server identity**
```yaml
- --api-audiences=https://kubernetes.default.svc
- --service-account-issuer=https://kubernetes.default.svc
```

5. **Aggregation layer**
```yaml
- --requestheader-client-ca-file=/etc/kubernetes/secrets/aggregator-ca.crt
- --requestheader-allowed-names=aggregator
- --requestheader-extra-headers-prefix=X-Remote-Extra-
- --requestheader-group-headers=X-Remote-Group
- --requestheader-username-headers=X-Remote-User
- --proxy-client-cert-file=/etc/kubernetes/secrets/aggregator.crt
- --proxy-client-key-file=/etc/kubernetes/secrets/aggregator.key
```

6. **Encryption at rest**
```yaml
- --encryption-provider-config=/etc/kubernetes/secrets/encryption-config.yaml
```

7. **Many volume mounts for secrets**

The operator correctly mounts 15+ different secret/configmap volumes.

## Key Differences Summary

| Aspect | Manual | Operator |
|--------|--------|----------|
| Lines of YAML | ~50 | ~500+ |
| Health checks | Basic or none | Comprehensive |
| Security | Basic | Hardened |
| Observability | None | Metrics, audit |
| Feature completeness | Minimal | Full |
| Version compatibility | Fragile | Tested |

## Conclusion

Operator rendering:
- Saves ~450 lines of YAML per component
- Encodes production best practices
- Handles version-specific differences
- Is tested with each release

The educational value is understanding WHAT the operator produces, not reimplementing it.
