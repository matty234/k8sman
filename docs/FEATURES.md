# All features

Everything k8sman does, by area. The [README](../README.md) has the tour.

## Cluster and navigation

- Kubeconfig picker: files from `$KUBECONFIG`, `~/.kube` or anywhere on disk
  (**Choose file…**), with recents and the last context used in each file.
- Context switcher in the sidebar.
- Automatic discovery of every API resource, CRDs included, plus a
  **Rediscover** button.
- CRD group icons: from the Helm chart that installed the CRD, bundled icons
  for well-known projects, the group's website favicon, or a generated
  monogram. Internet fetches are on by default only for local clusters.
  Change it in **Settings ▸ Clusters** (`"remoteIcons"` in `settings.json`),
  or pass `--no-remote-icons` to turn them off whatever the setting.
- **Settings** (⌘, / Ctrl+,, the gear at the bottom of the sidebar, the
  palette's **Settings…** or `:settings [section]`) holds every setting on
  one page: General (launch view, update checks), Clusters (kubeconfig files,
  read-only contexts, remote icons), Sidebar (pages, pins and their order),
  Views, Integrations, Tables (reset a kind's saved sort, widths and filter),
  Keyboard (the shortcut list) and About. A search box filters across
  sections. Changes apply and save as you make them; Esc goes back.
- A calm sidebar: Overview, Nodes and Security up top, the rest under
  **More**, collapsible sections and a **Custom Resources** group, plus **Search or jump to… ⌘K**
  (the command palette).
- Back / forward through where you've been (pages, kinds, opened objects): the mouse's side buttons, ⌘[ / ⌘] (Ctrl+[ / Ctrl+]; not while typing in a field or editor), or the palette's **Go Back** / **Go Forward**. Up to 100 steps, cleared when the context changes.
- A searchable namespace picker with recents. Tick several namespaces to see
  them together (`team-1, team-2 +2`): clicking a name shows only that one,
  its checkbox (or ⇧Return) adds it to the set. `:ns a,b` picks a set from
  the palette, `:ns +a` / `:ns -a` changes it.
- Namespace favourites and selection chips: star a namespace in the picker (the
  star shows on hover) and it is listed under Favourites, above Recent, saved
  per context. A multi-namespace selection shows as "3 namespaces" on the
  button, and as removable chips with Clear inside the picker. Removing the
  last one falls back to the kubeconfig namespace, else All.
- Cluster icon and colour: right-click the context switcher (or a context in
  its list, or use Settings > Clusters) for "Change icon & colour...": about
  thirty outlined icons or a 1-2 character monogram, and ten palette colours
  (or Default). The badge shows in the sidebar header, the switcher list and
  Settings > Clusters. Saved per context in settings.json, local only, so it
  works on read-only contexts.
- Namespace sets work for users whose access covers only those namespaces:
  each namespace is watched on its own and merged. A namespace you can't
  read shows a banner ("No access to team-5 (forbidden)") while the others
  load.
- Per-page namespace scope: Overview, Alerts, Metrics and Security default to
  all namespaces, independent of the table's namespace, and accept a set
  too.
- Pins can be scoped to a namespace or a set of namespaces.
- No permission to list namespaces? The picker says so and lets you type a
  namespace ("Use namespace ...") to add it. Typed namespaces are remembered
  per context ("added by you", with a remove button) next to the kubeconfig
  context's own namespace. The app opens in the kubeconfig namespace, else
  the first remembered one, else `default`.
- **Links**: Copy link (row menu, inspector ⋯, a kind's or a page's
  right-click menu in the sidebar or table header) copies
  `https://k8sman.dev/o/?kind=…&group=…&ns=…&name=…#c=…&ctx=…`, which opens
  the same object, table or page in a colleague's k8sman or offers the
  download. Hold ⌥ (or turn on Settings > General > Links) for the
  `k8sman://open?…&c=…&ctx=…` form, registered on macOS, Windows
  (installer) and Linux (`.desktop`). `c` is the cluster's fingerprint (12
  hex characters of SHA-256 over its normalised API server URL), so a link
  finds the cluster even when your context for it has another name; `ctx`
  is the sender's context name. On the web form both sit in the `#`
  fragment, which browsers don't send to k8sman.dev. A link carries only
  that hash, the context name, namespace, kind and name, never the server
  address. The hash isn't secret, though: someone who knows or guesses a
  server address can check whether a link is for it. Opening a link only
  navigates (read-only contexts stay read-only) and finds the context by a
  remembered choice for that cluster, then by fingerprint (several matches:
  the current context, then the one named like `ctx`, else a chooser), then
  by name (said in the prompt); a switch asks first. A cluster you don't
  have offers "Choose a context…", with "Always open links for this cluster
  here". Settings > Clusters > Links shows each context's fingerprint and
  the remembered choices. Older links with `ctx` in the query still open.

## Saved views

- **Save view…** (the bookmark in the table toolbar, or ⌘K → Save Current
  Table as View): the kind, namespaces, filter, sort and the table's columns,
  under a name. New views apply to **any context**; **Only <context>** binds
  one to the current context.
- A **Views** section in the sidebar lists views for any context and those
  bound to the current one. ⌘K and `:view <name>` list every view; one bound
  to another context shows its context and ⇄, and opening it switches there
  through the usual connect.
- While a view is open its filter, sort and columns are its own: changes
  don't touch the kind's remembered settings. The title shows the view's
  name, a dot when it has changed, and **Update View** / **Revert**.
  Choosing another kind, namespace or context closes the view.
- Right-click a view: Rename, Duplicate, Only on <context> / Apply to Any
  Context, Export to File…, Copy as YAML, Open at Launch, Delete (with
  Undo). Right-click the section header: Import Views… (paste, or From
  File…), Import from File…, Export All Views to File…, Copy All Views as
  YAML and Reorder Views…. Drag views to reorder them in **Settings ▸ Views**,
  which also renames, deletes, imports and exports them.
- **⌘S** saves the table as a view, or updates the open view. `:view save
  <name>` saves it from command mode. A view's kubeconfig matches by the
  file it resolves to, so the default kubeconfig and an explicit
  `~/.kube/config` are the same context.
- A view bound to a context that isn't in the kubeconfig never opens on
  another one by itself: k8sman offers to **re-point** it (contexts with the
  same API server URL first) or make it apply to any context. Importing does
  the same, re-pointing automatically when exactly one context has the
  view's API server URL.
- Namespaces of a view that the cluster doesn't have show struck through in
  the picker; namespaces you can't read show a banner (on Overview, Security and Metrics
  Top too) while the rest load.
