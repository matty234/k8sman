# Metrics APIs

k8sman reads the three Kubernetes metrics APIs (the aggregated APIs behind
`kubectl top` and the HPA). It does not keep history; for PromQL history and
alerts see the Prometheus pages.

| API | Typical provider | Used for |
|---|---|---|
| `metrics.k8s.io/v1beta1` | metrics-server | live CPU/memory of nodes, pods and containers |
| `custom.metrics.k8s.io/v1beta2` (falls back to `v1beta1`) | prometheus-adapter | per-object application metrics (HPA `Pods` / `Object` metrics) |
| `external.metrics.k8s.io/v1beta1` | KEDA, cloud adapters | metrics from outside the cluster (HPA `External` metrics) |

Backend: `backend/internal/metrics`. Frontend: `frontend/lib/metrics`.
Endpoints are listed in [API.md](../API.md#metrics).

## Availability

`GET /api/metrics/status` reads the `APIService` registrations
(`apiregistration.k8s.io/v1`). Each group is one of:

- `available`: registered and `Available=True`
- `notReady`: registered but `Available=False` (adapter starting, `FailedDiscoveryCheck`,
  `MissingEndpoints`), or metrics-server has not scraped yet (empty node list)
- `notInstalled`: no APIService for the group
- `unknown`: can't tell

Without RBAC to read APIServices, it falls back to discovery (`/apis/<group>/<version>`).
Data endpoints return **404** with `state: notInstalled` or **503** with
`state: notReady`, so the UI can offer "Install metrics-server" (via
`requestAddon`) or just "not ready yet".

## Usage in tables

When `/api/table`, `/api/watch` or `/api/columns/preview` lists **pods** or
**nodes**, the server fetches one usage snapshot (cached ~10s and shared
between requests) and evaluates the jq columns against a shallow copy of
each object with a reserved key added:

```
.k8sman.usage = {
  cpu: "12m", memory: "7340032",          # millicores, bytes (strings)
  cpuMillis: 12, memoryBytes: 7340032,    # same, as numbers
  # pods:  window, timestamp, containers: {<name>: {cpu, memory, cpuMillis, memoryBytes}}
  # nodes: cpuPercent, memoryPercent      # of status.allocatable
}
```

Stored objects are never mutated, and `row.object` (with `includeObject`) is
the original. Objects without a sample have no `.k8sman` key, so the
column is empty and renders as "—". User-defined columns can use it too,
e.g. `{"name": "CPU/req", "type": "quantity", "query": ".k8sman.usage.cpuMillis"}`.

Pods also get their containers' limits and requests summed
(`cpuLimitMillis`, `cpuRequestMillis`, `memoryLimitBytes`,
`memoryRequestBytes`; a limit only when every container has one) and nodes
their allocatable (`cpuAllocatableMillis`, `memoryAllocatableBytes`). Usage is
measured against the limit, else the request (nodes: allocatable):
`cpuBasis`/`memoryBasis` (`limit`, `request` or `allocatable`),
`cpuBase`/`memoryBase` (cores, bytes) and `cpuPercent`/`memoryPercent` (one
decimal). This comes from the object itself, so it costs no extra calls.

Default columns: pods and nodes get **CPU** and **Memory** (nodes also
allocatable as **Alloc CPU** / **Alloc Memory**). They use the `usage` column
type, whose cell is `{raw, base?, percent?, basis?, unit}` (`raw`/`base` in
cores or bytes, `unit` `cpu` or `bytes`): the value, a thin bar and the
percentage, coloured at ≥70% (amber) and ≥90% (red); under ~90px only the
value. Sorting orders by the percentage, then the value; filters compare the
value (`cpu>500m`) or, with `%`, the percentage (`cpu%>80`, `cpu>80%`). The
PVC table's **Used** column uses it too, with `basis: "capacity"`: "12 / 50
Gi", a bar and the percentage (amber from 80%).

**Live updates.** A pod/node `/api/watch` also re-evaluates its rows every
15s with fresh usage, without re-listing. It keeps the latest object per UID
(from the snapshot and watch events) and the cells it last sent, and sends
`MODIFIED` only for rows whose cells changed. When metrics are unavailable the
tick fetches nothing and sends nothing.

## HPA analysis

`GET /api/metrics/hpa?namespace=&name=` evaluates each `spec.metrics` entry
against the live APIs, roughly as the HPA controller does:

- `Resource` / `ContainerResource`: pods from the scale target's `/scale`
  selector (Running, not terminating), with usage from metrics.k8s.io;
  utilisation = Σusage / Σrequests over pods with samples
- `Pods`: custom metric `pods/*/<metric>` with the target's selector, averaged
- `Object`: the custom metric on the described object
- `External`: the external metric with the HPA's selector, summed

Each metric gets a proposed replica count (`ceil(ratio × pods)`, or
`ceil(total / averageValue)`, unchanged within the default 10% tolerance).
The largest proposal is `driving`. `limitedBy` is `min`/`max` when the bounds,
not a metric, set the result. The panel shows these live values next to the
HPA's own `status.currentMetrics`.

## External metric names

Adapters like KEDA only advertise a placeholder resource (`externalmetrics`),
so the HPA panel reads `External` metric names and selectors from the HPAs
themselves (e.g. KEDA's
`s1-cron-Etc-UTC-0xxxx-30xxxx` with `scaledobject.keda.sh/name=web`).

## UI

- **Nodes page / Node panel:** CPU and memory meters: usage filled, requests
  outlined, limits as ticks (panel), scaled to allocatable. Without metrics
  they fall back to the request bars and a "Metrics unavailable · Install
  metrics-server" note.
- **Pod panel:** pod total in the Status summary, and a usage row per running
  container (against its request, outlined, and its limit, tick).
  Percentages are of the limit when set, otherwise of the request.
- **Deployment / StatefulSet / DaemonSet:** a Usage section with summed usage
  vs summed requests over the pods that have samples, the per-pod spread
  (min / median / max) and the busiest pods.
- **HPA panel:** the Metrics section shows each metric's live value (above)
  next to its target, with a bar of current against target (the tick), the
  replicas it proposes and which metric is driving; the HPA's own
  `status.currentMetrics` is shown beside it, and alone when the live call
  fails.
- **Node / Pod panels:** live network receive/transmit from the kubelet when
  there is no Prometheus (with Prometheus the history charts show it).
- **PVC panel:** a Usage bar (used of capacity, free space, inodes, and with
  Prometheus a "full in ~N days" trend plus history).

Colour is used only for thresholds: ≥70% amber, ≥90% red (PVCs: ≥80% amber,
≥90% red).

## Storage and network usage

PVC usage and network throughput aren't in `metrics.k8s.io`. k8sman reads
them from Prometheus when a reachable instance is discovered (see
[PROMETHEUS.md](PROMETHEUS.md)), else from the **kubelet Summary API**:
`GET /api/metrics/summary` fetches `/api/v1/nodes/<node>/proxy/stats/summary`
(needs `get` on `nodes/proxy`) from the asked nodes, or every Ready node, in
parallel (16 at a time, 10s timeout each) and caches each node for ~12s, so the
panels and the Metrics tabs share one fetch per node.

- **Volumes:** the pod volumes with a `pvcRef` (`usedBytes`,
  `capacityBytes`, `availableBytes`, inodes). Kubelets report only volumes
  mounted by a running pod, so an unbound or idle claim shows "not mounted,
  usage unknown". Some volume types (e.g. hostPath-backed local-path
  volumes) report no stats at all.
