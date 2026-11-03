# k8sman backend API

Local-only HTTP/WebSocket API served by `backend/cmd/k8sman-server` on
`127.0.0.1:7443` by default. The macOS app embeds the server and runs it with
`--addr 127.0.0.1:0`; the server prints `K8SMAN_LISTENING <addr>` on stdout
once it listens. Reads are always available. Edits, actions, starting
port-forwards, exec and debug containers are refused (403) when the server runs with `--read-only`. The Dart client in
`frontend/lib/api/client.dart` wraps all of these endpoints.

If no kubeconfig can be loaded at startup the server still runs, disconnected:
cluster endpoints return 503 (`reason: "NoKubeconfig"`), while `/api/health`,
`/api/contexts`, `/api/kubeconfigs*` and `/api/portforwards*` keep working so
the UI can let the user pick a file.

Resource targets use query params `group` (`""` = core), `version` (optional:
the server's preferred version is used if omitted) and `resource` (the plural, e.g. `deployments`).
`namespace` is optional; omit it for all namespaces or cluster-scoped types.

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/health` | `{ok, connected, context, host, kubeconfig, readOnly, error?}` |
| GET | `/api/contexts` | `{current, contexts:[{name,cluster,user,namespace}]}` |
| POST | `/api/contexts/current` | body `{name}`: switch the kube context (remembered per kubeconfig) |
| GET | `/api/kubeconfigs` | `{current, context, home, merged?, candidates:[{path, contexts:[names], currentContext, source, error?}]}`. `current` is the active file (`""` = default rules merging the `merged` $KUBECONFIG files). Candidates: each `$KUBECONFIG` entry, `~/.kube/config`, other files under `~/.kube` that parse as kubeconfig (cache dirs skipped), and recently used files. `source` is `KUBECONFIG`, `default`, `kube-dir` or `recent`. Only paths and context names are returned |
| POST | `/api/kubeconfigs/current` | body `{path}` (absolute or `~/…`): validate the file, make it active and connect to its last used context (else its current-context). Returns the same shape as GET |
| GET | `/api/resources[?refresh=true]` | discovered listable types `[{group,version,resource,kind,namespaced,verbs,shortNames,categories,custom}]` |
| GET | `/api/namespaces` | `{namespaces:[...], default}` |
| GET | `/api/table` | list rendered through the jq columns: `{resource, columns, isDefaultColumns, resourceVersion, rows:[{uid,name,namespace,resourceVersion,cells,object?}], columnErrors:{idx:msg}}`. Accepts `labelSelector`, `fieldSelector`, `includeObject=true` |
| GET | `/api/items` | raw objects `{items:[...]}`. Accepts `labelSelector` and `fieldSelector`. Use this for related resources |
| GET | `/api/object?name=` | one object as JSON, or YAML with `format=yaml` (managedFields stripped unless `managedFields=true`) |
| GET | `/api/events` | core/v1 Events for an object, newest first. Filter by `uid` (preferred) or `kind`+`name`, plus `namespace` |
| GET/PUT/DELETE | `/api/columns` | read `{columns, isDefault, defaults}`, save `{columns}`, or reset the user's column override |
| POST | `/api/columns/preview[?limit=]` | body `{columns}`: evaluates unsaved columns against live objects and returns a table |
| WS | `/api/watch` | live table: `{type:"SNAPSHOT",table}`, then `{type:"ADDED"/"MODIFIED"/"DELETED",row}`, or `{type:"ERROR",error}`. Re-lists and sends a fresh SNAPSHOT when the watch expires. To watch a single object, use `fieldSelector=metadata.name=X&includeObject=true`. With `batch=true` the server may also send `{type:"BATCH",events:[{type,row},…]}`: deltas from a ~75ms window, in order (apply all, then redraw once). See [Shared watches](#shared-watches) |
| WS | `/api/logs` | `namespace`, `pod`, `container`, `tailLines` (default 500, `-1` = all), `previous`, `timestamps`, `sinceSeconds`, `follow` (default true). Sends frames `{line}`, ending with `{eof:true}` or `{error}` |

## Shared watches

The server keeps one upstream LIST+WATCH per resource, namespace and
selector set (per kube context) and shares it between every `/api/watch`
client; a single-object or label-selector watch rides on an already open
watch of the same type and is filtered locally. `/api/table` and
`/api/items` answer from an open watch when there is one (else they LIST),
and `/api/overview` and `/api/security` list through the same cache, so
repeated polls cost no API requests. A watch nobody uses is kept for 90s,
then stopped. Errors are those of the upstream LIST: `Forbidden` and
`NotFound` end the watch (the socket closes after the ERROR frame), other
errors are retried with backoff. A watch that ends normally resumes from
its last resourceVersion; an expired one (410) re-lists and sends a fresh
SNAPSHOT. A client that falls more than 4,096 events behind gets a fresh
SNAPSHOT instead of the backlog. See docs/PERFORMANCE.md.

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
| `argocd-refresh` | Argo CD Applications | annotates `argocd.argoproj.io/refresh: normal`, or `hard` with `{hard: true}` |
| `argocd-sync` | Argo CD Applications | sets `.operation.sync` like the Argo CD API server. Body: `{prune?, syncDryRun?, targetRevision?, syncOptions?, force?}`. 409 when an operation is pending or running unless `force` (which replaces it). `syncDryRun` is Argo's dry run; `dryRun` stays a kube dry run of the patch |
| `argocd-terminate` | Argo CD Applications | sets `status.operationState.phase: Terminating` on a running operation, as `argocd app terminate-op` does |

See `docs/ARGOCD.md` for how these work without the Argo CD API server.

## Terminals (exec)

| Method | Path | Purpose |
|---|---|---|
| WS | `/api/exec` | interactive TTY in a container. Query: `namespace`, `pod`, `container` (default: the `kubectl.kubernetes.io/default-container` annotation, else the first), `command` (repeat the param per argument, or pass one JSON array such as `["redis-cli","-n","1"]`; exec'd as-is), `shell` (`auto` (default), `bash`, `zsh`, ... used when there's no `command`), `cols`/`rows` (initial size) |
| POST | `/api/debug-container` | body `{namespace, pod, targetContainer, image}` (image defaults to `busybox:1.36`). Adds an ephemeral container like `kubectl debug -it pod --image=... --target=...` and waits (up to 3m) until it runs. Returns `{name, image, context}`. A fatal start (ErrImagePull, ...) or timeout returns 504 `DebugContainerNotRunning` |

**Shell selection** happens in one exec: without `command`, the server runs
`/bin/sh -c <script>`. The script sets `TERM=xterm-256color` when it is unset, `dumb` or
the runtime's default `xterm`, then `exec`s the first of `<shell>`, zsh, bash, ash and sh
that `command -v` finds.

**Framing.** Binary frames carry raw terminal bytes both ways: client→server is stdin,
server→client is stdout (the TTY merges stderr). Text frames are JSON control messages:

- client → server: `{type:"resize", cols, rows}`
- server → client: `{type:"started", container, command}`; then exactly one of
  `{type:"exit", code}` or `{type:"error", reason, message, code?}`; then the socket closes.

The `reason` for errors is one of:

- `noShell`: auto mode, and `/bin/sh` is missing (distroless) or exited 126/127 before any output. The UI offers a debug container.
- `commandNotFound`: the same failure for an explicit `command`.
- `podNotFound`, `containerNotFound`, `containerNotRunning` (checked before exec).
- `forbidden`: RBAC.
- `execFailed`: anything else.

Exec uses client-go's WebSocket executor (falling back to SPDY, like kubectl 1.30+).
Stdin and stdout block end to end, so a slow client applies backpressure to the
container. Closing the socket ends the exec; the process exiting closes the socket.

Debug containers are exec'd into (`/api/exec?container=debugger`), not attached.
They are created with `stdin`+`tty` so the image's default shell stays alive, which
means restart and reconnect work and the shell picker applies. They share the
target's process namespace (`/proc/1/root` reaches its filesystem when permissions
allow). Ephemeral containers cannot be removed: they stay until the pod is deleted.
Names are `debugger`, `debugger-2`, and so on.

## Port-forwards

Forwards are persisted to `~/.config/k8sman/portforwards.json` and supervised.
Each one resolves to a ready pod (for services: the selector, with
`targetPort` mapped like kubectl does; for workloads: their selector). It watches
that pod and reconnects to a fresh pod with backoff if the pod or stream dies. Each forward stores the kubeconfig file it was created under (`kubeconfig`, "" = default loading rules), so it keeps working after the app switches kubeconfig.
Forwards with `autoStart` start when the backend launches.

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/portforwards` | `{forwards:[{id, context, kubeconfig, namespace, kind, name, port, localPort, address, autoStart, label, state, pod, remotePort, error, since, reconnects, connections, url}]}`. `state` is `stopped`, `starting`, `active`, `reconnecting` or `error` |
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
| GET | `/api/metrics/summary[?namespace=][&node=a,b]` | kubelet Summary API (via `nodes/<n>/proxy/stats/summary`, needs `get nodes/proxy`), the fallback when there is no Prometheus: `{state: "available"\|"unavailable", message?, nodes, reporting, errors?:{node: msg}, volumes:[{namespace, claim, pod, node, volume, time, usedBytes, capacityBytes, availableBytes, inodes, inodesUsed, inodesFree}], pods:[{namespace, name, node, rxBytes, txBytes, rxBytesPerSec?, txBytesPerSec?, windowSeconds?}], nodeNetwork:[{name, rxBytes, txBytes, rxBytesPerSec?, txBytesPerSec?, windowSeconds?}]}`. All Ready nodes when `node` is omitted. Only mounted PVCs appear. Rates come from two cached samples (~12s apart), so they are absent on the first call. Always 200 |
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
          pvcs: {total, bound, pending, lost},
          gateways?: {total, programmed, problem},              // only when the Gateway API CRDs are served
          routes?: {total, accepted, problem, unresolved}},
 categories: [{id, label, section, severity, count}],   // only categories with issues, most severe first
 issues: [{severity, category, kind, group, namespace?, name, reason, message, since?, count?, owner?: {group, kind, name}}],
 nodes: [{name, ready, cordoned, pressure?, roles?, version, pods}],
 topWarnings: [{reason, count, objects, latestMessage, lastSeen, example: {kind, group, namespace?, name}}],
 errors?: {"<resource>": "<message>"}}                  // lists that failed (e.g. RBAC); pods failing is a hard error
