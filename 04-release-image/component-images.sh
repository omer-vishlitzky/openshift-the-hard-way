#!/bin/bash
# Component images for OpenShift 4.18.0
# Generated from: quay.io/openshift-release-dev/ocp-release:4.18.0-x86_64
# Generated at: 2026-02-06T14:07:37+02:00

# Release Image
export RELEASE_IMAGE="quay.io/openshift-release-dev/ocp-release:4.18.0-x86_64"
export RELEASE_DIGEST="sha256:5bca02661d61955b62889e7e2e648905b7202d5788f5ba5ab69055a73dffdb5c"

# Control Plane Components
export ETCD_IMAGE="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:07b7c6877441ecd6a5646fb68e33e9be8b90092272e49117b54b4a67314731ca"
export KUBE_APISERVER_IMAGE=""
export KUBE_CONTROLLER_MANAGER_IMAGE=""
export KUBE_SCHEDULER_IMAGE=""
export HYPERKUBE_IMAGE="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:06bc35825771aee1220d34720243b89c4ba8a8b335e6de2597126bd791fd90d4"

# Operator Images (referenced in cluster manifests, manage components day 2)
export CLUSTER_ETCD_OPERATOR_IMAGE="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:a0fa3723269019bee1847b26702f42928e779036cc2f58408f8ee7866be30a93"
export CLUSTER_KUBE_APISERVER_OPERATOR_IMAGE="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:6b1876df7e369ab1f3f62292439b3a6c8939750e539b3e8bb5b8f13cdd0f6e2e"
export CLUSTER_KUBE_CONTROLLER_MANAGER_OPERATOR_IMAGE="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:ded7024d5746abb97fe37dde60ea2fc2387762d46ec8e205a13c54e4e5079811"
export CLUSTER_KUBE_SCHEDULER_OPERATOR_IMAGE="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:5b881c97aa8e440c6b3ca001edfd789a9380066b8f11f35a8dd8d88c5c7dbf86"
export CLUSTER_CONFIG_OPERATOR_IMAGE="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:737e9019a072c74321e0a909ca95481f5c545044dd4f151a34d0e1c8b9cf273f"
export CLUSTER_NETWORK_OPERATOR_IMAGE="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:e1baa38811c04bd8909e01a1f3be7421a1cb99d608d3dc4cf86d95b17de2ab8b"
export CLUSTER_INGRESS_OPERATOR_IMAGE="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:e51e6f78ec20ef91c82e94a49f950e427e77894e582dcc406eec4df807ddd76e"
export MACHINE_CONFIG_OPERATOR_IMAGE="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:c915fb8ba96e911699a1ae34a8e95ca8a9fbe1bf8c28fea177225c63a8bdfc0a"
export CLUSTER_VERSION_OPERATOR_IMAGE="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:3d65068492fcc018f2ff1b43216a9db0f2e15e1d41d23006b6a49399a53535e3"
export CLUSTER_BOOTSTRAP_IMAGE="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:39bdde7abdd86bd1cac0fb0a33860bc7e0293b41c6387cf84068072c0d9680c1"
export AUTHENTICATION_OPERATOR_IMAGE="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:7e9e7dd2b1a8394b7490ca6df8a3ee8cdfc6193ecc6fb6173ed9a1868116a207"

# Infrastructure Components
export MACHINE_CONFIG_SERVER_IMAGE=""
export HAPROXY_ROUTER_IMAGE="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:fe009d03910e18795e3bd60a3fd84938311d464d2730a2af5ded5b24e4d05a6b"
export COREDNS_IMAGE="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:487c0a8d5200bcdce484ab1169229d8fcb8e91a934be45afff7819c4f7612f57"
export CLUSTER_DNS_OPERATOR_IMAGE="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:8fdf28927b06a42ea8af3985d558c84d9efd142bb32d3892c4fa9f5e0d98133c"
export KEEPALIVED_IPFAILOVER_IMAGE="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:996a61001d1ce08f4765b76a5837aafd708ab7e9400b51d5d8eab544ce0b2558"

# Additional Components
export CLI_IMAGE="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:35512335ac39aed0f55b7f799f416f4f6445c20c1b19888cf2bb72bb276703f2"
export POD_IMAGE="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:33549946e22a9ffa738fd94b1345f90921bc8f92fa6137784cb33c77ad806f9d"
export OAUTH_PROXY_IMAGE="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:a85bf366913cafd9e8244a83b91169199f07ee27af7edb8cfbdb404e7f4bd37f"
export OAUTH_SERVER_IMAGE="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:b641ed0d63034b23d07eb0b2cd455390e83b186e77375e2d3f37633c1ddb0495"
export OAUTH_APISERVER_IMAGE="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:5aa9e5379bfeb63f4e517fb45168eb6820138041641bbdfc6f4db6427032fa37"

# Kubernetes Components
export KUBE_PROXY_IMAGE="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:b97554198294bf544fbc116c94a0a1fb2ec8a4de0e926bf9d9e320135f0bee6f"
export COREDNS_IMAGE="quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:487c0a8d5200bcdce484ab1169229d8fcb8e91a934be45afff7819c4f7612f57"

# Container Runtime (for reference)
export MACHINE_OS_CONTENT_IMAGE=""
