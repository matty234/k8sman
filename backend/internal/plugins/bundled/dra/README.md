# Dynamic Resource Allocation (bundled plugin)

[Dynamic Resource Allocation](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/)
(`resource.k8s.io`, v1 or the beta shapes) in k8sman, written as a plugin
and compiled into the backend. It is on by default and turned off in
**Settings ▸ Integrations ▸ Dynamic Resource Allocation**, like a module.
It replaced the built-in `dra` module, which has been removed: see
[docs/PLUGINS.md](../../../../../docs/PLUGINS.md#bundled-plugins).

What it adds, for the `resource.k8s.io` kinds the cluster serves:

- A **Dynamic Resources** sidebar section, with icons.
- Columns: ResourceClaim State, Device Classes, Devices and Node;
  ResourceClaimTemplate Device Classes; DeviceClass Selectors;
  ResourceSlice Node, Driver, Pool and Devices; DeviceTaintRule Driver and
  Taint.
- Panels that replace the generic one (`panel.generic: replace`):
  - ResourceClaim: its state, the node it is allocated on, the pod and
    template it was made for; its requests (device class, count, admin
    access, tolerations and CEL selectors, `firstAvailable` alternatives);
    the allocated devices, with their model, memory and attributes from
    their ResourceSlice; who it is reserved for; device status (network
    data and conditions).
  - ResourceClaimTemplate: its requests.
  - DeviceClass: CEL selectors, the extended resource name, driver config;
    the claims that request it, across namespaces ("2 devices allocated").
  - ResourceSlice: node or scope, driver, pool; its devices with capacity,
    taints, attributes and the pod (or claim) each is allocated to
    ("1/2 allocated").
  - DeviceTaintRule keeps the generic panel.
- On core panels, only when there is something to show:
  - Pod: **Attached devices**, right after the status, with a header
    badge ("2 GPUs", "3 devices"): each allocated device (driver, pool,
    device, model and memory, every attribute), the claim it came from,
    and the other pods sharing that claim. A pending pod says why it waits
    (claim not created yet, not allocated because no node has matching
    devices free, reservedFor full) with the scheduler's message, and the
    badge says "Waiting for devices". **Resource claims**, after
    Configuration: each claim entry, its claim and state, template and the
    containers using it.
  - Deployment, StatefulSet, DaemonSet, ReplicaSet and Job: **Devices**,
    after Pods: "4 × gpu.example.com across 2 pods", pods pending without
    devices, and each pod's node, devices and claims. Only workloads whose
    pod template has `resourceClaims` look anything up.
  - Node: **DRA devices**, after the overview, with a header badge
    ("4/6 allocated"): allocated of total per driver and pool, each device
    free, tainted or allocated (with the pod or claim using it), and the
    ResourceSlices published for the node.
- A status line on its Integrations row: "ResourceClaims: 4 · pending: 1".

Work on it like any plugin: load this folder in developer mode (it overrides
the bundled copy while loaded), and run its fixtures with
`k8sman-server plugin test backend/internal/plugins/bundled/dra`
(`go test ./internal/plugins` runs them too).