```

- `severity` is `critical`, `warning` or `info`. Issues are sorted by severity, then by most recent `since` (RFC3339).
- `owner` is the pod's top-level controller: Pod → ReplicaSet → Deployment, Pod → Job → CronJob, or a StatefulSet/DaemonSet. Group issues by `(namespace, owner, category)` to show "3 pods of Deployment web are CrashLoopBackOff".
- Pod `reason` is the pod table's Status column (`Terminating`, `Init:<reason>`, the first container waiting/terminated reason, else the phase). `count` is the pod's restart count.
- Categories: pods `crashLoop` (including a container that just exited non-zero and is restarting), `imagePull` (ImagePullBackOff, ErrImagePull, InvalidImageName), `createContainerConfigError` (also CreateContainerError and RunContainerError), `initBlocked` (failing init container, or still initializing after 5m), `oomKilled` (OOMKilled within the last hour), `podFailed`, `stuckPending` (Pending for more than 5m; reason from the PodScheduled condition, e.g. Unschedulable), `stuckTerminating` (deletionTimestamp more than 5m old), `notReady` (Running but not ready for more than 5m), `highRestarts` (5 or more restarts); workloads `deploymentUnavailable`, `progressDeadlineExceeded`, `rolling`, `deploymentPaused`, `statefulSetNotReady`, `daemonSetNotReady`; jobs `jobFailed`, `jobLongRunning` (active for more than 1h), `jobSuspended`, `cronJobFailing` (latest job failed), `cronJobOverdue` (next run per the schedule is more than 2m, or startingDeadlineSeconds, in the past), `cronJobSuspended`; nodes `nodeNotReady`, `nodePressure`, `nodeCordoned`; storage `pvcPending` (more than 5m), `pvcLost`; Argo CD (section `argocd`, only when the Application CRD is served; apps in, or deploying to, the selected namespace) `argoSyncFailed` (last operation Failed/Error or an `*Error` condition, critical), `argoDegraded` (critical), `argoMissing` (warning), `argoOutOfSync` (warning). Each app is reported once, in its worst category, and `counts.argoApps` is `{total, synced, outOfSync, healthy, degraded, missing, failed}`; network (Gateway API, when served; see `docs/GATEWAY_API.md`) `gatewayNotReady` (not Accepted/Programmed), `gatewayListener` (listener Conflicted or ResolvedRefs/Accepted/Programmed False), `routeNotAccepted` (critical when no parent accepts the route, else warning), `routeUnresolvedRefs`.
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
| POST | `/api/helm/upgrade` | `{namespace, name, values (YAML), reuseValues? (default false: values replace the user values), repo?, chart?, version?, dryRun?, wait?, timeoutSeconds?}`. Re-renders **the chart stored in the release** (no repository fetch), unless `repo` + `chart` (+ `version`, empty = latest) are given: then that chart is fetched exactly like install does (also allowed for releases whose stored chart is `upgradeBlocked`). Returns `manifest` (rendered) and `currentManifest`, so a dry run can be diffed before applying |
| POST | `/api/helm/install` | `{namespace, releaseName, repo, chart, version?, values (YAML), createNamespace? (default true), wait?, timeoutSeconds?, dryRun?}`. `repo` is an https Helm repository URL (resolved through its index; no `helm repo add` needed) or an `oci://` reference, either the registry path (`oci://ghcr.io/org/charts` + `chart`) or the full chart reference (`oci://docker.io/envoyproxy/gateway-helm`). `version` empty = latest. Downloaded charts and indexes are cached in `~/.cache/k8sman/helm`; registry credentials come from Helm's usual `registry/config.json`. A dry run returns the rendered `manifest` and `notes` |
| GET | `/api/helm/chart-versions?repo=&chart=` | `{versions:[{version, appVersion?, created?, description?, deprecated?, prerelease?}]}`, newest first. https repos read the index (cached 10 minutes); OCI lists the registry's semver tags (best effort, version only) |

