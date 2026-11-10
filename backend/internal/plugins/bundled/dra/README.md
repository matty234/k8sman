# Dynamic Resource Allocation (bundled plugin)

[Dynamic Resource Allocation](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/)
(`resource.k8s.io`, v1 or the beta shapes) in k8sman, written as a plugin
and compiled into the backend. It is on by default and turned off in
**Settings ▸ Integrations ▸ Dynamic Resource Allocation**, like a module.
It replaced the built-in `dra` module, which has been removed: see
[docs/PLUGINS.md](../../../../../docs/PLUGINS.md#bundled-plugins).

What it adds, for the `resource.k8s.io` kinds the cluster serves:

- A **Dynamic Resources** sidebar section after Storage, with icons.
- Columns: ResourceClaim State, Device Classes, Devices and Node;
  ResourceClaimTemplate Device Classes; DeviceClass Selectors;
  ResourceSlice Node, Driver, Pool and Devices; DeviceTaintRule Driver and
  Taint.
- Panels that replace the generic one (`panel.generic: replace`):
  - ResourceClaim: its state, the node it is allocated on, the pod and
    template it was made for; its requests (device class, count, admin
    access, tolerations and CEL selectors, `firstAvailable` alternatives);
    the allocated devices; who it is reserved for; device status (network
    data and conditions).
  - ResourceClaimTemplate: its requests.
  - DeviceClass: CEL selectors, the extended resource name, driver config.
  - ResourceSlice: node or scope, driver, pool; its devices with capacity,
    taints and attributes.
  - DeviceTaintRule keeps the generic panel.
- On core panels: **Resource claims** on a Pod (each claim, the claim
  object behind it, its template and the containers using it) and **DRA
  devices** on a Node (the ResourceSlices published for it). These sit after
  the Pod's and Node's own sections, and only when there is something to
  show.
- A status line on its Integrations row: "ResourceClaims: 4 · pending: 1".

Work on it like any plugin: load this folder in developer mode (it overrides
the bundled copy while loaded), and run its fixtures with
`k8sman-server plugin test backend/internal/plugins/bundled/dra`
(`go test ./internal/plugins` runs them too).
