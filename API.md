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

## Helm

Helm v3 releases through the Helm SDK (`helm.sh/helm/v3` v3.18.6, `backend/internal/helm`), on the active kube context and with the same credentials as the rest of the API. Release state is read from and written to the Secrets storage driver (Helm's default), so everything here interoperates with the `helm` CLI. Mutations are refused (403) with `--read-only`. The Dart client is `frontend/lib/ui/helm/helm_api.dart`.

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/helm/releases[?namespace=]` | latest revision of every release, in every state: `{releases:[{name, namespace, revision, status, chart, chartVersion, appVersion, updated, description}], total, failed, pending}` |
| GET | `/api/helm/release?namespace=&name=[&revision=]` | one revision (default latest): the summary fields plus `{latestRevision, firstDeployed, lastDeployed, notes, chartInfo:{name, version, appVersion, description, home, sources, icon, apiVersion, type, keywords, kubeVersion, deprecated, dependencies:[{name, version, repository, condition, alias, embedded}]}, values, computedValues, manifest, hooks:[{name, kind, group, path, events, weight, deletePolicies, phase, startedAt, completedAt, manifest}], resources:[{group, version, kind, name, namespace?}], stuck?, upgradeBlocked?}`. `values` (user-supplied) and `computedValues` (chart defaults merged with them) are YAML strings. `resources` are the objects in the manifest |
| GET | `/api/helm/history?namespace=&name=` | `{history:[summary...]}`, newest first |
| GET | `/api/helm/diff?namespace=&name=&from=[&to=]` | `{name, namespace, from:{revision, status, chart, manifest, values}, to:{...}}`. `to` defaults to the latest revision and `from` to the one before `to`. Returns both texts; the client diffs them |
| POST | `/api/helm/rollback` | `{namespace, name, revision (0 = previous), dryRun?, wait?, timeoutSeconds?}` |
| POST | `/api/helm/uninstall` | `{namespace, name, keepHistory?, dryRun?}` |
| POST | `/api/helm/upgrade` | `{namespace, name, values (YAML), reuseValues? (default false: values replace the user values), dryRun?, wait?, timeoutSeconds?}`. Re-renders **the chart stored in the release** (no repository fetch). Returns `manifest` (rendered) and `currentManifest`, so a dry run can be diffed before applying |
| POST | `/api/helm/install` | `{namespace, releaseName, repo, chart, version?, values (YAML), createNamespace? (default true), wait?, timeoutSeconds?, dryRun?}`. `repo` is an https Helm repository URL (resolved through its index; no `helm repo add` needed) or an `oci://` reference, either the registry path (`oci://ghcr.io/org/charts` + `chart`) or the full chart reference (`oci://docker.io/envoyproxy/gateway-helm`). `version` empty = latest. Downloaded charts and indexes are cached in `~/.cache/k8sman/helm`; registry credentials come from Helm's usual `registry/config.json`. A dry run returns the rendered `manifest` and `notes` |
| GET | `/api/helm/chart-versions?repo=&chart=` | `{versions:[{version, appVersion?, created?, description?, deprecated?, prerelease?}]}`, newest first. https repos read the index (cached 10 minutes); OCI lists the registry's semver tags (best effort, version only) |

Every mutation returns `{message, dryRun, context, release?: summary, manifest?, currentManifest?, notes?}`.

Errors:

- **404** `NotFound`: the release or revision doesn't exist.
- **409** `ReleasePending`: the release is **stuck**. Its latest revision is `pending-install`, `pending-upgrade` or `pending-rollback` because an earlier operation was interrupted, and Helm refuses upgrades until that's resolved. The body includes `stuck: {name, status, revision, rollbackTo, remedy}`. The standard remedy is `POST /api/helm/rollback {revision: rollbackTo}` (the last deployed revision). When `rollbackTo` is 0 (a first install that never finished), uninstall instead. `GET /api/helm/release` reports the same `stuck` object up front.
- **409** `AlreadyExists`: install with a release name that's in use.
- **422** `Invalid`: bad values YAML, a bad `repo`, or an upgrade that isn't safe from the stored chart. Helm doesn't persist subcharts in the release, so when the current manifest contains resources rendered from subcharts (`# Source: <chart>/charts/...`), re-rendering would delete them. `upgradeBlocked` on the release explains this, and the UI disables "Edit values".
- Upgrades and installs aren't cancelled if the HTTP client disconnects, since cancelling midway is exactly what leaves a release stuck.
