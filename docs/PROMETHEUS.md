# Prometheus stack support

k8sman treats the Prometheus stack (Prometheus Operator, Prometheus,
Alertmanager) as a first-class part of the cluster:

- an **Alerts** page (nav, under Overview) with Alertmanager's alerts grouped
  by alertname, filters, silencing and a Silences tab; the nav item shows a
  count of firing critical alerts
- firing alerts as **issues on the Overview**, linked to the affected object
- a **Monitoring tab** on Pods, Services and workloads: is it scraped, by
  which ServiceMonitor / PodMonitor / scrape config, and if not, why; the
  alerts about it and the rules that seem to apply
- detail panels for **PrometheusRule** (with live rule state),
  **ServiceMonitor / PodMonitor / Probe / ScrapeConfig** (matching objects,
  which Prometheus picks them up, live target health), the **Prometheus**
  custom resource (what it selects, target health by pool), the
  **Alertmanager** custom resource (the running routing tree, receivers,
  inhibit rules, alerts by receiver, silences) and **AlertmanagerConfig**
  (route tree, receivers, which Alertmanagers load it and the alerts it
  applies to)
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

#### Manual address

For setups discovery doesn't recognise (Grafana Mimir, Thanos query-frontend,
VictoriaMetrics, anything serving the Prometheus API under a path such as
`/prometheus`), Settings > Integrations > Prometheus takes a Service per
kube context (`moduleSettings.prometheus`):

    {"prometheus":   {"namespace": "mimir", "service": "mimir-query-frontend", "port": "8080", "pathPrefix": "/prometheus"},
     "alertmanager": {"namespace": "...", "service": "...", "port": "9093", "pathPrefix": "..."},
     "defaultRange": "1h"}

`port` is a number or name (default 9090 / 9093). `pathPrefix` is added to
every request (query, query_range, alerts, rules, targets, silences) where the
proxy URL is built (`Instance.ProxyPath`). A manual instance has `source:
"settings"`, leads its list and is the default; discovered instances stay
listed. It is probed with buildinfo (`<prefix>/api/v1/status/buildinfo`),
falling back to `<prefix>/api/v1/query?query=vector(1)` because Mimir may not
serve buildinfo. Settings > Integrations shows whether it answers. With both
endpoints empty discovery is unchanged. `defaultRange` (`10m`, `15m`, `1h`,
`6h`, `1d`, `1w`) is the history charts' first range; picking another on a
chart changes only that view for the session. Long ranges keep about 240
points (1w = 42m step), and the Overview chart refreshes every 10m on 1w.

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

Answers the inspector asks for on every object it opens (targets, dropped
targets, rules, alerts, Alertmanager status) are cached per kube context and
instance for 10-30s (`cache.go`), so stepping through pods costs one
`/api/v1/targets`. Results are filtered and capped in the backend (200
targets, 100 alerts and rules per object), so the UI stays fast on
Prometheus servers with thousands of targets.

### An object's monitoring (`scrape.go`, `applies.go`, `selectors.go`)

`GET /api/prom/scrape?kind=&namespace=&name=` resolves the object to pods
(a workload's pods by its selector, a Service's by its selector, at most
500) and the Services in front of them, then:

- **targets**: active targets whose discovered `__meta_kubernetes_namespace`
  / `__meta_kubernetes_pod_name` (else the `namespace` / `pod` labels) name
  one of the pods; for a Service also its endpoints. Each carries its job
  and the monitor behind its scrape pool (`serviceMonitor/<ns>/<name>/<i>`,
  `podMonitor/`, `probe/`, `scrapeConfig/`; other pools are plain scrape
  configs, shown by job).
