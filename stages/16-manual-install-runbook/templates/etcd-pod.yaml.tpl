apiVersion: v1
kind: Pod
metadata:
  name: etcd
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
  - name: etcd
    image: ${ETCD_IMAGE}
    command:
    - /usr/local/bin/etcd
    - --name=${NODE_NAME}
    - --data-dir=/var/lib/etcd
    - --initial-advertise-peer-urls=https://${NODE_IP}:2380
    - --listen-peer-urls=https://${NODE_IP}:2380
    - --listen-client-urls=https://${NODE_IP}:2379,https://127.0.0.1:2379
    - --advertise-client-urls=https://${NODE_IP}:2379
    - --initial-cluster=${ETCD_INITIAL_CLUSTER}
    - --initial-cluster-state=new
    - --initial-cluster-token=etcd-cluster-0
    - --cert-file=/etc/kubernetes/pki/etcd/${NODE_NAME}-server.crt
    - --key-file=/etc/kubernetes/pki/etcd/${NODE_NAME}-server.key
    - --peer-cert-file=/etc/kubernetes/pki/etcd/${NODE_NAME}-peer.crt
    - --peer-key-file=/etc/kubernetes/pki/etcd/${NODE_NAME}-peer.key
    - --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
    - --peer-trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
    - --client-cert-auth=true
    - --peer-client-cert-auth=true
    volumeMounts:
    - name: etcd-data
      mountPath: /var/lib/etcd
    - name: pki
      mountPath: /etc/kubernetes/pki/etcd
  volumes:
  - name: etcd-data
    hostPath:
      path: /var/lib/etcd
  - name: pki
    hostPath:
      path: /etc/kubernetes/pki/etcd
