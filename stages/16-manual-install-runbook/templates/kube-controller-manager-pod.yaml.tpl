apiVersion: v1
kind: Pod
metadata:
  name: kube-controller-manager
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
  - name: kube-controller-manager
    image: ${KUBE_CONTROLLER_MANAGER_IMAGE}
    command:
    - kube-controller-manager
    - --allocate-node-cidrs=true
    - --cluster-cidr=${CLUSTER_CIDR}
    - --service-cluster-ip-range=${SERVICE_CIDR}
    - --cluster-name=${CLUSTER_NAME}
    - --cluster-signing-cert-file=/etc/kubernetes/pki/ca.crt
    - --cluster-signing-key-file=/etc/kubernetes/pki/ca.key
    - --kubeconfig=/etc/kubernetes/kube-controller-manager.kubeconfig
    - --leader-elect=true
    - --root-ca-file=/etc/kubernetes/pki/ca.crt
    - --service-account-private-key-file=/etc/kubernetes/pki/sa.key
    volumeMounts:
    - name: pki
      mountPath: /etc/kubernetes/pki
    - name: kubeconfig
      mountPath: /etc/kubernetes
  volumes:
  - name: pki
    hostPath:
      path: /etc/kubernetes/pki
  - name: kubeconfig
    hostPath:
      path: /etc/kubernetes
