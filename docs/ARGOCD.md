# Argo CD support

k8sman treats Argo CD's custom resources as first-class objects. It talks only
to the Kubernetes API with your kubeconfig. It needs no Argo CD API server, no
`argocd` CLI login and no SSO.

## What's supported

**Navigation and tables.** When the `argoproj.io` CRDs are served, an
**Argo CD** group appears in the nav with Applications, ApplicationSets and
AppProjects. Built-in columns (`backend/internal/columns/builtin.go`):

| Type | Columns |
|---|---|
| Applications | Sync, Health, Revision (short SHA), Repo (`org/repo`), Path/Chart, Destination (`cluster/namespace`), Project, Age |
| ApplicationSets | Generators (`list`, `matrix(git + clusters)`, ...), Apps, Status, Age |
| AppProjects | Destinations, Sources, Description, Age |

**Application panel** (`frontend/lib/panels/argocd/application_panel.dart`)

- Status card: sync and health in Argo's colours and icons, inline **Sync** and
  **Refresh / Hard refresh** buttons, the current revision (short and copyable)
  against the target revision, the auto-sync, prune and self-heal flags, sync
  options, retry policy, the last sync, when it was last compared, and images.
  Error conditions (ComparisonError, SyncError, InvalidSpecError and so on) show
  as red callouts and warnings as amber ones. A running sync shows a callout
  with a **Terminate** button.
- Last operation: phase, message, who started it (a user, or automated),
  start and finish times and duration, revision, options, retries, and the
  resources that failed to sync, each linked to its object.
- Sources: single or multi-source. Shows the repo URL (copyable), path or
  chart, target and resolved revision, and any `ref`. For Helm: release name,
  value files, parameters and inline values. For Kustomize: images, name
  prefix and suffix, labels, replicas and patches. Directory and plugin
  settings are shown too.
- Destination: the cluster, the namespace (linked to the Namespace when it is
  in-cluster), the project (linked to the AppProject), ignored differences and
  managed namespace metadata.
- Managed resources: `status.resources` grouped by kind, with a sync badge and
  a health badge, problems first, and filters for All, Out of sync and
  Unhealthy. Each row links to the live object. A **Tree** toggle shows the
  ReplicaSets and Pods underneath, built from ownerReferences. Resources that
  need pruning are marked.
- Sync history from `status.history`.
- An "Open in Argo CD" link appears when the `argocd-cm` ConfigMap sets `url`.

**Per-resource health.** Argo CD 3 keeps resource health in its resource tree
in Redis, not in `status.resources` (`status.resourceHealthSource: appTree`). When the
health isn't persisted on the CR, k8sman lists the live objects (one list per
kind and namespace) and works out their health with the same rules as Argo's
built-in checks (`frontend/lib/panels/argocd/live_health.dart`). A resource
that isn't in the cluster shows as Missing. Kinds that Argo has no check for
show "—". If the CR does carry health (Argo CD 2.x, or
`controller.resource.health.persist: "true"`), k8sman uses that instead.

**ApplicationSet panel.** A health summary, the generators in readable form
(list elements as a table; cluster selectors; git directories and files;
matrix and merge nested; SCM provider and pull request; a post-filter
`selector`), the template's key fields and sources, the generated Applications
with their sync and health, `applicationsSync`, `preserveResourcesOnDeletion`,
the RollingSync strategy steps, and the conditions.

**AppProject panel.** A summary that says whether the project is restricted or
unrestricted, and whether syncs are allowed now. Then the Applications in the
project, the source repos, the destinations, the allow and deny lists for
cluster-scoped and namespaced kinds (with Argo's defaults spelled out: no
cluster allow list means none are allowed), sync windows with an
"active now" indicator, roles with their policies as a table, and the
orphaned-resources settings.

**Cluster overview.** Argo apps with problems become issues
(`backend/internal/overview/argocd.go`). Failed syncs and error conditions are
critical, and so is Degraded. Missing and OutOfSync are warnings. Each app is
reported once, in its worst category. They only appear when the Application
CRD is served, and are filtered to apps that live in the selected namespace or
deploy to it.

## Actions, without the Argo CD API server

All three actions are backend actions (`backend/internal/server/argocd.go`) on
`applications.argoproj.io`. They are refused when the backend runs with
`--read-only`, and the UI hides them in that case.

| Action | What it writes | Equivalent |
|---|---|---|
| `argocd-refresh` | annotation `argocd.argoproj.io/refresh: normal` (or `hard`) | `argocd app get --refresh` / `--hard-refresh` |
| `argocd-sync` | merge patch setting `.operation` = `{initiatedBy: {username: k8sman}, sync: {revision, prune, dryRun?, syncOptions, source or sources}, retry?}` and clearing `status.operationState` | `argocd app sync` |
| `argocd-terminate` | `status.operationState.phase: Terminating` | `argocd app terminate-op` |

This is exactly what the Argo CD API server does:

- `Sync` builds an `Operation` and calls `argo.SetAppOperation`. That refuses
  when `.operation` is already set, writes `.operation`, and clears
  `status.operationState`.