- The connecting and cluster error screens list views bound to other
  contexts, so a dead context isn't a dead end. **Open at Launch** opens a
  view instead of reconnecting to the last context (straight to its context
  when it is bound to one).

## Tables

- Live tables over watches for every kind.
- jq-defined columns with a column editor (live preview, field picker, column
  types), saved per resource type. Besides jq's own functions, queries can
  call `podstatus`, `deploymentstatus`, `statefulsetstatus`,
  `daemonsetstatus`, `jobstatus`, `nodestatus`, `noderoles`,
  `condition("Ready")`, `duration(start; end)`, `selector`, `tobytes` and
  `base64size` (see `backend/internal/columns/helper_funcs.go`).
- Sorting, including quantity-aware sorting. A filter that combines terms
  (`status=Running restarts>3`, `status!=Running`, `memory>256Mi`, `age<1h`)
  and suggests columns and their values as you type. `!text` (or `-text`)
  excludes rows containing it, `!status=Running` negates a column term, and
  `/regex/` or `name=/^web-\d+/` match by case-insensitive regex; an invalid
  regex outlines the box in red and matches nothing.
- Drag headers to reorder columns and dividers to resize them; double-click a
  divider to fit the column to its widest text (up to 600px; again to reset);
  sort, widths and
  filter are remembered per kind across launches.
- Multi-select with ⌘-click, ⇧-click, ⌘A and ⇧↑/⇧↓. Bulk delete and restart
  show progress and a failure report.
- A right-click menu: Open, Copy name, Copy namespace/name, Copy YAML, and
  the kind's actions.
- **Copy kubectl command…** (row menu, multi-select menu and the inspector's
  ⋯ menu): `get -o yaml`, `describe`, Pod `logs -f` / `exec -it`, and
  `rollout restart` / `status` for workloads, with `-n`, `--context` and
  `--kubeconfig` as the app has them. Several rows give one command per
  namespace.
- Usage columns from metrics-server: Pods and Nodes show CPU and Memory as
  the value, a small bar and the percentage of the pod's limit (else its
  request; nodes: allocatable), amber from 70% and red from 90%. Sorting
  orders by the percentage (pods with neither limit nor request rank below
  the rest, by value); filter on the value (`cpu>500m`, `memory>1Gi`) or the
  percentage (`cpu%>80`, `cpu>80%`). Under ~90px wide only the value shows.
