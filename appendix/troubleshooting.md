# Troubleshooting

Common issues and how to fix them.

## Bootstrap Issues

### bootkube.sh fails to start

**Symptoms**: bootkube service fails, no static pods running

**Debug**:
```bash
ssh core@bootstrap
sudo journalctl -u bootkube --no-pager

# Check for image pull issues
sudo journalctl -u crio | grep -i error
```

**Common causes**:
- Pull secret invalid or missing
- Network can't reach registry
- Disk full

### etcd won't start on bootstrap

**Symptoms**: etcd pod in CrashLoopBackOff

**Debug**:
```bash
sudo crictl logs $(sudo crictl ps -a -q --name etcd)
```

**Common causes**:
- Certificate mismatch (wrong SANs)
- Data directory permissions
- Disk too slow (etcd needs <10ms fsync)

### API server not responding

**Symptoms**: `curl -k https://localhost:6443/healthz` fails

**Debug**:
```bash
sudo crictl logs $(sudo crictl ps -a -q --name kube-apiserver)
```

**Common causes**:
- etcd not ready
- Certificate errors
- Resource exhaustion (OOM)

## DNS Issues

### Nodes can't resolve cluster DNS

**Symptoms**: `dig api.cluster.example.com` fails

**Debug**:
```bash
# Check dnsmasq
systemctl status dnsmasq
journalctl -u dnsmasq

# Check DNS config
cat /etc/dnsmasq.d/ocp4.conf

# Test directly
dig @192.168.126.1 api.ocp4.example.com
```

**Fix**: Verify DNS server is running and nodes use it as resolver.

### Pods can't resolve internal DNS

**Symptoms**: Pods can't reach `kubernetes.default.svc`

**Debug**:
```bash
# Check dns operator
oc get co dns

# Check dns pods
oc get pods -n openshift-dns

# Test from pod
oc run test --rm -it --image=busybox -- nslookup kubernetes.default
```

## etcd Issues

### etcd cluster ID mismatch

**Symptoms**: "cluster ID mismatch" in etcd logs

**Cause**: Members formed separate clusters

**Fix**:
1. Stop all etcd members
2. Remove data directories on all but one
3. Re-bootstrap from remaining member

### etcd too slow

**Symptoms**: "took too long" warnings, leader elections

**Debug**:
```bash
# Check disk latency
oc exec -n openshift-etcd etcd-master-0 -c etcd -- \
  etcdctl check perf
```

**Fix**: Use SSD storage, ensure adequate IOPS.

### etcd member removal stuck

**Debug**:
```bash
# Check etcd-operator
oc logs -n openshift-etcd-operator deploy/etcd-operator

# Manual member list
oc exec -n openshift-etcd etcd-master-0 -c etcd -- \
  etcdctl member list
```

## Certificate Issues

### Certificate expired

**Symptoms**: TLS handshake failures

**Debug**:
```bash
# Check cert expiry
openssl x509 -in /path/to/cert.crt -noout -enddate

# Check API server cert
echo | openssl s_client -connect api.${CLUSTER_DOMAIN}:6443 2>/dev/null | openssl x509 -noout -enddate
```

### Certificate SAN mismatch

**Symptoms**: "certificate is valid for X, not Y"

**Debug**:
```bash
openssl x509 -in cert.crt -noout -text | grep -A1 "Subject Alternative Name"
```

## Network Issues

### Pods stuck ContainerCreating

**Symptoms**: Pods never start, CNI errors

**Debug**:
```bash
# Check CNI pods
oc get pods -n openshift-ovn-kubernetes

# Check CNI logs
oc logs -n openshift-ovn-kubernetes ds/ovnkube-node --all-containers
```

### Service not reachable

**Debug**:
```bash
# Check endpoints
oc get endpoints <service-name>

# Check service
oc describe service <service-name>

# Test from node
oc debug node/<node> -- chroot /host curl <service-ip>
```

## Ingress Issues

### Routes not accessible

**Debug**:
```bash
# Check ingress operator
oc get co ingress

# Check router pods
oc get pods -n openshift-ingress -o wide

# Check router logs
oc logs -n openshift-ingress deploy/router-default
```

### Wildcard DNS not resolving

**Fix**: Ensure `*.apps.cluster.example.com` resolves to ingress VIP.

## MCO Issues

### Node stuck updating

**Debug**:
```bash
# Check node state
oc get node <node> -o jsonpath='{.metadata.annotations.machineconfiguration\.openshift\.io/state}'

# Check MCD logs
oc logs -n openshift-machine-config-operator -l k8s-app=machine-config-daemon -c machine-config-daemon
```

### MachineConfigPool degraded

**Debug**:
```bash
oc describe mcp <pool-name>

# Check which nodes are degraded
oc get nodes -l node-role.kubernetes.io/<role>
```

## Resource Issues

### Nodes NotReady

**Debug**:
```bash
# Check node conditions
oc describe node <node> | grep -A10 Conditions

# Check kubelet
oc debug node/<node> -- chroot /host journalctl -u kubelet --no-pager | tail -50
```

### OOMKilled pods

**Debug**:
```bash
# Check pod events
oc describe pod <pod>

# Check resource usage
oc adm top nodes
oc adm top pods -A
```

## Authentication Issues

### Can't login to console

**Debug**:
```bash
# Check authentication operator
oc get co authentication

# Check OAuth server
oc get pods -n openshift-authentication

# Check OAuth logs
oc logs -n openshift-authentication deploy/oauth-openshift
```

### kubeadmin password not working

**Fix**:
```bash
# Get correct password
oc get secret -n kube-system kubeadmin -o jsonpath='{.data.password}' | base64 -d
```

## Useful Debug Commands

```bash
# Cluster overview
oc get nodes,co,mcp

# All pods not running
oc get pods -A | grep -v Running | grep -v Completed

# Events
oc get events -A --sort-by='.lastTimestamp' | tail -20

# Node debug shell
oc debug node/<node>

# Pod logs with previous
oc logs <pod> --previous

# All containers in pod
oc logs <pod> --all-containers

# Describe everything
oc describe <resource> <name>
```