- `TerminateOperation` sets `status.operationState.phase = Terminating` with an
  ordinary update. Applications have no status subresource.

The application controller does the rest. It picks up `.operation`, resolves
the revision and runs the sync. For a Terminating operation it stops the sync
and doesn't retry. The controller uses the same mechanism for its own sync
timeout. Every patch carries the object's `resourceVersion`, so a concurrent
change gives a 409 instead of being overwritten.

Like the API server, the sync action:

- refuses while an operation is pending or running, unless `force` is set;
- refuses a revision other than the target on an auto-sync app (dry runs are
  allowed);
- uses the app's `syncOptions` and retry policy when you don't override them.

**Verified on Argo CD v3.5.7.** A sync of `helm-guestbook` from k8sman ran to
`Succeeded`, with `initiatedBy.username: k8sman` in the operation state and
history. A hard refresh was picked up and the annotation was removed. A
terminate on a retrying sync stopped it.

In the UI, **Sync** opens a dialog with options for prune, dry run, "apply out
of sync only" and an optional revision. When an operation is in progress, it
also offers to replace it. Then the standard `confirmAction` confirmation
follows. On a non-local context, a sync with prune asks you to type the app
name. Refresh doesn't ask for confirmation, because it only asks the
controller to compare again.

## Limits

- **No live diff and no rendered manifests.** The diff and manifest
  generation happen in the repo server and controller, behind Argo's API.
  k8sman shows which resources are out of sync, but not how they differ.
- **RBAC is kube RBAC, not Argo RBAC.** Anyone whose kubeconfig can patch
  `applications.argoproj.io` can sync any app. Argo's project roles, SSO
  groups and `argocd-rbac-cm` policies don't apply. Sync windows are enforced
  by the API server, so a sync from k8sman is not blocked by a deny window.
  The project panel shows whether a window is active, but k8sman doesn't
  enforce windows.
- No selective sync of single resources, no rollback to a history entry, and
  no "sync with replace" or server-side apply toggles beyond what you can
  type as sync options.
- Sync windows in a non-UTC `timeZone` show "active: ?" because the app has no
  time zone database.
- Resource health is worked out on the client for Argo CD 3 (see above). Custom
  Lua health checks are not applied, so for CRDs with custom checks k8sman
  shows "—".
- Multi-cluster: resources deployed to remote clusters can't be linked or
  checked, because k8sman only sees the cluster in your current context.
- There is no install flow from the Argo CD views. When Argo CD is missing,
  its nav group simply doesn't appear. The shared add-on catalog
  (`frontend/lib/addons/addons.dart`, `AddonIds.argoCd`) is the place to offer
  installs once the Add-ons page exists.

## Trying it

Argo CD v3.5.7 and the sample objects in `dev/argocd/samples.yaml` are
installed in the dev kind cluster:

```sh
kubectl create namespace argocd
kubectl apply -n argocd --server-side -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.7/manifests/install.yaml
kubectl apply -f dev/argocd/samples.yaml
```

The samples:

- `guestbook`: auto-sync, Synced and Healthy.
- `helm-guestbook`: manual sync, with Helm parameters and values.
- `kustomize-guestbook`: manual sync and OutOfSync, with Kustomize images, a
  name prefix and labels.
- `guestbook-degraded`: a bad image and a 60s progress deadline, so it goes
  Degraded.
- `guestbook-no-namespace`: SyncError, because the destination namespace
  doesn't exist.
- `bad-path`: ComparisonError.
- `multi-source`: Helm chart plus a `$values` ref.
- The `demo-team` AppProject, with restrictions, roles and sync windows.
- The `guestbook-envs` ApplicationSet, whose list generator produces
  `guestbook-dev` and `guestbook-staging`.

## Recommended next steps

1. **Optional Argo CD API server integration.** Let the user log in with a
   token or port-forward to `argocd-server` to get live diffs
   (`/api/v1/applications/{name}/managed-resources`), rendered manifests, the
   full resource tree with health from Redis, app logs, and actions that
   enforce sync windows and Argo RBAC. Keep the kube-only path as the
   fallback.
2. **Diff without the API server.** Compare `kubectl.kubernetes.io/last-applied-configuration`,
   or a server-side dry-run apply, against the live object for out-of-sync
   resources. This is cheap and covers many cases.
3. **Selective sync and rollback.** Sync only the out-of-sync or checked
   resources (`operation.sync.resources`), and roll back to a history ID.
4. **Multi-cluster destinations.** Map cluster Secrets
   (`argocd.argoproj.io/secret-type: cluster`) to kube contexts so remote
   resources become links.
5. **Argo Rollouts.** A Rollout panel with canary and blue-green steps,
   promote, abort and retry, and analysis runs. Argo CD apps often manage
   Rollouts.
6. **Notifications.** Show `notifications.argoproj.io` subscriptions and the
   `notified.notifications.argoproj.io` state on apps.
7. **Overview tile.** Show `counts.argoApps` as a summary tile on the health
   page, next to the categories.
8. **Install via the add-on catalog** when the Argo CD CRDs are missing.