Every mutation returns `{message, dryRun, context, release?: summary, manifest?, currentManifest?, notes?}`.

Errors:

- **404** `NotFound`: the release or revision doesn't exist.
- **409** `ReleasePending`: the release is **stuck**. Its latest revision is `pending-install`, `pending-upgrade` or `pending-rollback` because an earlier operation was interrupted, and Helm refuses upgrades until that's resolved. The body includes `stuck: {name, status, revision, rollbackTo, remedy}`. The standard remedy is `POST /api/helm/rollback {revision: rollbackTo}` (the last deployed revision). When `rollbackTo` is 0 (a first install that never finished), uninstall instead. `GET /api/helm/release` reports the same `stuck` object up front.
- **409** `AlreadyExists`: install with a release name that's in use.
- **422** `Invalid`: bad values YAML, a bad `repo`, or an upgrade that isn't safe from the stored chart. Helm doesn't persist subcharts in the release, so when the current manifest contains resources rendered from subcharts (`# Source: <chart>/charts/...`), re-rendering would delete them. `upgradeBlocked` on the release explains this, and the UI disables "Edit values".
- Upgrades and installs aren't cancelled if the HTTP client disconnects, since cancelling midway is exactly what leaves a release stuck.

## Security overview

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/security[?namespace=&includeSystem=true]` | security findings for one namespace, or all if omitted. Lists namespaces, pods, workloads, services, ServiceAccounts, ingresses, NetworkPolicies, RBAC (always cluster-wide), Gateway API Gateways/HTTPRoutes and Trivy Operator reports (when those CRDs exist) once each, in parallel, and analyses them (`backend/internal/security`). `includeSystem` includes kube-system & co. and Kubernetes' default `system:` RBAC |
| GET | `/api/security/scanner` | `{operator: {installed, reports:[...], hasReports, scanning}, trivy: {available, path?, version?, hint?}, installHint}`. `scanning` = the operator is installed but no VulnerabilityReport exists yet |
| POST | `/api/security/scan` | body `{image, force?}`: scans the image with the local `trivy` CLI (`trivy image --format json --quiet --scanners vuln`, 5 min timeout) and caches the result for 1h. Returns `{image, scannedAt, duration, cached, os, counts, vulnerabilities:[CVE] (most severe first, max 300), total}`. 503 `ScannerUnavailable` without trivy, 400 for an invalid image reference, 502 `ScanFailed` if trivy fails |

Response of `GET /api/security`:

```
{generatedAt, namespace, includeSystem, score,             // score: 100·100/(100+Σweights), critical 10, high 4, medium 1.5, low 0.3
 categories: [{id: network|rbac|workloads|images|practices, title, total, counts: {critical, high, medium, low, info}}],
 findings: [{id, check, severity: critical|high|medium|low|info, category, title, detail, remediation,
             namespace?, objects: [{group, kind, name, namespace?}], checks?: ["baseline: privileged (shell)", ...]}],
 permissive: [{binding, role, roleMissing?, scope: "cluster"|<namespace>, subjects: [{kind, name, namespace?, exists?, used?}],
               score, reasons: [...], unused, system}],          // top 60 by risk score
 network: [{namespace, policies, workloads, ingress, egress, ingressOpen, egressOpen, exposed, psa?}],
                                                                 // ingress/egress: open | partial | restricted | default-deny
 images: [{image, workloads: [ref], scanned, source?: trivy-operator|trivy-cli, scannedAt?,
           counts: {critical, high, medium, low, unknown, fixableCritical, fixableHigh}, topCVEs: [CVE]}],
 topCVEs: [CVE],                                                 // CVE: {id, severity, package, installed, fixed?, title, link?, score, images?}
 sources: {trivyOperator, gatewayAPI, reports: {"<resource>": n}},
 errors?: {"<resource>": "<message>"}}                           // lists that failed; pods failing is a hard error
