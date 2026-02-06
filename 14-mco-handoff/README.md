# Stage 14: MCO Handoff

The Machine Config Operator (MCO) takes over node configuration from Ignition. This stage explains how.

## What is the MCO?

The Machine Config Operator:
- Manages OS-level configuration on all nodes
- Applies MachineConfig resources
- Handles node updates and reboots
- Manages kubelet configuration
- Rotates certificates

## MCO Components

```
┌────────────────────────────────────────────────────────────────┐
│                  MACHINE CONFIG OPERATOR                        │
├────────────────────────────────────────────────────────────────┤
│  machine-config-operator (controller)                          │
│    - Watches MachineConfig resources                           │
│    - Renders MachineConfigPools                                │
│    - Coordinates updates                                        │
├────────────────────────────────────────────────────────────────┤
│  machine-config-controller                                      │
│    - Manages node state                                         │
│    - Handles drain/update/reboot                               │
├────────────────────────────────────────────────────────────────┤
│  machine-config-daemon (on each node)                          │
│    - Applies configuration                                      │
│    - Reports node status                                        │
│    - Triggers reboots when needed                              │
├────────────────────────────────────────────────────────────────┤
│  machine-config-server                                          │
│    - Serves Ignition to new nodes                              │
│    - Runs on masters                                            │
└────────────────────────────────────────────────────────────────┘
```

## Check MCO Status

```bash
# MCO cluster operator
oc get co machine-config

# MCO pods
oc get pods -n openshift-machine-config-operator

# Machine config daemon on each node
oc get pods -n openshift-machine-config-operator -l k8s-app=machine-config-daemon
```

## MachineConfig Resources

MachineConfigs define node configuration:

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-worker-custom
  labels:
    machineconfiguration.openshift.io/role: worker
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - path: /etc/custom-config
        mode: 0644
        contents:
          source: data:text/plain;base64,...
    systemd:
      units:
      - name: custom.service
        enabled: true
        contents: |
          [Unit]
          Description=Custom service
          ...
```

## View MachineConfigs

```bash
# List all machineconfigs
oc get machineconfig

# Example output:
# NAME                                      GENERATEDBYCONTROLLER   IGNITIONVERSION   AGE
# 00-master                                 4.14.0                  3.2.0             1h
# 00-worker                                 4.14.0                  3.2.0             1h
# 01-master-container-runtime               4.14.0                  3.2.0             1h
# 01-master-kubelet                         4.14.0                  3.2.0             1h
# 99-master-generated-registries            4.14.0                  3.2.0             1h
# rendered-master-abc123                    4.14.0                  3.2.0             1h
# rendered-worker-def456                    4.14.0                  3.2.0             1h
```

## MachineConfigPools

MachineConfigPools group nodes and define which configs apply:

```bash
# List pools
oc get mcp

# Example output:
# NAME     CONFIG                   UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT
# master   rendered-master-abc123   True      False      False      3              3
# worker   rendered-worker-def456   True      False      False      2              2
```

## Rendered Configs

The MCO "renders" individual MachineConfigs into a single rendered config per pool:

```
┌──────────────────────────────────────────────────────────┐
│  00-master  +  01-master-kubelet  +  01-master-crio      │
│       +  99-master-custom  +  ...                        │
│                      ↓                                    │
│            rendered-master-abc123                        │
└──────────────────────────────────────────────────────────┘
```

View rendered config:
```bash
oc get machineconfig rendered-master-abc123 -o yaml
```

## Node Configuration Status

Each node has MCD annotations:

```bash
oc get node master-0 -o jsonpath='{.metadata.annotations}' | jq
```

Key annotations:
- `machineconfiguration.openshift.io/currentConfig`: Currently applied config
- `machineconfiguration.openshift.io/desiredConfig`: Target config
- `machineconfiguration.openshift.io/state`: Update state (Done, Working, Degraded)

## MCO Update Process

When a MachineConfig changes:

1. MCO renders new config
2. Controller updates pool's `desiredConfig`
3. MCD on each node detects change
4. One node at a time:
   - Cordon node
   - Drain workloads
   - Apply config
   - Reboot if needed
   - Uncordon

Watch updates:
```bash
oc get nodes -w
oc get mcp -w
```

## Verify MCO Health

```bash
# Check MCO operator
oc get co machine-config

# Check all pools updated
oc get mcp

# Check nodes match rendered config
for node in $(oc get nodes -o name); do
  current=$(oc get $node -o jsonpath='{.metadata.annotations.machineconfiguration\.openshift\.io/currentConfig}')
  desired=$(oc get $node -o jsonpath='{.metadata.annotations.machineconfiguration\.openshift\.io/desiredConfig}')
  state=$(oc get $node -o jsonpath='{.metadata.annotations.machineconfiguration\.openshift\.io/state}')
  echo "$node: state=$state current=$current desired=$desired"
done
```

## Common MCO Issues

### Node stuck updating

```bash
# Check node state
oc get node <node> -o yaml | grep machineconfig

# Check MCD logs
oc logs -n openshift-machine-config-operator -l k8s-app=machine-config-daemon -c machine-config-daemon --all-containers
```

### Pool degraded

```bash
oc describe mcp master
oc describe mcp worker
```

### Config not applying

```bash
# Check MCD on specific node
oc debug node/<node> -- chroot /host journalctl -u machine-config-daemon-host
```

## What's Next

With MCO managing nodes, continue to [Stage 15: Worker Join](../15-worker-join/README.md) to add worker nodes.