- Empty in this namespace? A **Show all namespaces** button.
- Clear error states for unreachable, timed-out, unauthorized, forbidden and
  not-found clusters, and for a backend that's down, each with Retry.

## Inspector

- Collapse it to a slim tab with ⌘I. Tabs switch instantly, back navigation
  works, and panels cross-link related objects.
- A metadata summary: namespace, owners, age, labels and annotations.
- An **Owns** section for any object lists what it owns (objects whose
  ownerReferences name its uid), grouped by kind with status badges. A child
  opens on click and a chevron expands its own children, as a tree. It is read
  from the watch cache, so it searches common child kinds plus kinds already
  cached, and says so when some were not searched. Hidden on workload panels
  that already list their children.
- A YAML view and editor with dry-run validation, diff review before apply,
  conflict detection and ⌘S. Optionally show managedFields.
- **Edit status…** (⋯ and right-click menus, palette) opens the editor on the `status` subresource of custom resources that have one, for hand-fixing an operator's `.status` while it is scaled down (built-in kinds aren't offered: the kubelet or a controller rewrites their status within seconds); only `.status` is saved and the diff shows only it. **Scale…** does the same for the `scale` subresource on kinds without a replica stepper (CRDs such as Argo Rollouts).
- **Open in Editor** (in the YAML tab) opens the object in a full-window
  split-screen editor: YAML on the left; on the right a resizable, collapsible
  pane with a debounced live diff against the server and a Validation tab.
  The title bar shows the kube context (amber when not local) and namespace.
  A "changed on the server" notice appears when the object moves on. ⌘S
  validates, reviews the diff and applies; ⌘↩ goes straight to the confirm;
  Esc closes the find bar, then the editor (warning about unsaved changes).
- **New Resource**: the same editor in create mode, with templates for
  Deployment, Service, ConfigMap, Secret (stringData), Job, CronJob, Ingress,
  PersistentVolumeClaim, Namespace, ServiceAccount, Role + RoleBinding and
  Blank (or a skeleton for any kind, CRs included), in a namespace you pick.
  Validate dry-runs every document and lists the result per object, with
  field errors mapped to editor lines. Create confirms with the context named,
  then offers to open what it made. When objects already exist you can retry
  with server-side apply. Read-only contexts get a read-only editor.
