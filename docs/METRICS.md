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

Default columns: pods get **CPU** and **Memory**; nodes get **CPU**, **CPU%**,
**Memory**, **Mem%** (plus allocatable as **Alloc CPU** / **Alloc Memory**).
They use the `quantity` column type: right-aligned, sorted by parsed value,
"—" when empty, and percentages coloured at ≥70% (amber) and ≥90% (red).

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
so `GET /api/metrics/external/discover` also lists the `External` metrics
referenced by HPAs, with their selectors (e.g. KEDA's
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
- **HPA panel:** a Live metrics section (above).
- **Metrics page** (nav → Metrics): API status strip; a **Top** tab
  (sortable nodes and pods, % of requests/limits, following the namespace
  filter, refreshed every 15s); **Custom metrics** (pick a resource type and
  metric, optional label selector, values per object); **External metrics**
  (known metrics or a typed name, optional selector). Clicking an object
  opens it in the inspector.

Colour is used only for thresholds: ≥70% amber, ≥90% red.

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
