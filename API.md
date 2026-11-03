# k8sman backend API

Local-only HTTP/WebSocket API served by `backend/cmd/k8sman-server` on
`127.0.0.1:7443`. Reads are always available. Edits, actions and starting
port-forwards are refused (403) when the server runs with `--read-only`. The Dart client in
`frontend/lib/api/client.dart` wraps all of these endpoints.

Resource targets use query params `group` (`""` = core), `version` (optional:
the server's preferred version is used if omitted) and `resource` (the plural, e.g. `deployments`).
`namespace` is optional; omit it for all namespaces or cluster-scoped types.

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/health` | `{ok, context, host}` |
| GET | `/api/contexts` | `{current, contexts:[{name,cluster,user,namespace}]}` |
| POST | `/api/contexts/current` | body `{name}`: switch the kube context |
| GET | `/api/resources[?refresh=true]` | discovered listable types `[{group,version,resource,kind,namespaced,verbs,shortNames,categories,custom}]` |
| GET | `/api/namespaces` | `{namespaces:[...], default}` |
| GET | `/api/table` | list rendered through the jq columns: `{resource, columns, isDefaultColumns, resourceVersion, rows:[{uid,name,namespace,resourceVersion,cells,object?}], columnErrors:{idx:msg}}`. Accepts `labelSelector`, `fieldSelector`, `includeObject=true` |
| GET | `/api/items` | raw objects `{items:[...]}`. Accepts `labelSelector` and `fieldSelector`. Use this for related resources |
| GET | `/api/object?name=` | one object as JSON, or YAML with `format=yaml` (managedFields stripped unless `managedFields=true`) |
| GET | `/api/events` | core/v1 Events for an object, newest first. Filter by `uid` (preferred) or `kind`+`name`, plus `namespace` |
| GET/PUT/DELETE | `/api/columns` | read `{columns, isDefault, defaults}`, save `{columns}`, or reset the user's column override |
| POST | `/api/columns/preview[?limit=]` | body `{columns}`: evaluates unsaved columns against live objects and returns a table |
| WS | `/api/watch` | live table: `{type:"SNAPSHOT",table}`, then `{type:"ADDED"/"MODIFIED"/"DELETED",row}`, or `{type:"ERROR",error}`. Re-lists and sends a fresh SNAPSHOT when the watch expires. To watch a single object, use `fieldSelector=metadata.name=X&includeObject=true` |
| WS | `/api/logs` | `namespace`, `pod`, `container`, `tailLines` (default 500, `-1` = all), `previous`, `timestamps`, `sinceSeconds`, `follow` (default true). Sends frames `{line}`, ending with `{eof:true}` or `{error}` |

## Columns

A column is `{name, query, type}`. `query` is a [jq](https://jqlang.org)
expression (evaluated by [gojq](https://github.com/itchyny/gojq)) that runs
against the full object. The first output becomes the cell. Multiple outputs
become a list. `type` is a rendering hint: `string`, `number`, `age`, `status`,
`bool` or `labels`.

Columns resolve in this order:
1. the user override in `~/.config/k8sman/columns.json`
2. the built-ins in `backend/internal/columns/builtin.go`
3. CRD `additionalPrinterColumns`, converted from simple JSONPath to jq
4. Name/Namespace/Age

Overrides are keyed kubectl-style (`pods`, `deployments.apps`,
`widgets.example.k8sman.dev`), so they apply across API versions.

## Mutations

| Method | Path | Purpose |
|---|---|---|
| PUT | `/api/object?name=[&dryRun=true]` | replace an object from a YAML/JSON body (`kubectl edit` semantics). The body must keep `metadata.resourceVersion`, so a stale edit returns 409 `Conflict`. Validation failures return 422 with `causes:[{field,message}]`. Returns `{dryRun, resourceVersion, yaml, context}` |
| GET | `/api/actions` | actions supported for a type: `{actions:[...]}` |
| POST | `/api/actions/{action}?name=` | run an action. Body: `{replicas?, revision?, gracePeriodSeconds?, propagation?, dryRun?}`. Returns `{message, dryRun, context, created?}` |

The actions are:

| Action | Applies to | Effect |
|---|---|---|
| `scale` | Deployments, StatefulSets, ReplicaSets, and CRs with a scale subresource | `{replicas}` |
| `restart` | Deployments, StatefulSets, DaemonSets | stamps the pod template with `restartedAt`, like `kubectl rollout restart` |
| `pause` / `resume` | Deployments | pauses or resumes the rollout |
| `rollback` | Deployments | `{revision}` (0 = previous), like `kubectl rollout undo` |
| `suspend` / `unsuspend` | Jobs, CronJobs | sets `spec.suspend` |
| `trigger` | CronJobs | creates a Job now; `created` points at it |
| `cordon` / `uncordon` | Nodes | sets `spec.unschedulable` |
| `delete` | anything with the delete verb | deletes the object |

## Port-forwards

Forwards are persisted to `~/.config/k8sman/portforwards.json` and supervised.
Each one resolves to a ready pod (for services: the selector, with
`targetPort` mapped like kubectl does; for workloads: their selector). It watches
that pod and reconnects to a fresh pod with backoff if the pod or stream dies.
Forwards with `autoStart` start when the backend launches.

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/portforwards` | `{forwards:[{id, context, namespace, kind, name, port, localPort, address, autoStart, label, state, pod, remotePort, error, since, reconnects, connections, url}]}`. `state` is `stopped`, `starting`, `active`, `reconnecting` or `error` |
| POST | `/api/portforwards` | create: `{namespace, kind: pod/service/deployment/statefulset/daemonset/replicaset, name, port (number or name), localPort (0 = auto), autoStart, label}` |
| PATCH | `/api/portforwards/{id}` | `{autoStart?, label?, localPort?}` |
| POST | `/api/portforwards/{id}/start`, `/api/portforwards/{id}/stop` | start or stop a forward |
| DELETE | `/api/portforwards/{id}` | stop and forget a forward |

## Health overview

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/overview[?namespace=]` | cluster health summary for one namespace, or all if omitted. Lists pods, deployments, statefulsets, daemonsets, replicasets, jobs, cronjobs, nodes, PVCs and Warning events once each, in parallel, and analyses them (`backend/internal/overview`) |

Response:

```
{generatedAt, namespace,
 counts: {pods: {total, running, ready, pending, crashLoop, imagePull, createContainerConfigError, oomKilled,
                 failed, terminating, stuckTerminating, stuckPending, notReady, highRestarts, completed, initBlocked},
          deployments: {total, healthy, unavailable, progressDeadlineExceeded, paused, rolling},
          statefulSets / daemonSets: {total, healthy, notReady},
          jobs: {total, running, succeeded, failed, longRunning, suspended},
          cronJobs: {total, suspended, failing, overdue},
          nodes: {total, ready, notReady, pressure, cordoned},
          pvcs: {total, bound, pending, lost}},
 categories: [{id, label, section, severity, count}],   // only categories with issues, most severe first
 issues: [{severity, category, kind, group, namespace?, name, reason, message, since?, count?, owner?: {group, kind, name}}],
 nodes: [{name, ready, cordoned, pressure?, roles?, version, pods}],
 topWarnings: [{reason, count, objects, latestMessage, lastSeen, example: {kind, group, namespace?, name}}],
 errors?: {"<resource>": "<message>"}}                  // lists that failed (e.g. RBAC); pods failing is a hard error
```

- `severity` is `critical`, `warning` or `info`. Issues are sorted by severity, then by most recent `since` (RFC3339).
- `owner` is the pod's top-level controller: Pod → ReplicaSet → Deployment, Pod → Job → CronJob, or a StatefulSet/DaemonSet. Group issues by `(namespace, owner, category)` to show "3 pods of Deployment web are CrashLoopBackOff".
- Pod `reason` is the pod table's Status column (`Terminating`, `Init:<reason>`, the first container waiting/terminated reason, else the phase). `count` is the pod's restart count.
- Categories: pods `crashLoop` (including a container that just exited non-zero and is restarting), `imagePull` (ImagePullBackOff, ErrImagePull, InvalidImageName), `createContainerConfigError` (also CreateContainerError and RunContainerError), `initBlocked` (failing init container, or still initializing after 5m), `oomKilled` (OOMKilled within the last hour), `podFailed`, `stuckPending` (Pending for more than 5m; reason from the PodScheduled condition, e.g. Unschedulable), `stuckTerminating` (deletionTimestamp more than 5m old), `notReady` (Running but not ready for more than 5m), `highRestarts` (5 or more restarts); workloads `deploymentUnavailable`, `progressDeadlineExceeded`, `rolling`, `deploymentPaused`, `statefulSetNotReady`, `daemonSetNotReady`; jobs `jobFailed`, `jobLongRunning` (active for more than 1h), `jobSuspended`, `cronJobFailing` (latest job failed), `cronJobOverdue` (next run per the schedule is more than 2m, or startingDeadlineSeconds, in the past), `cronJobSuspended`; nodes `nodeNotReady`, `nodePressure`, `nodeCordoned`; storage `pvcPending` (more than 5m), `pvcLost`.
- `topWarnings` groups Warning events seen in the last hour by reason (top 10 by count).

## Prometheus stack

Prometheus and Alertmanager are discovered through the Prometheus Operator
CRDs (or well-known Service names without them) and reached through the API
server's service proxy, so no port-forward is needed. Details, discovery
rules and limits: [docs/PROMETHEUS.md](docs/PROMETHEUS.md). Every endpoint
takes an optional `instance=<namespace>/<name>`; the default is the first
reachable instance (preferring the `monitoring` namespace). When no instance
of the needed kind exists the answer is 404 with `reason: "NotFound"`.

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/prom/status[?refresh=true]` | `{prometheus:[Instance], alertmanager:[Instance], operatorCRDs, checkedAt, errors?}`. Instance: `{id, kind, namespace, name, source: crd/service, service, port, scheme, pathPrefix?, version, replicas?, availableReplicas?, reachable, error?, default, externalUrl?}`. Cached for 30s |
| GET | `/api/prom/alerts[?instance=&prometheus=]` | Alertmanager v2 alerts plus Prometheus' pending ones, grouped by alertname: `{alertmanager?, prometheus?, summary:{firing, pending, silenced, inhibited, critical}, groups:[{alertname, severity, state, counts:{state:n}, summary, alerts:[Alert]}], errors?}`. Alert: `{fingerprint, alertname, state: firing/pending/silenced/inhibited, severity, labels, annotations, startsAt, endsAt?, generatorURL?, silencedBy?, inhibitedBy?, receivers?, source: alertmanager/prometheus, value?, target?:{group, kind, namespace?, name}}`. Without a reachable Alertmanager, Prometheus' firing alerts are returned instead |
| GET | `/api/prom/silences[?instance=]` | `{alertmanager, silences:[{id, state: active/pending/expired, matchers:[{name, value, isRegex, isEqual}], startsAt, endsAt, createdBy, comment}]}`, active first (soonest to end first) |
| POST | `/api/prom/silences[?instance=]` | body `{matchers, duration: "1h"/"4h"/"1d"/Go duration, startsAt?, endsAt?, comment, createdBy?}` (createdBy defaults to `k8sman`). Needs one positive non-wildcard matcher and a comment; at most 90 days. Returns `{silenceID, alertmanager, startsAt, endsAt}`. 403 when read-only |
| DELETE | `/api/prom/silences/{id}[?instance=]` | expire a silence. 403 when read-only |
| GET | `/api/prom/rules[?namespace=&name=&instance=]` | Prometheus `/api/v1/rules` with live state: `{prometheus, counts:{firing, pending, inactive, errors}, groups:[{name, file, interval, source?:{namespace, name}, rules:[{type: alerting/recording, name, query, duration, labels, annotations, state, health, lastError?, lastEvaluation, alerts?}]}]}`. `source` is the PrometheusRule the group came from; `namespace`/`name` filter on it |
| GET | `/api/prom/targets[?kind=&namespace=&name=&instance=]` | active scrape targets by pool: `{prometheus, up, down, unknown, pools:[{scrapePool, monitor?:{kind, namespace, name, endpoint}, up, down, unknown, targets:[{scrapeUrl, health, lastError?, lastScrape, lastScrapeDuration, scrapeInterval, labels, target?}]}]}`. `kind` (ServiceMonitor/PodMonitor/Probe), `namespace` and `name` filter on the monitor |
| GET | `/api/prom/query?query=[&time=&instance=]` | instant PromQL query: `{resultType, result, series, truncated?, warnings?, prometheus}` (Prometheus' `data.result` format) |
| GET | `/api/prom/query_range?query=[&start=&end=&step=&instance=]` | range query, same shape plus `{start, end, step}`. Times are Unix seconds, RFC3339 or relative (`-1h`); default the last hour at ~240 points. At most 31 days and 1100 points per series (the step is raised to fit) and 500 series. A bad query is 422 with Prometheus' message |

The health overview (`/api/overview`) also lists firing Alertmanager alerts
(not silenced or inhibited) as issues in the categories `alertCritical`,
`alertWarning` and `alertInfo` (section `alerts`), from the alert's
`severity` label: `critical` → critical, `warning` → warning, anything else
→ info, and `none` (Watchdog) skipped. They link to the object their labels
identify (`kind`/`name`, e.g. the pod, with its `owner`), else `kind: "Alert"`
with the alertname. With a namespace filter only alerts labelled with that
namespace are included.
