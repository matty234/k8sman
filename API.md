# k8sman backend API

Local-only HTTP/WebSocket API served by `backend/cmd/k8sman-server` on
`127.0.0.1:7443` by default. The macOS app embeds the server and runs it with
`--addr 127.0.0.1:0`; the server prints `K8SMAN_LISTENING <addr>` on stdout
once it listens. Reads are always available. Edits, actions and starting
port-forwards are refused (403) when the server runs with `--read-only`. The Dart client in
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
- Categories: pods `crashLoop` (including a container that just exited non-zero and is restarting), `imagePull` (ImagePullBackOff, ErrImagePull, InvalidImageName), `createContainerConfigError` (also CreateContainerError and RunContainerError), `initBlocked` (failing init container, or still initializing after 5m), `oomKilled` (OOMKilled within the last hour), `podFailed`, `stuckPending` (Pending for more than 5m; reason from the PodScheduled condition, e.g. Unschedulable), `stuckTerminating` (deletionTimestamp more than 5m old), `notReady` (Running but not ready for more than 5m), `highRestarts` (5 or more restarts); workloads `deploymentUnavailable`, `progressDeadlineExceeded`, `rolling`, `deploymentPaused`, `statefulSetNotReady`, `daemonSetNotReady`; jobs `jobFailed`, `jobLongRunning` (active for more than 1h), `jobSuspended`, `cronJobFailing` (latest job failed), `cronJobOverdue` (next run per the schedule is more than 2m, or startingDeadlineSeconds, in the past), `cronJobSuspended`; nodes `nodeNotReady`, `nodePressure`, `nodeCordoned`; storage `pvcPending` (more than 5m), `pvcLost`.
- `topWarnings` groups Warning events seen in the last hour by reason (top 10 by count).

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
