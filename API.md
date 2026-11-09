# k8sman backend API

Local-only HTTP/WebSocket API served by `backend/cmd/k8sman-server` on
`127.0.0.1:7443` by default. The macOS app embeds the server and runs it with
`--addr 127.0.0.1:0`; the server prints `K8SMAN_LISTENING <addr>` on stdout
once it listens. Reads are always available. Edits, actions, starting
port-forwards, exec and debug containers are refused (403) when the server runs with `--read-only`. The Dart client in
`frontend/lib/api/client.dart` wraps all of these endpoints.

## Access control

The server holds the user's cluster credentials, so every request (HTTP and
WebSocket upgrades, including `/api/health`) must pass these checks
(`backend/internal/server/guard.go`), in this order:

1. **Host**: `127.0.0.1:<port>`, `localhost:<port>` or `[::1]:<port>`, where
   `<port>` is the port the request arrived on. Anything else → 403
   (`reason: "ForbiddenHost"`; stops DNS rebinding).
2. **Origin**: absent (the desktop app sends none) or exactly
   `http(s)://localhost|127.0.0.1|[::1][:port]`. Anything else → 403
   (`ForbiddenOrigin`). Local origins get CORS headers; their `OPTIONS`
   preflights are answered without a token.
3. **Bearer token**: `Authorization: Bearer <token>`, compared in constant
   time. Missing or wrong → 401 (`Unauthorized`). WebSockets send it as a
   handshake header too; a token in the query string is ignored.
4. **Content-Type** on POST/PUT/PATCH/DELETE: `application/json` (also
   `application/yaml` for `PUT /api/object`, `POST /api/apply` and `POST /api/rbac/apply`),
   even with an empty body. Anything else → 415 (`UnsupportedMediaType`),
   so a cross-site "simple" request (`text/plain`, forms) never reaches a
   handler.
5. **Context check**: the app sends `X-K8sman-Context: <context it shows>`
   on every request. A change (any non-GET) for a context other than the
   current one → 409 (`ContextMismatch`), so an action confirmed for one
   cluster never runs on another after a switch. Context, kubeconfig and
   settings endpoints are exempt; requests without the header aren't checked.

The token comes from the `K8SMAN_AUTH_TOKEN` environment variable (at least
32 characters), which the server removes from its environment after reading.
The macOS and Windows apps generate 32 random bytes per backend launch and
pass them this way (an environment variable rather than a flag, since
command lines are visible to other users). A server started without it (e.g.
`make backend`) generates a token, prints `K8SMAN_DEV_TOKEN <token>` on
stderr and writes it to `~/.config/k8sman/dev-token` (mode 0600), where the
app (`make app-dev`) and scripts can read it:

```sh
curl -H "Authorization: Bearer $(cat ~/.config/k8sman/dev-token)" http://127.0.0.1:7443/api/health
```

The `--pprof` listener applies the same checks.

If no kubeconfig can be loaded at startup the server still runs, disconnected:
cluster endpoints return 503 (`reason: "NoKubeconfig"`), while `/api/health`,
`/api/contexts`, `/api/kubeconfigs*`, `/api/settings/*` and `/api/portforwards*` keep working so
the UI can let the user pick a file.