```

- Findings are sorted by severity, then category. Workload findings are per top-level owner (Pod → ReplicaSet → Deployment, Pod → Job → CronJob), and best-practice findings are grouped per namespace, so 40 identical pods are one row. `check` is the stable check id; see `docs/SECURITY.md` for the full list and severities.
- Images scanned on demand (still in the 1h cache) are merged into `images` with `source: "trivy-cli"`.

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

## Argo CD API (per-resource diffs)

Optional: talks to the Argo CD API server (`argocd-server`) through the API
server's service proxy (https, or http when `argocd-cmd-params-cm` sets
`server.insecure`; `server.rootpath` is honoured). The Service is found by the
label `app.kubernetes.io/name=argocd-server` in the app's namespace, then
cluster-wide, then in `argocd`. The Argo token goes as the `argocd.token`
cookie, because the API server strips `Authorization`. Tokens are never
returned or logged. None of these endpoints writes to the cluster, so they
also work with `--read-only`. Details: [docs/ARGOCD.md](docs/ARGOCD.md).

Errors carry a `reason`: `NotFound` (no argocd-server), `Unreachable`,
`NoToken` (401, connect first), `Unauthorized` (401, Argo rejected the token
or session), `Forbidden` (403, Argo RBAC), `NoInitialAdmin`, or `Kube<Reason>`
for errors from the Kubernetes API itself (such as a forbidden `services/proxy`).

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/argocd/status[?namespace=&refresh=1]` | `{context, found, reachable, server?:{namespace, service, port, scheme, rootPath?, version}, auth: none/configured/session, authValid?, username?, initialAdminAvailable, error?}`. `namespace` is the Application's. Checks the token with `/api/v1/session/userinfo`. Discovery is cached for 30s (10s on failure) |
| POST | `/api/argocd/auth` | body `{token, context?, namespace?}` (context defaults to the current one; a pasted `Bearer ` prefix is dropped). Saves the token per kube context in `~/.config/k8sman/settings.json` (mode 0600) and drops any session. A token Argo rejects is not saved (401). Returns the status |
| DELETE | `/api/argocd/auth[?context=&namespace=]` | forget the saved token and the session for the context. Returns the status |
| POST | `/api/argocd/auth/initial-admin` | body `{namespace?}`. Opt-in only (the UI asks first): reads the password from `<argo ns>/argocd-initial-admin-secret` with your kube RBAC, `POST /api/v1/session` as `admin`, and keeps the session token in memory for this context. The password is never stored. 404/403 `NoInitialAdmin` when the Secret is missing or unreadable, 401 when the password was changed. A session takes precedence over a saved token until it is cleared or expires |
| GET | `/api/argocd/diff?name=[&namespace=]` | Argo's `GET /api/v1/applications/{name}/managed-resources?appNamespace=`, converted: `{resources:[{group, kind, namespace?, name, status: Synced/OutOfSync, hook, requiresPruning, target: yaml/null, live: yaml/null}], server, auth}`. Out-of-sync resources come first. It compares `normalizedLiveState` with `predictedLiveState` when Argo predicted one (the diff the Argo UI shows), else `liveState` with `targetState`. Removed noise: `status`, `metadata.managedFields`, `resourceVersion`, `uid`, `generation`, `creationTimestamp`, `selfLink`, and the annotations `kubectl.kubernetes.io/last-applied-configuration` and `deployment.kubernetes.io/revision`. A null `target` means "to be pruned" and a null `live` means "to be created". Secret data arrives masked by Argo |

