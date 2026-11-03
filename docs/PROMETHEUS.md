# Prometheus stack support

k8sman treats the Prometheus stack (Prometheus Operator, Prometheus,
Alertmanager) as a first-class part of the cluster:

- an **Alerts** page (nav, under Overview) with Alertmanager's alerts grouped
  by alertname, filters, silencing and a Silences tab; the nav item shows a
  count of firing critical alerts
- firing alerts as **issues on the Overview**, linked to the affected object
- detail panels for **PrometheusRule** (with live rule state),
  **ServiceMonitor / PodMonitor** (matching objects and live target health)
  and the **Prometheus / Alertmanager** custom resources
- **CPU, memory and network history** charts in the Pod, Node and
  Deployment / StatefulSet / DaemonSet panels, and **PVC usage** (bar,
  days-to-full trend and history) in the PersistentVolumeClaim panel

Live usage from `metrics.k8s.io` (metrics-server) is a separate feature; this
document covers only what comes from Prometheus and Alertmanager.

## Backend: `backend/internal/prom`

### Discovery (`discovery.go`)

1. List `prometheuses.monitoring.coreos.com` and
   `alertmanagers.monitoring.coreos.com` in all namespaces.
2. For each custom resource, pick the Service in its namespace whose
   selector matches the labels the operator puts on the instance's pods
   (`app.kubernetes.io/name`, `operator.prometheus.io/name`,
   `prometheus=`/`alertmanager=<name>`, ...). An instance-specific Service
   (e.g. `kube-prometheus-stack-prometheus`) wins over the governing
   `prometheus-operated` / `alertmanager-operated` one. The port is the one
   named `web`/`http-web`/`http`, else 9090 / 9093.
3. `spec.routePrefix` becomes the path prefix; `spec.web.tlsConfig` switches
   the scheme to https.
4. Without the CRDs (or with none of a kind), fall back to well-known
   Service names: `prometheus-operated`, `prometheus-k8s`,
   `prometheus-server`, `prometheus`; `alertmanager-operated`,
   `alertmanager-main`, `prometheus-alertmanager`, `alertmanager`.
5. Probe each instance (`/api/v1/status/buildinfo`, `/api/v2/status`, 4s
   timeout) for reachability and the running version.
6. The default instance of each kind is the first reachable one, preferring
   the `monitoring` namespace. Every endpoint accepts
   `?instance=<namespace>/<name>`.

Discovery is cached per kube context for 30s (10s when nothing was found or
something failed); `GET /api/prom/status?refresh=true` re-runs it.

### Access (`proxy.go`)

Requests go through the Kubernetes API server's service proxy with the
active context's REST client, so nothing needs port-forwarding and RBAC is
the user's own (`services/proxy` in the instance's namespace):

    /api/v1/namespaces/<ns>/services/<scheme>:<service>:<port>/proxy/<routePrefix>/<path>

Timeouts: 4s for probes, 15s for reads, 30s for queries (and `timeout=20s`
is passed to Prometheus). Upstream errors keep the most useful message:
Prometheus' `error`, Alertmanager's body, or the API server's Status.

### Endpoints

See the "Prometheus stack" section of [API.md](../API.md). In short:
`status`, `alerts`, `silences` (GET / POST / DELETE `{id}`), `rules`,
`targets`, `query`, `query_range`, all under `/api/prom/`. Silences are the
only mutations and are refused with 403 when the backend runs `--read-only`.

### Mapping back to Kubernetes objects

- **Alerts → objects** (`TargetFor`): with a `namespace` label, the first of
  `deployment`, `statefulset`, `daemonset`, `replicaset`, `job_name`,
  `cronjob`, `horizontalpodautoscaler`, `persistentvolumeclaim`,
  `poddisruptionbudget`, `pod`, `service`. Workload labels come before `pod`
  because kube-state-metrics alerts about a Deployment also carry the
  exporter's own `pod` label. Then `node` → Node, `persistentvolume` → PV,
  and a bare `namespace` → Namespace.
- **Rule groups → PrometheusRule**: the operator writes each PrometheusRule
  to `<namespace>-<name>-<uid>.yaml`, so the file name identifies it. Without
  a UID match, a group name defined by exactly one PrometheusRule is used.
- **Scrape pools → monitors**: the operator names pools
  `serviceMonitor/<ns>/<name>/<endpoint>` (likewise `podMonitor/`, `probe/`,
  `scrapeConfig/`).

### Overview

`internal/server/overview.go` fetches firing alerts from the default
Alertmanager (5s budget, nothing when none is installed) alongside the other
lists, and `internal/overview/alerts.go` turns them into issues:
`severity=critical` → critical, `warning` → warning, others → info, `none`
skipped. Pod alerts get the pod's top-level owner, so they group with the
pod's other issues.

