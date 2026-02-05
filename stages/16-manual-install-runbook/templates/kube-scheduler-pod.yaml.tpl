apiVersion: v1
kind: Pod
metadata:
  name: kube-scheduler
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
  - name: kube-scheduler
    image: ${KUBE_SCHEDULER_IMAGE}
    command:
    - kube-scheduler
    - --kubeconfig=/etc/kubernetes/kube-scheduler.kubeconfig
    - --leader-elect=true
    volumeMounts:
    - name: kubeconfig
      mountPath: /etc/kubernetes
  volumes:
  - name: kubeconfig
    hostPath:
      path: /etc/kubernetes