## CRD group icons

Icons for custom resource API groups (`argoproj.io`, `cert-manager.io`, …), from
`backend/internal/icons`. Resolution order:

1. **Helm chart icon** (`source: "helm"`): the `icon` URL in the chart metadata of the
   deployed Helm release behind the group. Releases are read straight from their
   `helm.sh/release.v1` Secrets (base64 → gzip → JSON; no Helm SDK). A group is attributed to
   a release by, in order: the CRD's `meta.helm.sh/release-name`/`-namespace` annotations (or
   `app.kubernetes.io/managed-by: Helm` + `app.kubernetes.io/instance` labels); the chart
   shipping the CRD in its `crds/` directory (Helm doesn't label those); or a Helm-managed
   ClusterRole that grants write access to the group (the release running the group's
   controller, e.g. kube-prometheus-stack's operator for `monitoring.coreos.com`). Kubernetes
   project groups (`*.k8s.io`, `*.x-k8s.io`) are only attributed through the CRD's own
   annotations, never through other charts that vendor them. Attribution is cached per
   cluster for 10 minutes; any step lacking RBAC is skipped.
2. **Bundled** (`source: "bundled"`, `asset`): a curated icon shipped with the app in
   `frontend/assets/icons/<asset>.png` (see `ATTRIBUTION.md` there). The group matches a
   curated domain or is a subdomain of it.
3. **Favicon** (`source: "favicon"`): fetched directly from the group's own domain (never via
   a third-party favicon service). Candidates are the group, its parent and its registrable
   domain (`monitoring.coreos.com` → `monitoring.coreos.com`, `coreos.com`); public-suffix
   hosts stop at the owner's site (`aquasecurity.github.io`, never `github.io`). Reserved and
   in-cluster names (`.local`, `.svc`, `.internal`, `example.com`, …) are never fetched. The
   home page's `<link rel="icon" | "shortcut icon" | "apple-touch-icon">` entries are tried
   largest first (one `<meta http-equiv=refresh>` hop is followed), then `/favicon.ico`.
   A site that lands on a shared platform (github.com, gitlab.com, …) is rejected, since that
   icon is the platform's, not the project's.
4. **None** (`source: "none"`): the UI draws a monogram (first letter on a colour hashed from
   the group). No network call.

Fetch rules: https only (redirects to http are refused), 6 s per request, 15 s per lookup,
256 KB per download, image content types only, and no connections to private, loopback or
link-local addresses. Images are normalised to PNG of at most 128 px (`.ico` files are
decoded, PNG or BMP entries; WebP passes through). SVG icons are skipped because the UI
can't render them. Results, including misses, are cached in `~/.cache/k8sman/icons/`
(`--icon-cache`): icons for 7 days, misses for 12 hours.

**Privacy.** Remote fetches (chart icon URLs and favicons) reveal the group's domain to that
website and to DNS. They are:

- off with `--no-remote-icons`;
- otherwise set by `"remoteIcons": true | false` in `~/.config/k8sman/settings.json`;
- otherwise automatic: on only when the current context looks local (kind-, k3d-,
  minikube, docker-desktop, rancher-desktop, orbstack, colima or microk8s contexts, or a
  loopback API server).

With remote fetches off, icons already in the cache are still served; nothing new is fetched.
Bundled icons and monograms always work.

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/icons` | `{"<group>": {source, url?, asset?, release?}}` for every custom (CRD) group on the cluster. `release` is the Helm release as `namespace/name` |
| GET | `/api/icons/{group}` | the icon image (`Content-Type: image/png` or `image/webp`, header `X-Icon-Source: helm|favicon`). For bundled and missing icons: 404 `{error, code, source, asset?}` with `X-Icon-Source: bundled|none`. 400 for an invalid group name |
