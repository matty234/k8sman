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
become a list. `type` is a rendering hint: `string`, `number`, `quantity`, `age`, `status`,
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

## Metrics

Reads `metrics.k8s.io`, `custom.metrics.k8s.io` and `external.metrics.k8s.io`
(see [docs/METRICS.md](docs/METRICS.md)). When an API is unusable, data
endpoints return `{error, code, state, group}`: **404** with `state:
"notInstalled"` (no APIService), or **503** with `state: "notReady"`
(registered but not Available, or no samples yet).

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/metrics/status[?refresh=true]` | `{resource, custom, external}`, each `{group, version, versions, apiService, state, available, reason, message, service:{namespace,name}}`. `state` is `available`, `notReady`, `notInstalled` or `unknown` |
| GET | `/api/metrics/nodes` | `{items:[{name, timestamp, window, cpu, memory, cpuMillis, memoryBytes}]}`. `cpu` is millicores (`"12m"`), `memory` bytes. Cached ~10s |
| GET | `/api/metrics/pods?namespace=&labelSelector=` | `{items:[{name, namespace, timestamp, window, cpu, memory, cpuMillis, memoryBytes, containers:[{name, cpu, memory, cpuMillis, memoryBytes}]}]}` (pod totals are the sum of containers) |
| GET | `/api/metrics/custom/discover` | `{version, resources:[{resource, group, namespaced, metrics:[...]}]}` |
| GET | `/api/metrics/custom?group=&resource=&namespace=&name=\|selector=&metric=[&metricSelector=]` | `{items:[{object:{kind,namespace,name,apiVersion}, metric, labels, value, number, timestamp, windowSeconds}]}`. Omit `name` for all objects (`*`), optionally filtered by `selector` |
| GET | `/api/metrics/external/discover[?namespace=]` | `{version, metrics:[{name, namespace?, selector?, source: "discovery"\|"hpa", hpa?}]}`. Includes External metrics referenced by HPAs, since KEDA only advertises a placeholder |
| GET | `/api/metrics/external?namespace=&metric=[&labelSelector=]` | `{items:[{metric, labels, value, number, timestamp, windowSeconds}]}` |
| GET | `/api/metrics/hpa?namespace=&name=` | live evaluation of an HPA's metrics: `{target, selector, currentReplicas, desiredReplicas, minReplicas, maxReplicas, proposed, limitedBy?, metrics:[{index, type, name, container?, selector?, object?, targetType, target, current, utilization?, averageValue?, pods, ratio, proposed, driving, error?}], errors?}` |

**Usage in tables:** `/api/table`, `/api/watch` and `/api/columns/preview` for
`pods` and `nodes` evaluate columns with `.k8sman.usage` merged into a copy of
each object (`{cpu, memory, cpuMillis, memoryBytes}`; pods add `containers`,
`window` and `timestamp`; nodes add `cpuPercent` and `memoryPercent` of
allocatable). It's absent when there's no sample. `row.object` is never
modified. Pod/node watches also re-send changed rows as `MODIFIED` every 15s
as usage changes. The `quantity` column type renders values such as `250m`,
`128Mi` and `42%` right-aligned, sorted by value, with "—" when empty.

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
