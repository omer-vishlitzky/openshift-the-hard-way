apiVersion: config.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  clusterNetwork:
  - cidr: ${CLUSTER_CIDR}
    hostPrefix: 23
  serviceNetwork:
  - ${SERVICE_CIDR}
  networkType: OVNKubernetes