Resource targets use query params `group` (`""` = core), `version` (optional:
the server's preferred version is used if omitted) and `resource` (the plural, e.g. `deployments`).
`namespace` is optional; omit it for all namespaces or cluster-scoped types.
`namespaces=a,b,c` selects a set of namespaces instead (see
[Namespace sets](#namespace-sets)); sending both is a 400.

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/health` | `{ok, connected, context, host, kubeconfig, readOnly, error?}` |
| GET | `/api/contexts` | `{current, contexts:[{name,cluster,user,namespace,server,auth?}]}`; `auth` names an exec plugin / auth provider (e.g. `kubelogin`) |
| POST | `/api/contexts/current` | body `{name}`: switch the kube context (remembered per kubeconfig) |
| GET | `/api/kubeconfigs` | `{current, currentKey, context, home, merged?, candidates:[{path, contexts:[names], currentContext, source, error?}]}`. `current` is the active file (`""` = default rules merging the `merged` $KUBECONFIG files). `currentKey` is its canonical identity (see [Saved views](#saved-views)). Candidates: each `$KUBECONFIG` entry, `~/.kube/config`, other files under `~/.kube` that parse as kubeconfig (cache dirs skipped), and recently used files. `source` is `KUBECONFIG`, `default`, `kube-dir` or `recent`. Only paths and context names are returned |
| POST | `/api/kubeconfigs/current` | body `{path}` (absolute or `~/…`): validate the file, make it active and connect to its last used context (else its current-context). Returns the same shape as GET |
| GET | `/api/probe?step=reach\|auth` | connection check for the current context, run before discovery: `reach` = unauthenticated `GET /version`, fails in 10 s with `reason: "Unreachable"`; `auth` = the same with credentials (runs exec plugins; 30 s, 5 min for exec) |
| GET | `/api/resources[?refresh=true]` | discovered listable types `[{group,version,resource,kind,namespaced,verbs,shortNames,categories,custom}]` |
| GET | `/api/namespaces` | `{namespaces:[...], default, listed}`. `listed` is false when listing is forbidden (403); `namespaces` then holds only the kubeconfig context's own namespace (`[]` if it has none) and `default` is that namespace (`""` if none). `GET /api/contexts` also reports each context's kubeconfig `namespace` |
| GET | `/api/table` | list rendered through the jq columns: `{resource, columns, isDefaultColumns, resourceVersion, rows:[{uid,name,namespace,resourceVersion,cells,object?}], columnErrors:{idx:msg}, partialErrors?}`. Accepts `labelSelector`, `fieldSelector`, `includeObject=true`, `columns` (a JSON array of columns that replaces the kind's for this request, as a saved view uses) and `namespaces` (`partialErrors: [{namespace, error, reason, code}]` lists namespaces of the set that couldn't be read) |
| GET | `/api/items` | raw objects `{items:[...], partialErrors?}`. Accepts `labelSelector`, `fieldSelector` and `namespaces`. Use this for related resources |
| GET | `/api/object?name=[&subresource=status\|scale]` | one object as JSON, or YAML with `format=yaml` (managedFields stripped unless `managedFields=true`) |
| GET | `/api/events` | core/v1 Events for an object, newest first. Filter by `uid` (preferred) or `kind`+`name`, plus `namespace` |
| GET | `/api/owned?uid=` | objects that name `uid` in their ownerReferences, from the watch cache: `{items:[{group,version,kind,namespace,name,uid,status?}], partial}`. `namespace` narrows to the owner's namespace; without it (cluster-scoped owners) only already-cached kinds are searched. Searches every warm stream plus Pods, ReplicaSets, Jobs, PVCs, Services, ControllerRevisions, EndpointSlices, Endpoints and ConfigMaps (starting their watches for a namespaced lookup); Secrets only if already cached. `partial` is true when any of those could not be searched. No uid index is kept: each request scans the cached objects |
| GET/PUT/DELETE | `/api/columns` | read `{columns, isDefault, defaults}`, save `{columns}`, or reset the user's column override |
| GET/PUT/DELETE | `/api/settings/sidebar` | the sidebar's top section, persisted in settings.json: read `{sidebar: {items} \| null}` (null = app default), save `{items}`, or reset. Each item is a page `{view, hidden?}` (hidden pages fold under "More") or a pinned kind `{group, kind, namespace?}` (keyed by group/kind, applies across clusters). Works without a cluster connection |
| PUT | `/api/settings/readonly` | lock or unlock a kube context: `{context, readOnly: true \| false \| null}` (null = automatic: read-only when the name looks like production). Returns `{context, readOnly, readOnlyReason}`. `GET /api/health` reports the current context's `readOnly` and `readOnlyReason` (`flag`, `context` or `auto`); `GET /api/contexts` adds `readOnly: {context: reason}` |
| GET | `/api/settings/views` | saved views (see [Saved views](#saved-views)): `{views: [View], launchView, kubeconfigKeys: {path: key}}`. Works without a cluster connection |
| PUT/DELETE | `/api/settings/views/{id}` | add or replace a view (body: the View, its `id` matching the URL), or delete it. `PUT ?index=N` places the view at position N of the order (moving it if it exists; clamped to the end), so undoing a delete restores the old position. Without `index` a new view goes last and an existing one keeps its place |
| PUT | `/api/settings/views/order` | `{ids: [...]}`: puts those views in that order. They keep the slots they occupy now, so records of a newer version stay where they are. Unknown ids are ignored. 204 |
| PUT | `/api/settings/views/launch` | `{id}`: the view to open at launch (`""` = reconnect to the last context) |
| POST | `/api/settings/views/export` | `{views: [View]}` → the views as YAML documents (`application/yaml`) |
| POST | `/api/settings/views/parse` | `{yaml}` → `{views: [View]}`: YAML documents as exported, with fresh ids, validated but not saved |
| GET/PUT | `/api/settings/tables` | per-kind table preferences in settings.json: read `{tables: {"group/Kind": {sortColumn?, sortDescending?, widths?, filter?}}}`, save one with `{kind, prefs}` (prefs null forgets it) |
| GET/PUT | `/api/settings/namespaces[?context=]` | namespaces the user added by hand, per kube context (default: the current one), in settings.json's `namespaces` (`{"<context>": ["a","b"]}`; absent in older files). Read `{context, namespaces}`; save `{context?, namespaces: [...]}` (replaces the list; each a DNS-1123 label, at most 200; `[]` forgets them), 204. Local settings only, so allowed in read-only mode |
| GET/PUT | `/api/settings/modules` | integrations the user turned off, in settings.json: read or save `{disabled: [ids]}`. Ids: `argocd`, `argoworkflows`, `helm`, `gpus`, `prometheus`, `gateway`, `hubble` (backend modules) and UI-only ones (`metrics`, `addons`). A turned-off module's endpoints (`/api/argocd/*`, `/api/argowf/*`, `/api/helm/*`, `/api/gpu`, `/api/prom/*`, `/api/gateway/*`, `/api/hubble/*`) answer 404 with `reason: "ModuleDisabled"`, its actions are not offered, and the overview skips its checks. Works without a cluster connection |
| GET/PUT | `/api/settings/modules/{id}[?context=]` | a module's own settings for a kube context (default: the current one), in settings.json's `moduleSettings`: read `{context, settings}` (`{}` when none are saved) or save a JSON object (`{}` clears). The module validates it (400 with the reason). Only modules with settings (`hubble`, `argocd`); others answer 404. Modules whose settings hold a secret show a redacted form on read and merge a partial body on write (Argo CD, below). Allowed in read-only mode: it changes k8sman's settings, not the cluster |
| GET/PUT | `/api/settings/icons` | whether CRD group icons may be fetched from the internet (see [CRD group icons](#crd-group-icons)): read `{remoteIcons: true \| false \| null, flag, effective}` (null = automatic; `flag` = the backend runs with `--no-remote-icons`; `effective` = what applies to the current context), save `{remoteIcons}`. Replies like GET |
| POST | `/api/columns/preview[?limit=]` | body `{columns}`: evaluates unsaved columns against live objects and returns a table |
| WS | `/api/watch` | live table: `{type:"SNAPSHOT",table}`, then `{type:"ADDED"/"MODIFIED"/"DELETED",row}`, or `{type:"ERROR",error}`. With `namespaces`, `{type:"PARTIAL_ERROR", namespace, error, reason, code}` reports a namespace of the set that can't be watched (e.g. Forbidden) while the socket stays open for the others. Re-lists and sends a fresh SNAPSHOT when the watch expires. To watch a single object, use `fieldSelector=metadata.name=X&includeObject=true`. `columns=<JSON array>` renders the rows through those columns instead of the kind's (a saved view's own columns; invalid queries are a 400). With `batch=true` the server may also send `{type:"BATCH",events:[{type,row},…]}`: deltas from a ~75ms window, in order (apply all, then redraw once). See [Shared watches](#shared-watches) |
| WS | `/api/logs` | `namespace`, `pod`, `container`, `tailLines` (default 500, `-1` = all), `previous`, `timestamps`, `sinceSeconds`, `follow` (default true). Sends frames `{line}`, ending with `{eof:true}` or `{error}` |
| WS | `/api/logs/aggregate` | merged logs of many pods. `namespace` plus one of `selector` (label selector; the pod set follows the shared pod watch) or `pods` (comma-separated names, fixed). `container`: a name, `*` for every container, or omitted for each pod's default (`kubectl.kubernetes.io/default-container`, else `main` if the pod has it, else the first). `tailLines` (per stream, default 200, `-1` = all), `sinceSeconds`, `previous` (each container's previous instance; containers without one are skipped, and a `selector` pod set is read once, not followed), `follow` (default true). Streams run concurrently with timestamps and are merged by timestamp through a 250ms reorder window. Frames: a JSON **array** `[{pod,container,ts,line},…]` per ~75ms flush (`ts` is RFC3339Nano, `line` has no timestamp prefix); `{event:"added"\|"removed",pod,container}` when a stream starts or its pod goes away (pods that appear later are read from their start); `{error,pod?,container?}` for one failing stream (the session continues); `{warning}` when more than 50 pods match (the first 50 by name are streamed). Streams start once a container is running or has terminated. Closing the socket closes every stream. Allowed in read-only mode |

## Shared watches

The server keeps one upstream LIST+WATCH per resource, namespace and
selector set (per kube context) and shares it between every `/api/watch`
client; a single-object or label-selector watch rides on an already open
watch of the same type and is filtered locally. `/api/table` and
`/api/items` answer from an open watch when there is one (else they LIST),
and `/api/overview` and `/api/security` list through the same cache, so
repeated polls cost no API requests. Objects in the cache have
`metadata.managedFields` removed, so watch rows with `includeObject` and
`/api/items` answered from it don't carry it (`/api/object` still can). A watch nobody uses is kept for 90s,
then stopped. Errors are those of the upstream LIST: `Forbidden` and
`NotFound` end the watch (the socket closes after the ERROR frame), other
errors are retried with backoff. A watch that ends normally resumes from
its last resourceVersion; an expired one (410) re-lists and sends a fresh
SNAPSHOT. A client that falls more than 4,096 events behind gets a fresh
SNAPSHOT instead of the backlog. See docs/PERFORMANCE.md.

## Saved views

A view is a saved table: a kind, a namespace scope, a filter, a sort and its
own columns, bound to one context or applying to any context. Views are
stored in `settings.json` as versioned records; records with a `version`
newer than this backend writes are kept and returned untouched.

```jsonc
{"version": 1, "id": "9f2c41d07a3b5e18", "name": "My back-end deployments",
 "context": {"kubeconfig": "", "name": "us-east-a", "server": "https://…"},  // null = any context
 "kind": {"group": "apps", "kind": "Deployment"},
 "namespaces": ["team-1", "team-2"],          // [] = all namespaces
 "filter": "back-end",
 "sort": {"column": "Age", "descending": true},
 "columns": [{"name": "Name", "query": ".metadata.name"}]}
```

`id` is 1–64 characters of `[A-Za-z0-9_-]`; at most 500 views are kept.
`columns` are validated like `PUT /api/columns`. The YAML form
(`apiVersion: k8sman.dev/v1`, `kind: View`, with `resource` for the kind)
leaves out the kubeconfig path; a bound view keeps its context name and API
server URL so an importer can re-point it.

**Context identity.** A bound view's `context.kubeconfig` is the path as saved (`""` = the default loading rules). Clients compare kubeconfigs by canonical key, not by that string: `GET /api/settings/views` returns `kubeconfigKeys` (every kubeconfig path the views mention, and `""`, mapped to its key) and `GET /api/kubeconfigs` returns `currentKey`. The key is `cluster.KubeconfigKey`: `""` resolves like the loader does (the one `$KUBECONFIG` entry, else `~/.kube/config`; several entries give all of them joined), `~/` is expanded, the path is made clean and absolute, and symlinks are resolved when the file exists. So the default kubeconfig and an explicitly picked `~/.kube/config` are the same context. Stored views are unchanged.

## Namespace sets

`/api/watch`, `/api/table`, `/api/items`, `/api/overview`, `/api/security`,
`/api/metrics/pods`, `/api/metrics/summary` and `/api/metrics/volumes` take
`namespaces=a,b,c` (comma-separated, or the parameter repeated) for a set of
namespaces. One namespace in the set behaves exactly like `namespace=`.

- **Watch.** When a warm all-namespaces watch of the resource exists, the
  set is a filtered subscriber on it (no extra API requests). Otherwise
  each namespace gets its own shared watch (the same one a one-namespace
  table uses) and the server merges them: the first SNAPSHOT waits until
  every namespace has listed or failed for good, a namespace that re-lists
  produces a fresh merged SNAPSHOT, and a namespace that fails for good
  (Forbidden, NotFound) is a `PARTIAL_ERROR` frame. Only when every
  namespace fails does the watch send ERROR and close. This works for users
  whose RoleBindings cover only those namespaces.
- **Snapshots** (`/api/table`, `/api/items`) read every namespace in
  parallel (or the warm all-namespaces watch) and concatenate the rows;
  unreadable namespaces are listed in `partialErrors` unless all of them
  fail.
- **Overview, Security, Metrics** list each namespace of the set and
  analyse the union. Namespaces that can't be read are left out (unless
  none can). `/api/overview` and `/api/security` report the set as
  `namespace: "a,b"` and list the namespaces they left out in `partialErrors`
  (same shape as in `/api/table`), so pages show the table's banner. Metrics
  Top reads its pod list through `/api/items`, which has `partialErrors`;
  Alerts filter by label and read no namespace, so they have none. Custom and external metrics stay per namespace.

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
| PUT | `/api/object?name=[&dryRun=true][&subresource=status\|scale]` | replace an object from a YAML/JSON body (`kubectl edit` semantics). The body must keep `metadata.resourceVersion`, so a stale edit returns 409 `Conflict`. Validation failures return 422 with `causes:[{field,message}]`. Returns `{dryRun, resourceVersion, yaml, context}`. With `subresource=status` or `scale` (GET and PUT) the request goes to that subresource instead: `scale` reads/writes an `autoscaling/v1` Scale, and `status` replaces only `.status` (the rest of the body is ignored by the server). 400 if the type doesn't list the subresource in its `subresources` field (resource types carry `subresources: ["status","scale"]` when discovery shows them). Read-only mode and the context guard apply as for any PUT |
| POST | `/api/apply[?namespace=][&dryRun=true][&mode=create\|apply]` | create objects from a YAML/JSON body of one or more documents (`---`; a v1 `List` expands to its items), in order, like `kubectl create -f`. Kinds resolve through discovery (CRs too). Namespaced objects without `metadata.namespace` go to `namespace` (else the context's default namespace, else `default`); cluster-scoped ones lose any namespace. `mode=apply` uses server-side apply instead (fieldManager `k8sman`, `force=false`), which also updates existing objects; fields owned by another manager come back as a per-document `Conflict`. Always 200 once the body parses: `{dryRun, mode, context, results:[{index, line, group, version, kind, namespace?, name, created, error?, reason?, causes?}]}`, one per object; `line` is the document's first line in the body, `reason` the Kubernetes StatusReason (e.g. `AlreadyExists`, `Invalid`) and `causes` as for `PUT /api/object`. Refused in read-only mode |
| GET | `/api/actions` | actions supported for a type: `{actions:[...]}` |
| POST | `/api/actions/{action}?name=` | run an action. Body: `{replicas?, revision?, gracePeriodSeconds?, propagation?, dryRun?}`. Returns `{message, dryRun, context, created?}` |

**Node drain** uses kubectl's drain package (`kubectl drain --ignore-daemonsets`):

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/nodes/drain-plan?name=[&deleteEmptyDirData=][&force=]` | what a drain would do: `{node, evict:[ns/name], warnings:[...], blockers:[...]}`. Warnings are what drain skips or accepts (DaemonSet pods, emptyDir data, unmanaged pods) as kubectl prints them; blockers are why it would refuse (unmanaged pods without `force`, emptyDir without `deleteEmptyDirData`) |
| POST | `/api/nodes/drain?name=` | body `{deleteEmptyDirData?, force?, gracePeriodSeconds? (default: each pod's own), timeoutSeconds? (default 300)}`. Cordons the node, then evicts through the Eviction API, so PodDisruptionBudgets are honoured (blocked evictions retry until the timeout). Returns `{node, evicted:[ns/name], error?, context}`; `error` is set when it stopped short, and the node stays cordoned, like kubectl. Refused in read-only mode |

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
| (drain) | Nodes | see **Node drain** below |
| `delete` | anything with the delete verb | deletes the object |
| `argocd-refresh` | Argo CD Applications | annotates `argocd.argoproj.io/refresh: normal`, or `hard` with `{hard: true}` |
| `argocd-sync` | Argo CD Applications | sets `.operation.sync` like the Argo CD API server. Body: `{prune?, syncDryRun?, targetRevision?, syncOptions?, force?}`. 409 when an operation is pending or running unless `force` (which replaces it). `syncDryRun` is Argo's dry run; `dryRun` stays a kube dry run of the patch |
| `argocd-terminate` | Argo CD Applications | sets `status.operationState.phase: Terminating` on a running operation, as `argocd app terminate-op` does |
| `suspend` / `unsuspend` | Argo CronWorkflows | sets `spec.suspend` (`argo cron suspend/resume`) |
| `argowf-stop` / `argowf-terminate` | Argo Workflows | sets `spec.shutdown: Stop` / `Terminate` (`argo stop` / `argo terminate`); 400 for completed workflows |
| `argowf-suspend` / `argowf-resume` | Argo Workflows | suspend sets `spec.suspend`; resume clears it and marks running suspend steps `Succeeded` (supplied outputs take their defaults), as `argo resume` does. 400 when node status is offloaded |
| `argowf-resubmit` | Argo Workflows | creates a new Workflow from the spec (same parameters, `generateName`, the `resubmitted-from-workflow` label), as `argo resubmit` does; `created` points at it. `{memoized: true}` (Failed/Error only) goes through argo-server |
| `argowf-retry` | Argo Workflows (Failed/Error) | `{restartSuccessful?}`. Through argo-server only (`PUT /api/v1/workflows/{ns}/{name}/retry`); 503 when it is unavailable |
| `argowf-submit` | CronWorkflows, WorkflowTemplates, ClusterWorkflowTemplates | creates a Workflow: from a cron's `workflowSpec` (labelled and owned like a scheduled run, as `argo submit --from cronwf/x`), or referencing the template with `{parameters?:[{name,value}], entrypoint?}` (enums are checked). ClusterWorkflowTemplates need `{targetNamespace}` |

See `docs/ARGOCD.md` for how these work without the Argo CD API server.

## Terminals (exec)

| Method | Path | Purpose |
|---|---|---|
| WS | `/api/exec` | interactive TTY in a container. Query: `namespace`, `pod`, `container` (default: the `kubectl.kubernetes.io/default-container` annotation, else the first), `command` (repeat the param per argument, or pass one JSON array such as `["redis-cli","-n","1"]`; exec'd as-is), `shell` (`auto` (default), `bash`, `zsh`, ... used when there's no `command`), `cols`/`rows` (initial size) |
| WS | `/api/local-shell` | interactive login shell on this machine, pointed at the current context (see **Local shells** below) |
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

**Local shells.** `WS /api/local-shell` (query: `cols`/`rows`) runs the user's
login shell (`$SHELL -l`, else the passwd entry, else `/bin/zsh` on macOS or
`/bin/bash`/`/bin/sh`) in a pseudo-terminal on this machine, in their home
directory, with the same framing as `/api/exec`. `started.container` is the kube
context it targets. Its environment is the backend's, minus every `K8SMAN_*`
variable (the API token never reaches it), with `TERM=xterm-256color`,
`TERM_PROGRAM=k8sman`, `K8SMAN_CONTEXT=<context>` and
`KUBECONFIG=<session file>:<the app's kubeconfig>`. The session file (0600,
deleted when the shell ends) only sets `current-context`, so `kubectl` targets
the app's context without changing any kubeconfig. Read-only mode doesn't
refuse it, since the shell uses the user's own credentials either way; on a
read-only context it starts with a yellow notice saying so. Closing the socket
hangs up the shell's process group (SIGHUP, then SIGKILL after 2s). Not yet
available on Windows (`error`, `execFailed`).

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
| POST | `/api/portforwards` | create: `{namespace, kind: pod/service/deployment/statefulset/daemonset/replicaset, name, port (number or name), localPort (0 = auto), autoStart, label, replace}`. If `localPort` is held by another forward of ours, or by another process, it answers 409 `{reason: "LocalPortInUse", usedBy, suggestedPort}` (`usedBy` is `namespace/kind/name:port`, empty when another process holds it). With `replace: true` the forward holding the port is stopped and forgotten, and the new one starts in its place (not possible when another process holds the port) |
| POST | `/api/portforwards/stop` | stop every running forward in one request, or only those of `?context=`; they stay saved. `{stopped: n}` |
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
| GET | `/api/metrics/volumes[?namespace=]` | per-PVC usage merged per claim: `{items:[{namespace, claim, source: "prometheus"\|"kubelet", usedBytes, capacityBytes, availableBytes, inodes, inodesUsed}], prometheus, kubelet, kubeletMessage?}`. Prometheus `kubelet_volume_stats_*` (uncapped instant queries) where it has the claim, the kubelet Summary API for the rest. Always 200 |
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
| GET | `/api/overview[?namespace=][&wait=1s]` | cluster health summary for one namespace, or all if omitted. Answers after a soft deadline (`wait`, default `1.2s`, at most `10s`) with what has loaded; see `pending`. Lists pods, deployments, statefulsets, daemonsets, replicasets, jobs, cronjobs, nodes, PVCs and Warning events once each, in parallel, and analyses them (`backend/internal/overview`) |

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
 nodes: [{name, ready, cordoned, pressure?, roles?, version, pods,
          cpuAllocatable, cpuRequests, memoryAllocatable, memoryRequests}],  // millicores, bytes
 topWarnings: [{reason, count, objects, latestMessage, lastSeen, example: {kind, group, namespace?, name}}],
 capacity?: {cpuAllocatable, cpuRequests, memoryAllocatable, memoryRequests},  // sum over nodes; absent without nodes
 errors?: {"<resource>": "<message>"},                // lists that failed (e.g. RBAC); pods failing is a hard error
 pending?: ["alerts", "argocd", "deployments", ...]}    // sources not finished at the soft deadline
```

- `pending` names the sources still loading: `deployments`, `statefulsets`, `daemonsets`, `replicasets`, `jobs`, `cronjobs`, `nodes`, `pvcs`, `events`, `alerts`, `argocd`, `workflows`, `gateway`, `hubble`. Pods are never pending: they are always waited for, up to the 20s limit. What a pending source feeds (its `counts`, `categories`, `issues`, `nodes`) is unknown, not zero or healthy, and clients show a placeholder for it. Pending sources keep running after the response (up to 20s) and warm the watch cache, so asking again shortly after (the app does after 0.7s, 1.5s, then 3s) returns more. Absent when everything finished.
- `severity` is `critical`, `warning` or `info`. Issues are sorted by severity, then by most recent `since` (RFC3339).
- `owner` is the pod's top-level controller: Pod → ReplicaSet → Deployment, Pod → Job → CronJob, or a StatefulSet/DaemonSet. Group issues by `(namespace, owner, category)` to show "3 pods of Deployment web are CrashLoopBackOff".
- Pod `reason` is the pod table's Status column (`Terminating`, `Init:<reason>`, the first container waiting/terminated reason, else the phase). `count` is the pod's restart count.
- Categories: pods `crashLoop` (including a container that just exited non-zero and is restarting), `imagePull` (ImagePullBackOff, ErrImagePull, InvalidImageName), `createContainerConfigError` (also CreateContainerError and RunContainerError), `initBlocked` (failing init container, or still initializing after 5m), `oomKilled` (OOMKilled within the last hour), `podFailed`, `stuckPending` (Pending for more than 5m; reason from the PodScheduled condition, e.g. Unschedulable), `stuckTerminating` (deletionTimestamp more than 5m old), `notReady` (Running but not ready for more than 5m), `highRestarts` (5 or more restarts); workloads `deploymentUnavailable`, `progressDeadlineExceeded`, `rolling`, `deploymentPaused`, `statefulSetNotReady`, `daemonSetNotReady`; jobs `jobFailed`, `jobLongRunning` (active for more than 1h), `jobSuspended`, `cronJobFailing` (latest job failed), `cronJobOverdue` (next run per the schedule is more than 2m, or startingDeadlineSeconds, in the past), `cronJobSuspended`; nodes `nodeNotReady`, `nodePressure`, `nodeCordoned`; storage `pvcPending` (more than 5m), `pvcLost`; Argo CD (section `argocd`, only when the Application CRD is served; apps in, or deploying to, the selected namespace) `argoSyncFailed` (last operation Failed/Error or an `*Error` condition, critical), `argoDegraded` (critical), `argoMissing` (warning), `argoOutOfSync` (warning). Each app is reported once, in its worst category, and `counts.argoApps` is `{total, synced, outOfSync, healthy, degraded, missing, failed}`; network (Gateway API, when served; see `docs/GATEWAY_API.md`) `gatewayNotReady` (not Accepted/Programmed), `gatewayListener` (listener Conflicted or ResolvedRefs/Accepted/Programmed False), `routeNotAccepted` (critical when no parent accepts the route, else warning), `routeUnresolvedRefs`.
- `topWarnings` groups Warning events seen in the last hour by reason (top 10 by count).
- Requests are the effective requests (containers and sidecars, or the largest init container, plus overhead) of the non-terminated pods scheduled on each node, as `kubectl describe node` counts them. Only pods in the namespace scope count, so for one namespace they are that namespace's share. Capacity is unknown while `nodes` is pending.

## NVIDIA GPUs

| Method | Path | Description |
|---|---|---|
| GET | `/api/gpu[?live=false][&refresh=true]` | GPU inventory (`backend/internal/gpu`): nodes with `nvidia.com/gpu` (or MIG / `gpu.shared`) capacity and their GPU feature discovery labels, pods requesting GPU resources and per-node allocation. Merged with live DCGM exporter stats from the default Prometheus when present. `live=false` skips Prometheus. Cached for 10s per context |

```
{generatedAt, monitoring: "dcgm"|"noExporter"|"noPrometheus"|"error"|"skipped", prometheus?, attribution,
 summary: {nodes, capacity, allocatable, allocated, devices, idle, unhealthy, unmonitored, pendingPods, avgUtil?},
 nodes: [{name, ready, product?, family?, memoryMiB?, count?, driverVersion?, cudaVersion?, migStrategy?, sharingStrategy?,
          capacity, allocatable, allocated, resources: [{name, capacity, allocatable, allocated}], monitored,
          idleAllocated?, selector?, pods: [{namespace, name, gpus}],
          devices: [{node, gpu, uuid?, model?, util?, avgUtil?, memUsed?, memTotal?, tempC?, powerW?, tensorActive?, ...,
                     xid?, uncorrectableRemappedRows?, rowRemapFailure?, pods?, health?, idle?, selector}]}],
 pods: [{namespace, name, node?, phase, gpus, resources, startedAt?, devices?, util?, avgUtil?, idle?, selector?, unschedulable?}],
 issues: [{severity, reason, node?, namespace?, pod?, gpu?, message}], errors?}
```

- DCGM series are mapped to nodes by a `node`/`kubernetes_node`/`Hostname` label naming a node, else through the exporter pod (`namespace`/`pod`, or `Hostname` as a pod name), else the scrape `instance` IP (pod IP, or node IP for hostNetwork exporters).
- Devices are attributed to pods only from `exported_pod`/`exported_namespace` (dcgm-exporter's pod mapping), or `pod`/`namespace` naming a pod that requests GPUs (honorLabels). Without attribution, allocation is per node only.
- Fractions are 0..1, memory in bytes. `selector` is a PromQL label matcher for the device's / node's / pod's DCGM series (used for history charts).
- An allocated GPU is idle when its utilisation averaged under 1% over the last hour and its pods have run that long. Without attribution, `idleAllocated` is the node's allocated GPUs minus devices that did any work.
- Issue reasons: `IdleAllocated`, `NoExporter` (GPU node without DCGM metrics while other nodes have them), `NoDCGM`, `DevicePluginUnhealthy` (capacity > allocatable), `DevicesNotReported`, `XIDError`, `RowRemapFailure`, `UncorrectableRemappedRows`, `ECCDoubleBitErrors`, `HighTemperature` (≥ 85 °C), `PendingGPU`.

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

## Access (RBAC workspace)

Effective permissions are computed from the cluster's Roles, ClusterRoles and
bindings by `backend/internal/rbac`, the way the RBAC authorizer evaluates them:
aggregated ClusterRoles are expanded (each rule attributed to the role that
declares it, with the aggregation chain), a RoleBinding to a ClusterRole only
grants namespaced resources in its namespace, `*/subresource` matches but
`pods/*` doesn't, resourceNames never match unnamed requests (list, create),
nonResourceURLs support a trailing `*`, and ServiceAccounts belong to
`system:serviceaccounts`, `system:serviceaccounts:<ns>` and
`system:authenticated`. RBAC is listed cluster-wide through the watch cache;
a list that is forbidden is an error (a partial answer would under-report).

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/rbac/subjects` | `{serviceAccounts, users, groups: [{kind, name, namespace?, bindings, exists}], serviceAccountsError?}`: every subject named by a binding, plus every ServiceAccount |
| GET | `/api/rbac/matrix?kind=&name=&subjectNamespace=&namespace=&groups=` | a subject's permissions. `namespace` empty = cluster-wide (ClusterRoleBindings only); a namespace adds its RoleBindings. `groups` (comma-separated) adds groups to a User. Returns `{subject, identity: {user, groups}, namespace, verbs, rows: [{group, resource, kind, namespaced, virtual?, verbs, cells: {<verb>: {paths: [i], names?, danger?}}}], paths: [Path], nonResource: [{urls, verbs, paths}], fullWildcard, bindings: [{binding, role, roleMissing?, subject, scope, inherited?}], roleBindingNamespaces, missingRoles?}`. A `*` cell means the rule has the wildcard verb; `names` means only those objects |
| GET | `/api/rbac/role-matrix?kind=Role\|ClusterRole&name=&namespace=` | the same matrix for one role's (aggregated) rules |
| GET | `/api/rbac/who-can?verb=&group=&resource=&subresource=&resourceName=&namespace=&path=` | `{request, danger?, entries: [{subject, paths, partial?, names?, fullWildcard?, scopes}]}`. `namespace` empty = cluster-wide, `*` = any namespace. Without `resourceName`, grants limited to resourceNames are returned as `partial` |
| GET | `/api/rbac/self?namespace=` | the app's own credentials: SelfSubjectRulesReview laid out as a matrix, plus `identity` from SelfSubjectReview (or, on servers before 1.26, the impersonated user or the client certificate's CN/O; `identitySource` says which), `incomplete`, `evaluationError?`, `readOnly` |
| POST | `/api/rbac/check` | body `{subject?, groups?, request: {verb, group, resource, subresource?, name?, namespace?, path?}}`: a SubjectAccessReview (SelfSubjectAccessReview without `subject`), compared with the resolver: `{allowed, denied, reason, evaluationError?, identity, resolver: {allowed, paths}, agree}`. Reviews persist nothing, so this works with `--read-only` |
| GET | `/api/rbac/resources` | every served resource and subresource (preferred versions; the per-metric `custom.metrics`/`external.metrics` pseudo-resources are skipped) plus `virtual` ones RBAC knows (users, groups, signers, …) |
| POST | `/api/rbac/apply[?dryRun=true]` | create or replace one Role, ClusterRole, RoleBinding or ClusterRoleBinding (YAML or JSON body). Replacing needs `metadata.resourceVersion` (409 `AlreadyExists` without, 409 `Conflict` when stale). Returns `{dryRun, created, before, after, resourceVersion, context}` with volatile metadata stripped, for a diff. The API server's escalation check applies (also to dry runs): granting what you don't hold is 403 `attempting to grant RBAC permissions not currently held`. 403 with `--read-only` |

`Path` is `{binding: {kind, name, namespace?}, role, roleMissing?, subject, scope: "cluster"|<namespace>, rule: {rule: PolicyRule, source: <role declaring it>, index, via?: [aggregated ClusterRoles in between]}}`.

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
| GET | `/api/argocd/status[?namespace=&refresh=1]` | `{context, crd, found, reachable, server?:{namespace, service, port, scheme, rootPath?, version}, auth: none/configured/session, authValid?, username?, initialAdminAvailable, error?}`. `crd` is whether the Application CRD is served; when it is false nothing else is looked up. `namespace` is the Application's. Checks the token with `/api/v1/session/userinfo`. Discovery is cached for 30s (10s on failure) |
| POST | `/api/argocd/auth` | body `{token, context?, namespace?}` (context defaults to the current one; a pasted `Bearer ` prefix is dropped). Saves the token per kube context in `~/.config/k8sman/settings.json` (mode 0600, `moduleSettings.argocd[context]`) and drops any session. A token Argo rejects is not saved (401). Returns the status |
| DELETE | `/api/argocd/auth[?context=&namespace=]` | forget the saved token and the session for the context. Returns the status |
| POST | `/api/argocd/auth/initial-admin` | body `{namespace?}`. Opt-in only (the UI asks first): reads the password from `<argo ns>/argocd-initial-admin-secret` with your kube RBAC, `POST /api/v1/session` as `admin`, and keeps the session token in memory for this context. The password is never stored. 404/403 `NoInitialAdmin` when the Secret is missing or unreadable, 401 when the password was changed. A session takes precedence over a saved token until it is cleared or expires |
| GET/PUT | `/api/settings/modules/argocd[?context=]` | the generic module-settings endpoint. Saved per context as `{token?, useCli?}` (at most one; choosing one clears the other). GET never returns the token: `{useCli?, tokenSet?}`. PUT takes `{token?, useCli?}`: a field that is present replaces the saved one (`token: ""` removes it), absent fields are kept, `{}` clears both; no check against Argo (use `POST /api/argocd/auth` for that). Settings from releases that kept `argocdTokens` / `argocdUseCli` at the top of settings.json are moved here when the file is opened, and the old fields are dropped (a context that already has `moduleSettings.argocd` keeps it) |
| GET | `/api/argocd/diff?name=[&namespace=]` | Argo's `GET /api/v1/applications/{name}/managed-resources?appNamespace=`, converted: `{resources:[{group, kind, namespace?, name, status: Synced/OutOfSync, hook, requiresPruning, target: yaml/null, live: yaml/null}], server, auth}`. Out-of-sync resources come first. It compares `normalizedLiveState` with `predictedLiveState` when Argo predicted one (the diff the Argo UI shows), else `liveState` with `targetState`. Removed noise: `status`, `metadata.managedFields`, `resourceVersion`, `uid`, `generation`, `creationTimestamp`, `selfLink`, and the annotations `kubectl.kubernetes.io/last-applied-configuration` and `deployment.kubernetes.io/revision`. A null `target` means "to be pruned" and a null `live` means "to be created". Secret data arrives masked by Argo |

## Argo Workflows (argo-server)

Most Argo Workflows actions work on the CRs directly (see Mutations). Retry
and memoized resubmit need argo-server, reached through the API server's
service proxy (`https:argo-server:2746`, else http). The Service is
`argo-server` in any namespace, else the Helm chart's
`app.kubernetes.io/part-of=argo-workflows,app.kubernetes.io/component=server`.
Auth modes: `server` (no token; argo-server acts as its service account, so
anyone allowed to proxy to it gets its rights) and `client` (your kube bearer
token, also from exec plugins or auth providers, sent as argo-server's
`authorization` cookie because the API server strips `Authorization`). Client
certificates carry no token, and SSO-only servers are not supported; then
those two actions are unavailable. Tokens are never returned or logged.

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/argowf/status[?refresh=1]` | `{context, crd, found, reachable, server?:{namespace, service, port, scheme, version?}, auth: server/client/"", subject?, available, error?}`. `crd` is whether the Workflow CRD is served; when false, argo-server isn't looked for. Cached per context for 30s (10s when unavailable). Read-only |

The Health overview reports `workflowFailed` issues: Workflows that failed in
the last 24h, one per CronWorkflow / WorkflowTemplate (the latest failure,
with a count); critical unless a later run of the same origin succeeded.

## Gateway API status

Gateway API objects are read through the generic resource endpoints. One
small endpoint backs its status in Settings ▸ Integrations.

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/gateway/status` | `{crd, classes: [{name, controller, accepted}]}`. `crd` is whether the Gateway API CRDs are served; `classes` are the GatewayClasses (one direct list, no watch) with their controller and whether it accepted the class. Read-only |

## Cilium Hubble

Network flows from Cilium's Hubble Relay (`backend/internal/hubble`). The
relay speaks gRPC (`observer.Observer/GetFlows` and `ServerStatus`), which
the API server's service proxy can't carry, so the backend dials it through
an in-process port-forward to a ready relay pod (the same `pods/portforward`
subresource as port-forwards, but nothing listens on the machine; needs
`create pods/portforward` in the relay's namespace). It works in read-only
mode: nothing here changes the cluster.

Discovery: the relay Service by its chart labels (`k8s-app=hubble-relay`,
then `app.kubernetes.io/name=hubble-relay`) across namespaces, else
`hubble-relay` in `kube-system` or `cilium`; its port named `grpc`, else the
first. `cilium-config` says whether Cilium is there and Hubble on
(`enable-hubble`). TLS comes from the relay's own `hubble-relay-config`
(`disable-server-tls`); with TLS the CA is read from the
`hubble-relay-server-certs` Secret and a client certificate from
`hubble-ui-client-certs` (else `hubble-relay-client-certs`), in memory only.
Per-context overrides (`GET/PUT /api/settings/modules/hubble`): `relay`
(`namespace/name[:port]`), `tls` (`on`/`off`) and `tlsServerName` (default
`ui.hubble-relay.cilium.io`) and `reverseDNS` (boolean, default true: look up
PTR records for public world addresses on the map; cluster-object names
still apply when off).

Flows are fetched with a field mask (only the fields below; endpoint and
node labels make up most of a flow's ~3.5 KB), so a following stream fits
through the API server tunnel. The relay keeps a fixed number of flows per
node (4095 by default): on a busy cluster that is seconds of history, not
minutes, so `since` can reach back less far than asked; responses say how
far they got (`oldest`).

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/hubble/status[?refresh=true]` | `{state, message?, cilium, hubbleEnabled?, relay?:{namespace, service, port, tls, fromSettings?}, server?:{version, numFlows, maxFlows, seenFlows, flowsRate, uptimeSeconds, connectedNodes?, unavailableNodes?}, errors?, checkedAt}`. `state`: `notInstalled` (no Cilium, or Hubble off), `noRelay`, `connected` or `unreachable` (with the reason in `message`). Cached per context for 30s (10s when not connected) |
| WS | `/api/hubble/flows` | live flows, filtered by the relay. Frames `{flows?:[Flow], lost?, end?, error?}`, at most every 100 ms and 500 flows per frame. A following stream passes at most 1,000 flows a second; the rest, and flows the relay itself reports lost, are counted in `lost`. Query below; `follow` defaults to true, with recent history first (`since=5s`, or `5m` for a narrow query: some endpoints, or only non-FORWARDED verdicts). Without `follow`, the last 200 flows (or `last`/`since`) then a frame with `end`. Bad parameters are a 400 before the upgrade; an unreachable relay is an `error` frame |
| GET | `/api/hubble/drops` | recent drops grouped: `{groups:[{source, destination, reason, protocol?, port?, count, first, last, deniedBy?}], flows, truncated?, lost?, since, oldest?, partial?}`, most frequent first. Takes `namespace` (comma-separated), `since` (default 15m), `last` (default 1000). `partial` when the relay was too slow (15 s) |
| GET | `/api/hubble/connectivity?from=&to=` | "can A reach B": the flows from `from` to `to` (endpoint specs) as `{from, to, since, verdict: allowed\|dropped\|mixed\|unknown, verdicts:{VERDICT: n}, drops:[groups], allowedBy?:[policies], recent:[Flow] (last 50), reverse:{VERDICT: n} (the other way), lost?, oldest?}`. `since` defaults to 15m |
| GET | `/api/hubble/map[?window=5m]` | the traffic map: flows between namespaces, and between them and the world, counted over the last `window` (a Go duration, at most 15m; default 5m). `{window, since, now, startedAt, flows, drops, rate, lost?, uncounted?, state: starting\|live\|error, error?, edges:[{from, to, flows, drops, rate?, ports?, peers?, fromWorkloads?, toWorkloads?, reasons?}], names?:{"<ip>":{name, source: cluster\|rdns}}}`, busiest first. See below |

Flow query (`/api/hubble/flows`, and `namespace` for drops), translated into
Hubble `FlowFilter`s:

- Scope, ANDed, matching flows where either side is in it: `namespace`
  (comma-separated), `pod` (`namespace/name`, matched by Hubble as a prefix,
  so `ns/web-` matches a workload's pods; add `exact=true` for that pod only), `labels` (a label selector over
  Cilium identity labels, e.g. `app=web,tier!=db`), `service`
  (`namespace/name`).
- Or `from` and/or `to` (not with the scope): endpoint specs
  `namespace/pod` (prefix), `svc:namespace/name`, `ns:namespace`,
  `fqdn:name` or an IP.
- Narrowing either: `verdict` (`FORWARDED`, `DROPPED`, `ERROR`, `AUDIT`, …,
  comma-separated), `protocol` (`tcp`, `udp`, `icmp`, `http`, `dns`, …),
  `port` (destination ports), `direction` (`ingress`/`egress`).
- History: `since` (a Go duration), `last` (at most 10000), `follow`.

Flow: `{time, verdict, dropReason? (e.g. POLICY_DENIED), direction?
(INGRESS/EGRESS), isReply?, type? (L3_L4/L7/SOCK), source, destination, l4?:
{protocol, flags?}, l7?: {kind, latencyMs?, http?: {method, url, code},
dns?: {query, rcode, ips}}, node?, event? (observation point), policies?:
{allowedBy?, deniedBy?: [{kind, namespace, name}]}}`. An endpoint is
`{namespace?, pod?, workloadKind?, workloadName?, service?, ip?, port?,
identity?, names? (DNS names), reserved? (world, host, remote-node,
kube-apiserver, … for non-pod endpoints)}`. Policies need Cilium's policy
correlation (`hubble-network-policy-correlation-enabled`).

**Traffic map** (`/api/hubble/map`). The relay holds seconds of history, so
the backend counts: the first request starts following the relay for the
current context, and later requests read the counts. It keeps counting
while asked (the app polls every 2 s while the Map tab is on screen) and
stops a minute after the last request, after which the gRPC connection
closes too. One map per context is shared by every viewer.

- Nodes are namespaces, or reserved ids for endpoints outside any:
  `reserved:world` (Cilium's world identities and CIDR identities),
  `reserved:ingress` (Cilium Ingress / Gateway, which is where traffic from
  the world usually shows up, as Envoy's connections to pods),
  `reserved:host`, `reserved:remote-node`, `reserved:kube-apiserver`,
  `reserved:health`, `reserved:init`, `reserved:unmanaged`, and
  `reserved:unknown` (an identity with no namespace in the flow). An edge
  with `from == to` is traffic within a namespace.
- Each flow is counted once. The relay is asked only for to-endpoint
  traces, traces leaving a node for a reserved identity or the world, and
  drops, without replies (event-type, reply, identity and label filters,
  and a field mask of ~20 fields): about a quarter of all flows on a busy
  cluster. Pod-to-pod traffic counts where it reaches the destination pod
  (not again where it left the source node); socket-LB traces, L7 records
  and policy-verdict events aren't counted. The same rule is applied again
  as flows are added.
- `flows` are forwarded (and audited), `drops` dropped; `rate` is flows a
  second over the last 20-40 s (0 for a pair that went quiet). `ports` are
  destination ports as `PROTO/port`; `peers` the world side of world edges
  (a DNS name when Hubble knows one, from `destination_names`, else the IP);
  `fromWorkloads`/`toWorkloads` as `Kind/name`; `reasons` drop reasons.
  Each list has the top 5 by count, `{name, n}`, with the rest summed under
  `name: ""`.
- `since` is where the counts really start: later than `now - window` while
  the map is younger than the window. `lost` is what the relay reported it
  couldn't deliver: the counts are then a lower bound. A stream whose
  readers keep losing more than they deliver (a node's buffer overtook its
  reader) is restarted from the head. `state` is `error` while the stream is
  reconnecting (with backoff); counts so far are kept.
- Bounded: 20-second buckets for 15 minutes (46), at most 512 pairs per
  bucket (more are counted in `uncounted`), and per pair and bucket at most
  5 ports, 5 world peers, 3 workloads each side and 3 drop reasons, with
  strings shared. Worst case about 15 MB; measured about 3 MB of heap with
  30 namespaces and ~180 pairs, and 3-6% of one core at ~1,200 counted
  flows a second.

- `names` labels the IP peers present in `edges` (not DNS-name peers).
  `source: "cluster"`: a cluster object owns the address (`node/<name>` for
  node addresses, `svc/<ns>/<name>` for LoadBalancer ingress IPs,
  `externalIPs` and the clusterIP, `ingress/<ns>/<name>`,
  `gateway/<ns>/<name>`), read from the shared watch cache. `source: "rdns"`:
  a PTR record, for public addresses only (not private, loopback, link-local
  or CGNAT), looked up in the background (at most 4 at once, 2 s each) and
  cached for 1 hour (10 minutes for misses), so names appear on later polls;
  a request never waits for DNS. Cluster objects win over PTR records.

The Health overview adds `hubbleRelayUnreachable` (warning, on the relay
Service) and `hubbleDrops` (warning, per namespace with at least 5 drops in
the last 5 minutes, or as far back as the relay holds; a drop counts for the
destination pod's namespace, else the source's). Both come from cached
results refreshed in the background (status 30s, drops 1 min), so an
overview poll never waits on the relay and the first one after starting has
none.

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
- otherwise set by `"remoteIcons": true | false` in `~/.config/k8sman/settings.json` (Settings ▸ Clusters, `PUT /api/settings/icons`);
- otherwise automatic: on only when the current context looks local (kind-, k3d-,
  minikube, docker-desktop, rancher-desktop, orbstack, colima or microk8s contexts, or a
  loopback API server).

With remote fetches off, icons already in the cache are still served; nothing new is fetched.
Bundled icons and monograms always work.

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/icons` | `{"<group>": {source, url?, asset?, release?}}` for every custom (CRD) group on the cluster. `release` is the Helm release as `namespace/name` |
| GET | `/api/icons/{group}` | the icon image (`Content-Type: image/png` or `image/webp`, header `X-Icon-Source: helm|favicon`). For bundled and missing icons: 404 `{error, code, source, asset?}` with `X-Icon-Source: bundled|none`. 400 for an invalid group name |
