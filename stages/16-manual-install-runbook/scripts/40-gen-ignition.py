#!/usr/bin/env python3
import base64
import json
import os
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
CONFIG = ROOT_DIR / "config"
GEN = ROOT_DIR / "generated"
PKI = GEN / "pki"
KUBECONFIG = GEN / "kubeconfig"
MANIFESTS = GEN / "manifests"

# Load cluster vars from env
required_env = [
    "CLUSTER_DOMAIN",
    "BOOTSTRAP",
    "MASTER0",
    "MASTER1",
    "MASTER2",
    "WORKER0",
    "WORKER1",
    "SSH_PUB_KEY",
]
missing = [k for k in required_env if k not in os.environ]
if missing:
    raise SystemExit(f"Missing env vars: {', '.join(missing)}")

CLUSTER_DOMAIN = os.environ["CLUSTER_DOMAIN"]
SSH_PUB_KEY = os.environ["SSH_PUB_KEY"]

HOSTS = [
    os.environ["BOOTSTRAP"],
    os.environ["MASTER0"],
    os.environ["MASTER1"],
    os.environ["MASTER2"],
    os.environ["WORKER0"],
    os.environ["WORKER1"],
]

CONTROL_PLANE = [
    os.environ["BOOTSTRAP"],
    os.environ["MASTER0"],
    os.environ["MASTER1"],
    os.environ["MASTER2"],
]

COMMON_FILES = [
    ("/etc/kubernetes/kubelet-config.yaml", CONFIG / "kubelet-config.yaml", 0o644),
    ("/etc/systemd/system/kubelet.service.d/20-hardway.conf", CONFIG / "systemd" / "kubelet-override.conf", 0o644),
]

DIRECTORIES = [
    "/etc/systemd/system/kubelet.service.d",
    "/etc/kubernetes",
    "/etc/kubernetes/pki",
    "/etc/kubernetes/pki/etcd",
    "/etc/kubernetes/manifests",
    "/home/core/.ssh",
]


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode("utf-8")


def file_entry(path: str, src: Path, mode: int = 0o644):
    data = src.read_bytes()
    return {
        "path": path,
        "mode": mode,
        "contents": {"source": "data:text/plain;base64," + b64(data)},
    }


def inline_entry(path: str, contents: str, mode: int = 0o644):
    data = contents.encode("utf-8")
    return {
        "path": path,
        "mode": mode,
        "contents": {"source": "data:text/plain;base64," + b64(data)},
    }


def ignition_for_node(node: str):
    files = []
    files.append(inline_entry("/etc/hostname", f"{node}.{CLUSTER_DOMAIN}\n", 0o644))
    files.append(inline_entry("/home/core/.ssh/authorized_keys", SSH_PUB_KEY + "\n", 0o600))

    for dest, src, mode in COMMON_FILES:
        files.append(file_entry(dest, src, mode))

    # kubelet kubeconfig for this node
    kubelet_kc = KUBECONFIG / f"kubelet-{node}.kubeconfig"
    if kubelet_kc.exists():
        files.append(file_entry("/etc/kubernetes/kubelet.kubeconfig", kubelet_kc, 0o600))

    if node in CONTROL_PLANE:
        # PKI
        files.append(file_entry("/etc/kubernetes/pki/ca.crt", PKI / "ca.crt", 0o644))
        files.append(file_entry("/etc/kubernetes/pki/ca.key", PKI / "ca.key", 0o600))
        files.append(file_entry("/etc/kubernetes/pki/apiserver.crt", PKI / "apiserver.crt", 0o644))
        files.append(file_entry("/etc/kubernetes/pki/apiserver.key", PKI / "apiserver.key", 0o600))
        files.append(file_entry("/etc/kubernetes/pki/apiserver-kubelet-client.crt", PKI / "apiserver-kubelet-client.crt", 0o644))
        files.append(file_entry("/etc/kubernetes/pki/apiserver-kubelet-client.key", PKI / "apiserver-kubelet-client.key", 0o600))
        files.append(file_entry("/etc/kubernetes/pki/front-proxy-ca.crt", PKI / "front-proxy-ca.crt", 0o644))
        files.append(file_entry("/etc/kubernetes/pki/front-proxy-client.crt", PKI / "front-proxy-client.crt", 0o644))
        files.append(file_entry("/etc/kubernetes/pki/front-proxy-client.key", PKI / "front-proxy-client.key", 0o600))
        files.append(file_entry("/etc/kubernetes/pki/sa.key", PKI / "sa.key", 0o600))
        files.append(file_entry("/etc/kubernetes/pki/sa.pub", PKI / "sa.pub", 0o644))

        # etcd certs
        files.append(file_entry(f"/etc/kubernetes/pki/etcd/{node}-server.crt", PKI / "etcd" / f"{node}-server.crt", 0o644))
        files.append(file_entry(f"/etc/kubernetes/pki/etcd/{node}-server.key", PKI / "etcd" / f"{node}-server.key", 0o600))
        files.append(file_entry(f"/etc/kubernetes/pki/etcd/{node}-peer.crt", PKI / "etcd" / f"{node}-peer.crt", 0o644))
        files.append(file_entry(f"/etc/kubernetes/pki/etcd/{node}-peer.key", PKI / "etcd" / f"{node}-peer.key", 0o600))
        files.append(file_entry(f"/etc/kubernetes/pki/etcd/{node}-client.crt", PKI / "etcd" / f"{node}-client.crt", 0o644))
        files.append(file_entry(f"/etc/kubernetes/pki/etcd/{node}-client.key", PKI / "etcd" / f"{node}-client.key", 0o600))
        files.append(file_entry("/etc/kubernetes/pki/etcd/ca.crt", PKI / "etcd" / "ca.crt", 0o644))
        files.append(file_entry("/etc/kubernetes/pki/etcd/apiserver-etcd-client.crt", PKI / "etcd" / "apiserver-etcd-client.crt", 0o644))
        files.append(file_entry("/etc/kubernetes/pki/etcd/apiserver-etcd-client.key", PKI / "etcd" / "apiserver-etcd-client.key", 0o600))

        # kubeconfigs
        files.append(file_entry("/etc/kubernetes/kube-controller-manager.kubeconfig", KUBECONFIG / "kube-controller-manager.kubeconfig", 0o600))
        files.append(file_entry("/etc/kubernetes/kube-scheduler.kubeconfig", KUBECONFIG / "kube-scheduler.kubeconfig", 0o600))

        # static pod manifests
        manifest_dir = MANIFESTS / node
        if manifest_dir.exists():
            for mf in manifest_dir.glob("*.yaml"):
                files.append(file_entry(f"/etc/kubernetes/manifests/{mf.name}", mf, 0o644))

    ignition = {
        "ignition": {"version": "3.2.0"},
        "storage": {
            "directories": [{"path": d} for d in DIRECTORIES],
            "files": files,
        },
        "systemd": {
            "units": [
                {"name": "kubelet.service", "enabled": True},
            ]
        }
    }
    return ignition


out_dir = GEN / "ignition"
out_dir.mkdir(parents=True, exist_ok=True)

for node in HOSTS:
    ign = ignition_for_node(node)
    out_file = out_dir / f"{node}.ign"
    out_file.write_text(json.dumps(ign, indent=2))

print(f"Ignition configs written to {out_dir}")