- **monitors**: every ServiceMonitor (against each Service of the object)
  and PodMonitor (against the pod or pod template) is checked:
  `namespace` (its namespaceSelector: `any`, `matchNames`, else its own),
  `selector` (failing terms are listed, e.g. `release=prod (has dev)`),
  `port` (endpoint `port` names a Service port / container port;
  `targetPort` and `portNumber` too) and `prometheus` (a Prometheus CR's
  `<kind>Selector` and `<kind>NamespaceSelector`: missing selector = none,
  `{}` = all; missing namespace selector = the CR's own namespace). Monitors
  that match, scrape, or come close (selector passes or shares a label, in
  a namespace they watch) are returned, best first, at most 12.
- **dropped**: `/api/v1/targets?state=dropped` entries for the object, from
  pools that don't also scrape it, and only for monitors whose selector
  picks it (or plain scrape configs). These are "discovered, then dropped by
  relabelling", usually a port name.
- **hints**: no pods, no Service in front, no named container ports, a
  `prometheus.io/scrape` annotation the operator ignores, and how many other
  monitors watch the namespace.

`GET /api/prom/applies` returns the alerts (Alertmanager's plus pending)
whose labels name the object (its workload label, e.g. `deployment`, a pod,
its Service, or one of its jobs, in its namespace) and, as a heuristic,
rules with an active alert for it or a positive matcher (`=`/`=~`, not
`.*`) on its job, namespace, Service or name. Each rule says why it was
picked and links its PrometheusRule (file name, see below).

### Alertmanager config (`amconfig.go`)

`GET /api/prom/alertmanager` reads `/api/v2/status` and parses
`config.original` into the routing tree (matchers, legacy `match`/`match_re`
as `name="v"`/`name=~"v"`, grouping and timings), receivers (notifier kinds
and counts only), inhibit rules and time intervals. Routes and receivers
from an AlertmanagerConfig (`<namespace>/<name>/<receiver>`) link to it. The
YAML it returns is redacted (`Redact`): values under keys that look like
credentials (password, secret, token, `*_key`, api_key, credentials,
authorization, `*_api_url`), every HTTP header value, `Bearer`/`Basic`
strings, and the path, query and user info of every URL (webhook URLs carry
tokens). `*_file` paths are kept. The generated config Secret is never read.

`GET /api/prom/selection` (Prometheus / Alertmanager CR: what it selects,
with a Prometheus' target health by pool) and `GET /api/prom/selectedby`
(monitor, rule, Probe, ScrapeConfig or AlertmanagerConfig: which CRs pick it
up, and the selector that stops the others; for AlertmanagerConfigs the
Alertmanager's `alertmanagerConfigMatcherStrategy`) evaluate the same
selectors.

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
| `lib/panels/prometheus/` | PrometheusRule, ServiceMonitor/PodMonitor, Probe/ScrapeConfig, Prometheus/Alertmanager (live sections in `instance_live.dart`) and AlertmanagerConfig panels |
| `lib/prometheus/monitoring_tab.dart` | the Monitoring tab on Pods, Services and workloads, added by the Prometheus module (`inspectorTabs`) once discovery finds Prometheus or Alertmanager: Scraping (targets by pool under their monitor, or "Not scraped" with hints), Monitors / "Why it isn't scraped" (each check), Alerts, and "Rules that may apply" |

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
- node network: `node_network_{receive,transmit}_bytes_total` without
  virtual devices (`nodeVirtualDevices`: loopback, veth/lxc, CNI bridges,
  tunnels such as vxlan/tunl/sit/ip6tnl/gre, dummy/teql/ifb/nlmon, and VLAN
  sub-interfaces `.+[.].+`), joined on nodename like CPU. They would double
  count traffic already on the NIC. On a node with an up bond
  (`node_network_up{device=~"bond.*"} == 1`) only `bond*` devices count,
  since node-exporter doesn't say which NICs are its slaves (other
  non-bonded NICs on such a node are then left out)
- hostNetwork pods report their node's counters, so the Pod panel and
  workloads with `hostNetwork: true` show no network chart (the pod panel
  links to the node instead), and the Metrics → Network top pods drop them
  (`unless on (namespace, pod) kube_pod_info{host_network="true"}`, plus a
  pod-spec filter when kube-state-metrics is absent)
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

    curl -sG -H "Authorization: Bearer $(cat ~/.config/k8sman/dev-token)" \
      127.0.0.1:7443/api/prom/rules -d namespace=demo -d name=k8sman-demo | jq .

Tests serve them through `FixturePromApi` (`test/prometheus/prom_fixtures.dart`),
either as an `AlertsView(source:)` or via `PromApi.debugOverride` for panels.
