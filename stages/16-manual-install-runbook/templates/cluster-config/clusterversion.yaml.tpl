apiVersion: config.openshift.io/v1
kind: ClusterVersion
metadata:
  name: version
spec:
  channel: ${RELEASE_CHANNEL}
  clusterID: ${CLUSTER_ID}
  desiredUpdate:
    version: ${RELEASE_VERSION}
    image: ${RELEASE_IMAGE}
