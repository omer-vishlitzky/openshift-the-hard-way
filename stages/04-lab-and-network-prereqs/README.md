# Stage 04: Lab and Network Prereqs

This stage defines a practical HA baseline for bare metal while explaining the underlying requirements so the knowledge transfers to other topologies, including SNO. The goal is to have a lab that is reproducible, observable, and aligned with the OpenShift 4.18 docs.

**Sources used in this stage**
- `../pdfs/openshift/Installing_on_bare_metal.pdf`
- `../pdfs/openshift/Installation_overview.pdf`

## Baseline topology (HA)

- 1 bootstrap node (temporary)
- 3 control plane nodes
- 2 or more compute nodes
- 2 load balancer nodes (HAProxy + Keepalived)
- 1 DNS service (external, lab-local, or enterprise DNS)

This topology matches the minimum HA shape required for etcd quorum and control plane redundancy.

## Minimum machine requirements (from docs)

- Bootstrap: RHCOS, 4 CPU, 16 GB RAM, 100 GB storage, 300 IOPS
- Control plane: RHCOS, 4 CPU, 16 GB RAM, 100 GB storage, 300 IOPS
- Compute: RHCOS or RHEL 8.6+, 2 CPU, 8 GB RAM, 100 GB storage, 300 IOPS
- Storage note: etcd on control plane nodes requires fast storage and a p99 fsync of 10 ms or lower.

## Network requirements (HA baseline)

- All nodes must have L3 connectivity to each other and to the load balancers.
- DNS A/AAAA and PTR records must resolve for API, bootstrap, and all nodes.
- The API and Ingress load balancers must use Layer 4 (TCP) with no TLS termination for the API.
- The API load balancer must not use session persistence.
- The API health check should use `/readyz` on port 6443 and remove unhealthy backends within 30 seconds.

## Required DNS records (UPI-style bare metal)

The bare metal docs list these records as required. Use your cluster name and base domain.

- `api.<cluster>.<base_domain>`: API load balancer VIP
- `api-int.<cluster>.<base_domain>`: API load balancer VIP (internal resolution)
- `*.apps.<cluster>.<base_domain>`: Ingress load balancer VIP
- `bootstrap.<cluster>.<base_domain>`: Bootstrap node
- `<control-plane><n>.<cluster>.<base_domain>`: Control plane nodes
- `<compute><n>.<cluster>.<base_domain>`: Compute nodes

Note: etcd SRV records are not required for OpenShift 4.4 and later.

## Load balancer design (HAProxy + Keepalived)

We will run two load balancer nodes in an active-passive pair using VRRP (Keepalived) and HAProxy.

VIPs:
- `api` VIP: TCP 6443 (Kubernetes API) and TCP 22623 (Machine Config Server)
- `apps` VIP: TCP 80 and TCP 443 (Ingress)

Backend pools:
- API (6443): bootstrap and control plane during install, control plane only after bootstrap removal
- MCS (22623): bootstrap and control plane during install, control plane only after bootstrap removal
- Ingress (80/443): compute nodes by default (control plane if 3-node without workers)

Example configs are in:
- `stages/04-lab-and-network-prereqs/examples/haproxy.cfg`
- `stages/04-lab-and-network-prereqs/examples/keepalived.conf`

Operational notes:
- After bootstrap completes, remove the bootstrap node from the API and MCS pools and reload HAProxy.
- If SELinux is enforcing on the load balancer, set `haproxy_connect_any=1` so HAProxy can bind to the required ports.
- In Keepalived, set one node to `state MASTER` with higher priority and the other to `state BACKUP` with lower priority.

## Required ports (from bare metal docs)

- All nodes to all nodes: ICMP, TCP 1936, TCP 9000-9999, TCP 10250-10259, UDP 4789, UDP 6081, UDP 500, UDP 4500, UDP 123, TCP/UDP 30000-32767, ESP
- All nodes to control plane: TCP 6443
- Control plane to control plane: TCP 2379-2380
- Load balancer front and back ends, API: TCP 6443 and TCP 22623
- Load balancer front and back ends, Ingress: TCP 80 and TCP 443

## Time sync (NTP)

- RHCOS uses chrony. If you use an enterprise or local NTP server, ensure UDP 123 is open and NTP is reachable from all nodes.

## Validation checklist

Run these before bootstrapping the cluster.

DNS forward resolution:
- `dig api.<cluster>.<base_domain>`
- `dig api-int.<cluster>.<base_domain>`
- `dig +short *.apps.<cluster>.<base_domain>`
- `dig bootstrap.<cluster>.<base_domain>`

DNS reverse resolution for API and each node:
- `dig -x <api_vip>`
- `dig -x <node_ip>`

LB reachability:
- `nc -zv api.<cluster>.<base_domain> 6443`
- `nc -zv api.<cluster>.<base_domain> 22623`
- `nc -zv <apps_vip> 80`
- `nc -zv <apps_vip> 443`

NTP sync status (once nodes are up):
- `chronyc sources -v`

**Deliverables for this stage**
- HA baseline lab topology, DNS records, and load balancer requirements.
- HAProxy + Keepalived example configs for the lab.