- An Events tab, and header actions for the kind.
- Panels by kind:
  - **Pod**: why it isn't ready, containers, probes, env references, volumes,
    scheduling, QoS, usage, and history charts with Prometheus.
  - **Deployment, StatefulSet, DaemonSet, ReplicaSet**: rollout status, a scale
    stepper, HPA and PDB. Deployments also get rollout history with rollback.
  - **HorizontalPodAutoscaler, PodDisruptionBudget**: their own panels. PDBs
    warn when they would block drains.
  - **Job, CronJob**: the cron schedule in plain English, the next runs,
    **Run now**, suspend and resume, missed-schedule warnings and job history.
  - **Service, Endpoints, EndpointSlice, Ingress, IngressClass,
    NetworkPolicy**: endpoint diagnosis, and NetworkPolicies explained in
    plain English.
  - **ConfigMap, Secret**: which workloads use them. Secret values stay masked
    until you reveal them.
  - **ConfigMap, Secret, ServiceAccount**: a "Used by" section groups the
    referencing pods under their Deployment, StatefulSet, DaemonSet or CronJob
    (workloads scaled to zero included) and shows how each one references it.
  - **ServiceAccount**: effective permissions. **Role, ClusterRole and
    bindings**: dangerous grants are flagged.
  - **PersistentVolumeClaim, PersistentVolume, StorageClass**: diagnoses for
    pending and resizing volumes. The PVC table's **Used** column shows how
    full each volume is (from Prometheus, or the kubelets when Prometheus
    doesn't have it) as "12 / 50 Gi", a bar and the percentage, amber from 80% and red from 90%; filter with `used>80` (percent) or `used>10Gi`.
  - **Node, Namespace, ResourceQuota, LimitRange, Event, APIService.**
  - **CustomResourceDefinition**: a schema browser. **Any custom resource**: a
    generic panel that summarises status and conditions.
  - **Argo CD** Application, ApplicationSet and AppProject (see above).
  - **Gateway API** Gateway, GatewayClass, routes and ReferenceGrant (see above).
  - **Dynamic Resource Allocation** (`resource.k8s.io`, v1 or the beta
    shapes) ResourceClaim, ResourceClaimTemplate, DeviceClass and ResourceSlice
    in a "Dynamic Resources" sidebar section (only where served), with state,
    device and node columns; Pods list their claims and Nodes their devices,
    and Settings ▸ Integrations counts claims and pending ones. A bundled
    plugin (see [PLUGINS.md](PLUGINS.md#bundled-plugins)), which replaced the
    module.
  - **External Secrets Operator** (`external-secrets.io`, v1 or v1beta1)
    ExternalSecret, ClusterExternalSecret, SecretStore, ClusterSecretStore and
    PushSecret in an "External Secrets" sidebar section (only where served):
    sync status and error message, store and target Secret links (with a
    warning when the Secret is missing), data mapping, provider settings
    (auth Secrets as links, never values), "Refresh now" (sets `force-sync`),
    "ExternalSecrets not synced" alerts on the Overview (critical after a
    day), a status line in Settings ▸ Integrations, and "Managed by
    ExternalSecret" on the Secret it owns (that line is core). A plugin
    from the Marketplace, bundled up to 0.2.16 (see
    [PLUGINS.md](PLUGINS.md#bundled-plugins-moved-to-the-directory)); it
    replaced the module.
  - **Kyverno** (`kyverno.io` and `wgpolicyk8s.io`) ClusterPolicy and
    Policy (rules, status, and the results they produced), PolicyReport and
    ClusterPolicyReport (summary and results, failures first), exceptions,
    cleanup policies and 1.14+ `policies.kyverno.io` kinds in a "Kyverno"
    sidebar section (only where served), and a status line in Settings ▸
    Integrations. Any object that owns policy reports (Kyverno 1.10+ writes
    one per resource) gets a **Policy results** tab, failures first; on Pods
    and workloads the results are a section of the Security tab. A plugin
    from the Marketplace, bundled up to 0.2.16 (see
    [PLUGINS.md](PLUGINS.md#bundled-plugins-moved-to-the-directory)); it
    replaced the module.
  - **cert-manager** (`cert-manager.io`) Certificate, CertificateRequest,
    Issuer and ClusterIssuer in a "cert-manager" sidebar section after Network
    (only where served): Ready, Issuer and Expires columns, a Certificate panel
    with expiry warnings, its Secret (names and keys, never values), issuer
    and requests, the Prometheus expiry, "Certificates expired / expiring /
    not ready" alerts, a status line in Settings ▸ Integrations, **Renew** and
    **cmctl status** (run `cmctl` in the dock; every run asks, hidden on
    read-only contexts) and **Set renewal time…** / **Private key
    rotation…** (a dry run, then your confirmation). A plugin from the
    Marketplace, bundled up to 0.2.16 (see
    [PLUGINS.md](PLUGINS.md#bundled-plugins-moved-to-the-directory)); a short
    example is in `examples/plugins/cert-manager`.
  - **Admission** (`admissionregistration.k8s.io`) Validating and Mutating
    admission policies and their bindings, and Validating/Mutating webhook
    configurations, in an "Admission" sidebar section (only where served):
    match rules, CEL (matchConditions, variables, validations, mutations) with
    copy, type-check warnings, the bindings using a policy, and each webhook's
    target and failure policy.
  - **Prometheus Operator** Prometheus (what it selects, target health by
    pool), Alertmanager (running routing tree, receivers, inhibit rules,
    alerts by receiver, silences; secrets redacted), AlertmanagerConfig (route
    tree, receivers by kind, which Alertmanagers load it and for which
    alerts), PrometheusRule (live rule state), ServiceMonitor, PodMonitor,
    Probe and ScrapeConfig (live target health, which Prometheus picks them up).
  - A **Monitoring tab** on Pods, Services and workloads: whether it's
    scraped, by which monitor or scrape config (target health, last scrape,
    errors), and if not, why: the monitors that come close and the check that
    fails (namespace, selector, port name, the Prometheus selectors). Also the
    alerts about it and, as a labelled guess, the rules that apply.
  - A Prometheus or Alertmanager that discovery can't find (Mimir, Thanos
    query-frontend, VictoriaMetrics under a path such as `/prometheus`) can be
    set by hand per context in Settings > Integrations > Prometheus
    (namespace, service, port, path prefix); its reachability shows there.
  - History charts offer 10m, 15m, 1h, 6h, 1d and 1w, and the Prometheus
    settings choose the range charts first open with.
  - Pod history charts mark the pod's events (and container starts and
    restarts from its status, which outlive events) as ticks under the time
    axis: grey Normal, amber Warning, red for OOMKilled, BackOff and failed
    probes. Hovering a tick shows the event in place of the value readout.

## Bottom dock: alerts, logs and terminals

- A permanent bar along the main column. Its first tab is **Alerts**, with a
  badge counting firing critical alerts; click it to open the alerts list
  without leaving the page you're on.

- Log tabs with search, highlighting and "only matching" filtering, follow,
  previous instance, timestamps, wrap, initial lines, Copy all and Clear.
- Log viewer extras: a `.*` toggle beside search makes it a case-insensitive
  regex (invalid patterns show a red outline and match nothing); the history
  picker also loads by time (`since 5m` to `1d`, sent as `sinceSeconds`, up to
  the 10,000-line buffer); the **⋯** menu has **Newest first** (newest line on
  top, following pins the top; also Settings ▸ General) and **Download logs…**
  (shown lines, or only the matching ones, to `<pod>-<container>-<time>.log`;
  aggregates are named `<workload>-logs-<time>.log` and keep the pod prefix).
- Aggregated logs (k9s style): **Logs** on a Deployment, StatefulSet, DaemonSet,
  ReplicaSet, Job or Service, or `l` / **Logs (N pods)** on two or more selected
  pods, opens one tab merging every pod's logs in timestamp order. Each line
  has a fixed-width, colour-coded prefix (the pod name minus the prefix its
  siblings share, plus `/container` with **All containers**); hover shows the full
  name and a click opens the pod in the inspector. The tab follows the pod set
  live (new pods start streaming, deleted ones stop, with a dim divider line),
  shows a live pod count, and has a **Sources** menu to hide pods or containers.
  Search also matches the pod name. Up to 50 pods; a warning shows beyond that.
  **Previous** shows each container's previous instance (containers without one
  are skipped) and stops following the pod set. Each pod's default container is
  its `default-container` annotation, else `main`, else the first.
- **Logs** on an Argo Workflow opens one such tab for all its step pods
  (`main` container), following new steps live.
- Terminals into any container, with automatic shell detection
  (zsh → bash → ash → sh). Font size is adjustable (⌘+ / ⌘− / ⌘0) and ⌘K clears.
- An ephemeral debug container for distroless images that have no shell.
- Local shells (macOS and Linux): **+** opens your login shell on this
  machine. Its `KUBECONFIG` puts a context-only file in front of your
  kubeconfig, so `kubectl` and friends target the context on screen while
  your kubeconfig and other terminals stay as they are. On a read-only
  context it prints a warning: commands there use your own credentials.
- ⌘J expands or collapses the dock. It sits beside the inspector, like Xcode's debug area.

## Port-forwards

- One-click forwards from Pod container ports and Service ports, and forwards
  to workloads.
- Supervised: a forward reconnects to a new ready pod when its pod goes away.
- They persist across launches, with optional auto-start, and are restarted
  after an update relaunch.
- A **Forwards** tab in the bottom dock with start, stop, remove, labels,
  Open in browser and Copy URL. Its badge counts running forwards (amber
  while one reconnects, red if one fails), and it flashes when you start one.
- **Stop all** in the Forwards tab (or the palette's **Stop All Port Forwards**) stops every running forward after a confirmation, offering this cluster or all clusters when forwards span several. Starting a forward on a local port another forward of ours holds offers **Replace it** or the next free port; a port held by another process only suggests a free one.
- The start dialog defaults the local port to the remote port when it is free and 1024 or above, else the next free port (`80` suggests `8080`); one-click forwards pick the same way. **Open in browser when it starts** and **Use https** are remembered with the forward (Start on a saved forward honours them). **Don't remember this forward** keeps it out of the saved set, so it is gone after a restart.
- A saved forward whose pod, service or workload no longer exists (a 404) is dropped quietly when k8sman starts, with a dismissable "2 saved forwards were removed (their targets are gone)" note in the Forwards list. Other errors keep the forward and show as its own warning.

## Pages

- **Overview** (the page the app opens on at launch, unless a saved view is
  set to open instead): cluster health grouped by owning workload, with quick
  fixes and top warning events. It appears as soon as pods are listed;
  slower sources (other workload kinds, nodes, alerts, Argo CD, ...) show
  placeholders in their tiles and sections, never "All healthy", and fill
  in within a few seconds.
- **Alerts** (in the bottom dock): Alertmanager alerts, silences (create,
  expire, "why is this silenced?") and runbook links.
- **Nodes**: the one home for nodes (the sidebar has no separate Node
  table). **Overview | Table** beside the title switches between the page's
  own list and the Node table in place, with its columns, filter language,
  sorting, multi-select, k9s keys, bulk actions and saved views. The last
  mode is remembered (saved with the kind's table settings). `:nodes`,
  `:no`, ⌘K "Nodes" and any link to the Node kind open the page in that
  mode; a saved view of nodes, or a filtered link such as the Overview's
  "nodes not ready", opens the Table; a link to one node opens it in the
  inspector. Switching modes replaces the history entry rather than adding
  one. The Overview is a sortable table like the GPUs page's: a row per node
  (ready dot, name, roles, kubelet version, age, CPU and memory usage cells,
  pods used of capacity, chips for NotReady, pressure, cordoned, taints and
  GPUs), grouped under a header with totals per node pool when nodes carry
  a pool label (`eks.amazonaws.com/nodegroup`,
  `cloud.google.com/gke-nodepool`, `karpenter.sh/nodepool`,
  `kubernetes.azure.com/agentpool`), else a flat list. Expand a node to see
  its pods: problem pods (not running or ready, restarting) first, then the
  busiest, with namespace, status, restarts, age and usage against their
  limit or request; **Show all N** past 15; click one to inspect it. The
  list shows as soon as nodes and pods are listed; usage from metrics-server
  fills in after, with placeholders of the same size until it does. Nodes
  also have cordon/uncordon and **drain** in their ⋮ menu. Drain works like `kubectl drain
  --ignore-daemonsets`. It first shows the pods it will evict, what it skips
  (DaemonSet and mirror pods), and anything blocking it. Options cover
  emptyDir data and pods without a controller. Evictions respect
  PodDisruptionBudgets, retrying for up to 5 minutes.
- **Helm**: releases, values, manifest, hooks, history diffs, rollback,
  upgrade with a dry-run diff (optionally to an `oci://` chart, with a
  searchable list of the registry's versions using your `helm registry login`
  credentials), uninstall, and stuck-release recovery.
- **Security**: network exposure, RBAC risk (including unused privileged
  ServiceAccounts), Pod Security, best practices, Trivy image CVEs, and
  **Copy for AI**. It loads progressively: it answers after about a second
  with the categories whose lists are in; the rest show placeholders (never
  "0 findings") and the score waits, while the page re-fetches quickly until
  everything is in. Findings can be ignored (this finding, this check in a
  namespace, or this check everywhere, with an optional reason): they leave
  the list, score and Copy for AI, and stay one click away under "N ignored".
  Rules are per context and listed in Settings.
- **Upgrade readiness** (a module, under More): what an upgrade from the
  server's version to one of the next three minors would break or slow
  down, with a status line ("Not ready for 1.33 · 2 blockers · 5
  warnings"). Checks: removed APIs (served versions from discovery, live
  objects' managedFields and last-applied annotations, the latest revision
  of each Helm release, and the API server's
  `apiserver_requested_deprecated_apis` metric where allowed) against the
  deprecated API migration guide; kubelet version skew and mixed
  control-plane versions; drain blockers (PDBs that allow no evictions,
  single replicas, bare pods, emptyDir and node-local volumes); webhooks with
  `failurePolicy: Fail` and no ready endpoints, or matching everything
  including kube-system; CRDs storing objects in unserved or deprecated
  versions; unhealthy nodes; and well-known add-ons with a compatibility
  link. Each finding says why it matters and what to do, links its objects,
  and offers Copy kubectl and docs; findings can be ignored like Security's.
  Read-only; a check the user may not run says so instead of failing.
- **Add-ons**: one-click Helm installs of metrics-server, the Prometheus
  stack, Trivy Operator, Argo CD, Envoy Gateway and cert-manager.
- **Hubble** (on clusters running Cilium with Hubble Relay; the integration
  is on **auto** by default, so it appears, and does anything, only where a
  Hubble Relay Service or Cilium with Hubble is found): a **Map** of
  which namespaces talk to each other and which receive from and send to
  the world, over the last 1, 5 or 15 minutes. The cluster is drawn as a
  disc with a lane per namespace: chords inside join namespaces that talk
  (thicker for more flows, red for drops, with an arrowhead at the
  receiving end), and rays crossing the boundary are traffic to the world
  (blue, labelled with the top destination's DNS name or IP) and from it
  (violet); Cilium Ingress has its own lane at the top, as the door most
  outside traffic comes through. Hover for counts, ports, workloads, world
  peers and drop reasons; click a namespace to focus it and open it in the
  inspector, or an edge for its details, **Can A reach B?** prefilled, and
  the namespace's flows. A side panel lists the edges of the cluster:
  namespaces reached from the world (via Ingress or directly, with ports),
  namespaces calling out (with their destinations), dropping links and the
  busiest ones. A **Matrix** view shows the same counts as a grid (sources
  down, destinations across, the world first). Filter namespaces by name
  (matches and their neighbours stay), show the host and other nodes, the
  API server or other reserved identities (hidden by default, with their
  volume on the toggle), and turn on **Live** to see dots move along the
  links that carried traffic in the last half minute (off by default, and
  never while the system asks to reduce motion). Past what fits, the
  quietest namespaces share one lane. The backend counts flows while the map
  is open (the relay itself only holds seconds) and stops a minute after
  you leave it. Then live network flows for the cluster or a namespace, filtered by verdict, protocol, port
  and direction at the relay; **Drops**, grouped live by source, destination
  and reason (with the denying policy where Hubble knows it); and **Can A
  reach B?**, which says whether traffic between two endpoints was forwarded
  or dropped, why, and by which policy, then shows the flows between them
  live. Pods, Services, Namespaces and workloads get a **Flows** tab in the
  inspector: drops are highlighted with their reason, both ends link to their
  objects, and HTTP and DNS details show when Cilium sees L7. The overview
  flags an unreachable relay and namespaces dropping flows. k8sman reaches
  the relay through a port-forward it manages itself, read-only; the relay
  Service and TLS can be set per context under Integrations.

## Actions

- Scale, restart, pause and resume rollouts, roll back Deployments, suspend
  and resume Jobs and CronJobs, run a CronJob now, cordon and uncordon, delete,
  and edit YAML.
- The delete dialog has a collapsed **Advanced** section, nothing ticked by
  default. **Force (no grace period)** (pods only, also in bulk delete) sets
  `gracePeriodSeconds=0`; **Remove finalizers** (only when the object is already
  terminating and has finalizers) clears them, naming each and warning that what
  they protect may be left behind. Either turns the button into **Force
  delete**. Deleting an object that is already terminating explains what it is
  waiting on. Hidden in read-only mode.
- Argo CD sync, refresh, hard refresh and terminate.
- Helm rollback, upgrade and uninstall.
- Every mutating action asks for confirmation and names the target context.
  Contexts that aren't local (kind, k3d, minikube, Docker Desktop, …) get an
  extra warning.
- Read-only contexts: click the lock next to the context name to block edits,
  deletes, scaling, Helm changes and exec on that context. Contexts whose
  names look like production (`prod`, `production`, `prd`) start locked.
  `--read-only` locks every context. The UI hides those controls.

## App

- A native window with vibrancy and a unified titlebar. It follows the system
  appearance and remembers its size and position.
- Self-contained: the Go backend is embedded and supervised, restarted with
  backoff if it crashes, and stopped with the app.
- Your login-shell environment is passed to the backend, so kubeconfig exec
  credential plugins are found.
- Automatic, EdDSA-signed updates with Sparkle.
- Integrations you don't use (Argo CD, Argo Workflows, Helm, GPUs,
  Prometheus, Gateway API, Hubble, Metrics, Add-ons) can be turned off in
  **Settings ▸ Integrations** (also the palette's **Integrations…**): their
  pages, panels, palette entries and overview checks go away. Each row also
  says how the integration stands on the current cluster (for example "2 GPU
  nodes · DCGM metrics", "using kubectl only", the Prometheus instance
  found, metrics-server available or not), checked once per cluster after
  the first table appears, and expands to the settings of those that have
  some: Hubble's relay, and Argo CD's sign-in (token, argocd CLI login or
  initial admin password). Hubble starts on **auto** (on where it is found,
  off elsewhere, nothing probing or port-forwarding); its switch turns it
  on everywhere or off, and "Use auto" on its row goes back.
