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
- Categories: pods `crashLoop` (including a container that just exited non-zero and is restarting), `imagePull` (ImagePullBackOff, ErrImagePull, InvalidImageName), `createContainerConfigError` (also CreateContainerError and RunContainerError), `initBlocked` (failing init container, or still initializing after 5m), `oomKilled` (OOMKilled within the last hour), `podFailed`, `stuckPending` (Pending for more than 5m; reason from the PodScheduled condition, e.g. Unschedulable), `stuckTerminating` (deletionTimestamp more than 5m old), `notReady` (Running but not ready for more than 5m), `highRestarts` (5 or more restarts); workloads `deploymentUnavailable`, `progressDeadlineExceeded`, `rolling`, `deploymentPaused`, `statefulSetNotReady`, `daemonSetNotReady`; jobs `jobFailed`, `jobLongRunning` (active for more than 1h), `jobSuspended`, `cronJobFailing` (latest job failed), `cronJobOverdue` (next run per the schedule is more than 2m, or startingDeadlineSeconds, in the past), `cronJobSuspended`; nodes `nodeNotReady`, `nodePressure`, `nodeCordoned`; storage `pvcPending` (more than 5m), `pvcLost`; Argo CD (section `argocd`, only when the Application CRD is served; apps in, or deploying to, the selected namespace) `argoSyncFailed` (last operation Failed/Error or an `*Error` condition, critical), `argoDegraded` (critical), `argoMissing` (warning), `argoOutOfSync` (warning). Each app is reported once, in its worst category, and `counts.argoApps` is `{total, synced, outOfSync, healthy, degraded, missing, failed}`.
- `topWarnings` groups Warning events seen in the last hour by reason (top 10 by count).