- **Network:** cumulative `rxBytes`/`txBytes` per pod and node, summed over
  non-virtual interfaces (same exclusions as the
  Prometheus node query, including VLANs; with an active bond only bonds
  count). Rates come from the difference between the last two
  distinct samples (by the kubelet's own timestamp) held in the cache; they
  are absent until a second sample arrives (~15s), after a counter reset or
  pod recreation, or when the previous sample is older than 3 minutes.
  The Pod and Node panels show this live rate only when there is no
  Prometheus.

Prometheus and the kubelets are combined **per claim**: some Prometheus
setups scrape the kubelet but drop `kubelet_volume_stats_*`, so the PVC panel
falls back to the kubelet whenever Prometheus has no series for the claim
(and hides the history chart), and `GET /api/metrics/volumes` (the Storage
tab) merges both sources, Prometheus first.

It fails soft: no permission or unreachable kubelets give `state:
"unavailable"` (with per-node `errors` when only some fail), never an HTTP
error, and the UI shows a quiet note or nothing.

## Dev cluster

The kind dev cluster (k8s 1.25) has:

- metrics-server 3.14.0 chart (`kube-system`, `--kubelet-insecure-tls`)
- KEDA 2.11.2 (`keda`, `webhooks.enabled=false`) and the ScaledObject in
  `dev/keda-web.yaml`, which takes over the `demo/web` HPA (CPU 70% + a
  cron trigger), so there is a real external metric
- prometheus-adapter 5.3.0 chart (`monitoring`), pointing at the
  kube-prometheus-stack Prometheus, which serves `custom.metrics.k8s.io/v1beta1`

```
helm install keda kedacore/keda --version 2.11.2 -n keda --create-namespace --set webhooks.enabled=false
kubectl apply -f dev/keda-web.yaml
helm install prometheus-adapter prometheus-community/prometheus-adapter --version 5.3.0 -n monitoring \
  --set prometheus.url=http://kube-prometheus-stack-prometheus.monitoring.svc --set prometheus.port=9090
```