## Frontend

| Where | What |
|---|---|
| `lib/prometheus/prom_api.dart` | `PromApi` client + models. `PromApi.of(api)` shares one per backend; `cachedStatus()` / `hasPrometheus()` cache discovery for a minute |
| `lib/prometheus/metric_history_chart.dart` | `MetricHistorySection`, `MetricHistoryChart`, `AreaChart` (custom painter with hover readout), and the one-line `podHistory(ctx)` / `nodeHistory(ctx)` / `workloadHistory(ctx)` / `pvcHistory(ctx)` |
| `lib/ui/alerts/` | the Alerts page, the Silence… dialog (via `confirmAction`), the Silences tab and the nav badge |
| `lib/panels/prometheus/` | PrometheusRule, ServiceMonitor/PodMonitor and Prometheus/Alertmanager panels |

History queries (rate window = max(2m, 4 × step), ~240 points):

- pod CPU: `sum(rate(container_cpu_usage_seconds_total{namespace,pod,container!="",container!="POD"}[w]))`,
  per container with `sum by (container)`
- pod memory: `sum(container_memory_working_set_bytes{...})`
- node CPU: `sum(rate(node_cpu_seconds_total{mode!~"idle|iowait|steal"}[w]) * on(instance) group_left(nodename) node_uname_info{nodename="<node>"})`
- node memory: `node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes`, joined the same way
- pod network: `sum(max by (interface) (rate(container_network_{receive,transmit}_bytes_total{namespace,pod,interface!="lo"}[w])))`.
  These series carry no real container label (the sandbox reports them as
  `container=""`/`"POD"`, some runtimes repeat them per container), so the
  max per interface counts each NIC once. The two directions come back as one
  query (`label_replace(...) or label_replace(...)`, label `direction`)
- node network: `node_network_{receive,transmit}_bytes_total{device!~"lo|veth.*|cali.*|flannel.*|cni.*|docker.*|br-.*|virbr.*|vxlan.*|tunl.*|kube-ipvs.*|cilium.*|lxc.*|genev.*|nodelocaldns.*"}`,
  joined on nodename like CPU (virtual devices would double count traffic)
- workloads: the per-pod series above, summed over the workload's pods,
  matched by owner via kube-state-metrics (`* on (namespace, pod)
  group_left() max by (namespace, pod) (kube_pod_owner{owner_kind=...})`;
  Deployments via their ReplicaSets, `owner_name=~"<name>-[a-z0-9]+"`) `or`,
  without kube-state-metrics, by the controller's pod-name pattern
- PVC: `max by (namespace, persistentvolumeclaim) (kubelet_volume_stats_{used,capacity,available}_bytes / _inodes / _inodes_used)`;
  days to full = available / `deriv(kubelet_volume_stats_used_bytes[6h])`
  (shown when growing and under 30 days)

The charts render nothing when no reachable Prometheus is discovered.

## Dev cluster setup

kube-prometheus-stack **92.17.1** (operator v0.94.2, Prometheus 3.15.1,
Alertmanager 0.34.2) in `monitoring`, release `kube-prometheus-stack`:

    helm upgrade --install kube-prometheus-stack kube-prometheus-stack \
      --repo https://prometheus-community.github.io/helm-charts --version 92.17.1 \
      -n monitoring --create-namespace -f dev/prometheus/values-kind.yaml
    kubectl apply -f dev/prometheus/demo-rules.yaml -f dev/prometheus/demo-monitors.yaml

`values-kind.yaml` disables the etcd / controller-manager / scheduler /
kube-proxy targets (kind binds them to localhost), keeps resources and
retention small, enables Grafana, and makes Prometheus select rules and
monitors from every namespace (`*SelectorNilUsesHelmValues: false`).

`demo-rules.yaml` (PrometheusRule `demo/k8sman-demo`): `K8smanTestAlert`
(`vector(1)`, for 1m, warning) and `K8smanDemoPodCrashLooping` (critical, for
the crashlooping `demo/crashy`), both with summary, description and
`runbook_url`, plus a recording rule. `demo-monitors.yaml`: a ServiceMonitor
for `demo/web` (nginx has no `/metrics`, so its targets are realistically
down) and a PodMonitor scraping Grafana (healthy).

## Fixtures

`frontend/test/prometheus/fixtures/*.json` are captured from a backend
running against that setup (`/api/prom/*` responses and the CRs), e.g.

    curl -sG 127.0.0.1:7443/api/prom/rules -d namespace=demo -d name=k8sman-demo | jq .

Tests serve them through `FixturePromApi` (`test/prometheus/prom_fixtures.dart`),
either as an `AlertsView(source:)` or via `PromApi.debugOverride` for panels.
