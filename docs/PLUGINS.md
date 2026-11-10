# Plugins

Status: **Milestone 2 implemented** (your own plugins load in dev mode
only), plus [bundled plugins](#bundled-plugins) that load by default:
External Secrets, Dynamic Resource Allocation, Kyverno and cert-manager. Sections 1–12
are the design; [§13 As built](#13-as-built) says where the build differs
from it, [Writing a plugin](#writing-a-plugin) is how to use it, and the
[v1 freeze checklist](#v1-freeze-checklist) is what is left before third
parties build on the format.

Deep integrations (Argo CD, Helm, Gateway API, …) are compile-time modules
(see [DEVELOPMENT.md](DEVELOPMENT.md#adding-an-integration)). Plugins cover
the long tail of CRDs (cert-manager, Karpenter, Crossplane, …): a folder
with a `plugin.yaml`, in YAML and [CEL](https://cel.dev), loaded at runtime.

## Writing a plugin

Your own plugins load only in **developer mode**, from folders on your
computer, and reload as you save. (Plugins bundled with the app load
without it: see [Bundled plugins](#bundled-plugins).)

1. Start one: `k8sman-server plugin new my-plugin` writes `my-plugin/` with
   a `plugin.yaml` (a column, a panel section with a related object, a patch
   action and an alert), a README, and one fixture with its snapshot. Or
   copy [`examples/plugins/cert-manager`](../examples/plugins/cert-manager),
   a short commented example (columns, a panel section, an alert, a shell
   action, nav and an icon). The full cert-manager plugin, which uses most
   of the format, is bundled:
   [`backend/internal/plugins/bundled/cert-manager`](../backend/internal/plugins/bundled/cert-manager).
   The example keeps the id `cert-manager`, so loading it replaces the
   bundled one while it is loaded (see [Bundled plugins](#bundled-plugins)).
2. Turn developer mode on: **Settings ▸ Integrations ▸ Plugins ▸ Developer
   mode** (or the palette's **Integrations…**). Or start the backend with
   `--plugin-dev <folder>` (repeatable), e.g.
   `make backend BACKEND_ARGS="--plugin-dev examples/plugins/cert-manager"`
   with `make app-dev`, or for the packaged macOS app
   `defaults write dev.k8sman.app BackendArgs -array --plugin-dev /path/to/plugin`.
3. **Load plugin folder…** and pick a folder with a `plugin.yaml` (or a
   folder of such folders).
4. Open a table of one of its kinds: the plugin's columns are there (hover a
   header for its description). Open an object: its sections are on the
   Overview tab, and its actions are in the inspector header, the row menu
   and the command palette. Its alerts show on the Overview and in the
   dock's Issues tab.
5. Edit `plugin.yaml` and save. Tables and open panels update within a
   moment. A mistake shows inline in Settings ▸ Integrations ▸ Plugins as
   `plugin.yaml:42:21: undeclared reference to 'objet'` with the line and a
   caret, and the previous version keeps running until the file loads again.
   A failing expression shows its error (with its line) in its cell, field or
   block; the rest still renders. Editors that use the YAML language server
   (VS Code and others) complete and document fields from the JSON Schema
   named on the file's first line.
6. Add fixtures, and check the plugin without the app, e.g. in CI:
   `k8sman-server plugin validate ./my-plugin` and
   `k8sman-server plugin test ./my-plugin` (both exit 1 on problems).

The Plugins settings also list, per plugin, its kinds (active where the
cluster serves them) with what each adds, its permissions, consent (Allow…
/ Revoke), and load, compile and evaluation timings (p50/p95/max per
contribution type).

Shell actions run on your computer in a dock tab (or, with `background:
true`, without one: the app reports the exit status and the last lines of
output). The first action of a plugin asks you to allow its permissions;
every run shows the full command or the change and asks first. Plugin
actions are hidden on read-only contexts. Differences from the design below
(notably `ns` instead of `namespace`) are in [§13](#13-as-built).

### Related objects and metrics

A kind's `related` names the objects its panels and actions read, served
from the app's shared watch cache. Their kinds must be in
`permissions.read`:

```yaml
permissions:
  read: [cert-manager.io/Certificate, cert-manager.io/CertificateRequest, /Secret, /Pod]
kinds:
  cert-manager.io/Certificate:
    related:
      secret:                        # related.secret: the object, absent until found
        kind: /Secret
        name: object.spec.secretName # in the object's namespace (or set `namespace:`)
      requests:                      # related.requests: a list, possibly empty
        kind: cert-manager.io/CertificateRequest
        owner: true                  # their ownerReferences include this object (≤ 200)
      pods:
        kind: /Pod
        selector: '{"app": object.metadata.name}'   # matchLabels, or a LabelSelector
        when: has(object.spec.app)                  # otherwise skip the lookup
```

Read them as `related.secret` (test with `has(related.secret)` or use
`related.?secret`) and `related.requests` (a list, e.g. a `table` block's
`rows`).

A list relation can also keep only the objects a `filter` accepts. The host
evaluates it for each candidate (as `item`) before the list is capped, so
nothing is missed past the cap. Alone, without `name`, `owner` or
`selector`, the candidates are every object of the kind in the namespace
(every namespace for a cluster-scoped object, or with `namespace: '""'`).
`limit` raises the cap (default 200, at most 2,000):

```yaml
      users:                         # the ExternalSecrets that use this store
        kind: external-secrets.io/ExternalSecret
        filter: item.spec.?secretStoreRef.?name.orValue("") == object.metadata.name
      slices:                        # a Node's ResourceSlices (cluster-wide)
        kind: resource.k8s.io/ResourceSlice
        filter: item.spec.?nodeName.orValue("") == object.metadata.name
        limit: 500
```

Prefer `name`, `owner` or `selector` where they fit: they are answered in
Go (a field or label selector, a uid match), a filter costs about 1.3 µs of
CEL per candidate. Only the relations that a panel's (or an action's) expressions
mention are looked up. Secrets show their keys with `""` values: plugins
never see Secret values. While a panel that reads related objects is open,
it renders again every 5 seconds from the warm cache, so a Secret that
appears shows up. A kind the cluster doesn't serve, or a list you aren't
allowed to read, leaves the relation empty and says so above the plugin's
sections; the rest renders.

Columns and alerts see the object only: `related` there (also through a
variable) is a load error at the expression, so tables and overview polls
stay cheap.

`metrics` are instant PromQL queries through the Prometheus integration,
for panels only. They need `permissions.prometheus: true`:

```yaml
    metrics:
      expiry:
        query: '"certmanager_certificate_expiration_timestamp_seconds{namespace=" + promQuote(ns) + ", name=" + promQuote(object.metadata.name) + "}"'
```

`metrics.expiry` is a list of `{labels, value}`, cached for 15 seconds per
query, and empty (with a note) without Prometheus. Lookup expressions
(`name`, `selector`, `namespace`, `when`, `query`) can't read `now`,
`related` or `metrics`. Map keys come out in no particular order: sort a
list made from them (`related.secret.?data.orValue({}).map(k, k).sort()`).

### Patch actions

A patch action changes the object it is offered for, through the app's own
action path: never on read-only contexts, only for kinds in
`permissions.patch` (never Secrets), and only after a dry run whose change
you confirm:

```yaml
permissions:
  patch: [cert-manager.io/Certificate]
…
    actions:
      - id: renew-before
        label: Set renewal time…
        icon: schedule
        dangerous: false
        inputs:
          - name: renewBefore
            label: Renew before
            default: object.spec.?renewBefore.orValue("360h")
            validate: input.renewBefore.matches("^([0-9]+h)?([0-9]+m)?([0-9]+s)?$") && input.renewBefore != ""
            validateMessage: Enter a duration such as 360h or 720h30m.
        patch:
          type: merge                # or json: a list of {op, path, value}
          body: '{"spec": {"renewBefore": input.renewBefore}}'
```

Inputs are `string`, `int`, `bool` or `enum` (with `options`). The app
shows a form with the defaults. The backend checks each value (its type,
the options, then `validate`, whose `validateMessage` shows in the form),
builds the body from the object as it is now, and runs a dry run. The
confirmation shows the patch, the object's diff and the context.

An action's `shortcut` (one letter or digit, optionally `shift+`) runs it
on the table's selected row once the inspector has loaded that row's
actions. The table's own keys win; the loader warns about a clash or a
shortcut it can't bind.

### Alerts

```yaml
    alerts:
      - id: expiring
        label: Certificates expiring within 14 days   # the Overview's row
        severity: warning                              # critical, warning or info
        section: custom                                # or pods, workloads, jobs, nodes, storage, network
        when: >-
          variables.notAfter.hasValue() && timestamp(variables.notAfter.value()) >= now &&
          until(variables.notAfter.value()) < duration("336h")
        message: '"Expires in " + humanDuration(until(variables.notAfter.value()))'
        since: variables.notAfter.value()             # optional
```

Each alert runs for every object of its kind on each overview poll (over
the lists the overview reads from the watch cache, in its namespace scope)
and raises an issue in category `plugin.<plugin>.<alert>`. Alerts in the
`custom` section show under **Plugins** on the Overview; all of them show
in the dock's Issues tab.

### Status lines

A kind's `status` adds to the plugin's one-line summary, shown on a bundled
plugin's row in Settings ▸ Integrations as modules show theirs:

```yaml
    status:
      label: Certificates               # "Certificates: 12"
      counts:
        - label: not ready              # " · not ready: 2"
          severity: warning             # colours the line while the count isn't zero
          when: condition(object, "Ready").hasValue() && !conditionTrue(object, "Ready")
```

Objects are counted across the cluster, from the watch cache, with the
alerts' budgets; counts see the object only, like alerts. A shared
predicate is best a variable that both an alert and a count read.

### Panels that replace the generic one

For a kind without a compiled-in panel (most custom resources), the
generic panel's sections (Health, Conditions, Spec, Status, …) follow the
plugin's. `panel.generic` changes that: `collapse` keeps them, collapsed;
`replace` leaves them out, so the plugin's sections are the panel (the
inspector's Owns and Metadata sections, and the YAML and Events tabs,
stay). Use `replace` when the sections cover the object, conditions
included.

```yaml
    panel:
      generic: replace       # keep (default), collapse or replace
      sections: […]
```

The CRD's printer columns can be dropped the same way: `hideColumns:
["*"]` drops every default column but Name, Namespace and Age, so the
plugin's columns are the table's. Names match in any case (printer columns
are often `READY`, `AGE`), for `hideColumns` and for a plugin column that
replaces a default one.

### Section summaries and detail columns

A section's `summary` is a short text at the right of its header (a count,
a state). A table column with `detail: true` is drawn on a line of its own
under the row's other cells, across the table: a message, a description,
or (with `type: code`) part of the object as YAML:

```yaml
        - title: Requests
          summary: string(size(variables.requests))
          blocks:
            - type: table
              rows: variables.requests
              columns:
                - {name: Request, value: row.name, mono: true}
                - {name: Class, value: row.deviceClassName}
                - name: Selectors
                  detail: true
                  mono: true
                  value: row.?selectors.orValue([]).map(s, s.cel.expression).join("\n")
                - name: Definition
                  type: code         # a value that isn't a string is shown as YAML
                  detail: true
                  value: '{?"match": row.?match, ?"validate": row.?validate}'
```

### Tabs, and plugins for any kind

`panel.tabs` adds inspector tabs, each with its own sections, after the
kind's own tabs. A tab shows for an object while its `when` holds, which
may read related objects: it appears once the object's panel has been
rendered. `into` names a tab of the app's that the sections go into on
kinds that have it, instead of a tab of their own: `security`, the Security
tab of Pods and workloads.

The `"*"` kind key is any kind. It may hold `variables`, `related`,
`metrics`, `panel` sections and tabs, and `actions`, but not columns,
alerts or a status line (those run over whole tables and every object of a
kind, so they stay per kind). Together they let a policy engine show its
results on whatever object they are about, as the bundled Kyverno plugin
does:

```yaml
  "*":
    related:
      reports:                       # the reports the object owns (by uid)
        kind: wgpolicyk8s.io/PolicyReport
        owner: true
        when: ns != ""
    panel:
      tabs:
        - title: Policy results
          icon: policy
          into: security             # a section of the Security tab on Pods and workloads
          when: size(related.reports) > 0
          sections:
            - title: Policy results
              summary: string(size(related.reports.map(r, r.results).flatten()))
              blocks: […]
```

Every inspected object then asks for its plugin panel (`GET
/api/plugins/panel`), so keep a `"*"` entry's lookups cheap: an `owner` or
`name` relation from the watch cache, skipped with `when` for kinds that
have none. A panel that shows nothing (no section, no tab) is fetched again
every 30 seconds rather than every 5. What a `"*"` relation can't read (a
kind the cluster doesn't serve) is noted only where the plugin shows
something. Objects seen through `"*"` are prepared as for their own kind:
a Secret's values are blanked there too.

### Fixtures and tests

```
my-plugin/
  plugin.yaml
  fixtures/
    test.yaml                now, context, readOnly, metric answers
    certificate-ready.yaml   first document: the object; the rest: what related lookups see
    __snapshots__/
      certificate-ready.yaml written by plugin test --update
```

`fixtures/test.yaml`:

```yaml
now: 2026-01-01T00:00:00Z     # what `now` is (default 2026-01-01T00:00:00Z)
context: demo                 # the context's name (default demo)
readOnly: false               # true: actions are hidden, as in the app
metrics:                      # query string → samples; without it there is no Prometheus
  'certmanager_certificate_expiration_timestamp_seconds{namespace="default", name="web-tls"}':
    - {labels: {name: web-tls}, value: 1774915200}
```

Capture objects with **Copy YAML** or `kubectl get -o yaml`, and remove
what shouldn't be committed. `k8sman-server plugin test <folder>` renders
each fixture (the plugin's cells, the resolved panel, the actions offered
with their argv or patch body built from the input defaults, and the
alerts raised) and compares it with `fixtures/__snapshots__/<fixture>`,
printing a diff when they differ; `--update` writes the snapshots. Review
that diff before committing, as for any golden file.

### Tooling without a cluster

`k8sman-server plugin …` (linked as `k8sman` by the packages):

| Command | What it does |
|---|---|
| `validate <folder>…` | load and compile; every error and warning with its line; exit 1 on errors |
| `test [--update] <folder>…` | render the fixtures and compare them with (or write) the snapshots; exit 1 on a difference |
| `render <folder> <fixture.yaml>` | print what one fixture renders to, without comparing |
| `new <id> [<parent folder>]` | start a plugin, with one fixture and its snapshot |
| `import-k9s [--id <id>] <plugins.yaml>` | convert k9s plugins into shell actions (to stdout; warnings to stderr) |
| `schema` | print `plugin.yaml`'s JSON Schema, [`schema/plugin.v1.json`](../schema/plugin.v1.json) |

`import-k9s` maps scopes to kind keys (`pods` → `/Pod`, `deploy` →
`apps/Deployment`, `all` → `"*"`, and `certificates.cert-manager.io` →
`cert-manager.io/Certificate` with a warning to check it). It keeps
`shortCut`, `background` and `dangerous` (missing means `true`), renames
`$RESOURCE_NAME`, `$RESOURCE_GROUP` and `$RESOURCE_VERSION`, and skips
entries that use `$POD`, `$CONTAINER` or `$FILTER`. Validate the result
before loading it.

## Bundled plugins

Some of the app's own integrations are plugins: ordinary plugin folders
compiled into the backend with Go `embed`, in
[`backend/internal/plugins/bundled/<id>/`](../backend/internal/plugins/bundled)
(`plugin.yaml`, `README.md`, `fixtures/`; only the first two are embedded).
Each replaced a built-in module, since removed:
[External Secrets](../backend/internal/plugins/bundled/external-secrets)
(`external_secrets`), [Dynamic Resource Allocation](../backend/internal/plugins/bundled/dra)
(`dra`) and [Kyverno](../backend/internal/plugins/bundled/kyverno)
(`kyverno`). [cert-manager](../backend/internal/plugins/bundled/cert-manager)
(`cert-manager`) was written as a plugin from the start and replaced no
module. It is the full version of
[`examples/plugins/cert-manager`](../examples/plugins/cert-manager), the
short teaching copy.

- **Loaded by default.** They load at start (a parse each; a kind compiles
  on first use), with or without developer mode, and whether the Plugins
  integration is on or off: that switch now turns off only your own plugins.
- **Trusted.** No consent prompt: their actions need no Allow… first. They
  still read only the kinds they declare (and never Secret values), change
  the cluster only through the action path, every patch still shows its dry
  run and asks, every shell command still asks, and all of them are hidden
  and refused on read-only contexts.
- **A switch each.** Each has a row in **Settings ▸ Integrations**, like a
  module (name, description, on/off, and its [status line](#status-lines),
  or else whether the cluster serves its kinds), marked "plugin", in the
  place of the module it replaces, if any. Off is saved in
  settings.json's `plugins.disabled`, as for any plugin. In developer mode
  they also appear under Integrations ▸ Plugins (badge **Bundled**) with
  their kinds, permissions and timings.
- **Overridable.** A plugin folder with the same `id`, loaded in developer
  mode, overrides the bundled copy while it is loaded (badges *Unpacked ·
  overrides bundled* and *Bundled · overridden*): load
  `backend/internal/plugins/bundled/external-secrets` to work on it with hot
  reload. The cert-manager example folder has the id `cert-manager` too, so
  loading it overrides the bundled cert-manager the same way. Two of your own folders with one id still refuse the second.
- **Tested in `go test`.** `TestPluginTestGolden` validates every bundled
  plugin and the cert-manager example, and runs their fixtures against their
  snapshots (a bundled plugin must have fixtures). By hand:
  `k8sman-server plugin test backend/internal/plugins/bundled/external-secrets`.

To add one: a folder under `bundled/` with fixtures and snapshots, and, if
it replaces a module, an entry in `bundled.ReplacesModule`.

### Comparing a bundled plugin with the module it replaces

When a module is rewritten as a bundled plugin, the module can stay in the
app for a while to compare the two (`bundled.ReplacesModule`). They are
never on at once: a module that a bundled plugin replaces is off (the
backend leaves out its routes, overview inputs and actions, and the UI its
sidebar section, panels, icons and Integrations row), unless settings.json's
`plugins.useModule` names the plugin; then the plugin is off and the module
on. Default: the plugin.

To flip: turn on developer mode (Settings ▸ Integrations ▸ Plugins), find
the plugin's card and switch **Use the built-in module instead**; switch it
off to go back. It applies at once (tables, sidebar and inspector follow).
Or edit `~/.config/k8sman/settings.json` with the app closed, e.g.
`{"plugins": {"useModule": ["<plugin id>"]}}` (or `PUT /api/plugins/settings
{"useModule": [...]}`).

No bundled plugin replaces a module now: External Secrets, DRA and Kyverno
were compared with their modules and the modules removed (§13). A saved
`useModule` entry for a plugin without a module is ignored.

## 1. Goals and non-goals

Goals:

- **Look native.** Plugins say *what* to show; the app draws it with its own
  widgets, so plugins follow theme changes for free.
- **Cost what built-ins cost.** CEL is compiled once and evaluated in the Go
  backend over the shared watch cache. The UI never runs plugin code.
- **Easy to write.** No build step, hot reload, file:line errors, a JSON
  Schema, golden tests against fixtures.
- **Safe.** Plugins read only what they declare, change the cluster only
  through the existing action path, and run local commands only after
  consent and a per-run confirmation.

Non-goals for v1:

- Whole pages, custom widgets, or any code other than CEL (no rfw,
  WebAssembly or native code). (Sidebar sections and kind icons are in v1:
  see §12, question 7.)
- Network access from plugins, other than PromQL through the existing
  Prometheus module.
- Replacing deep integrations. Argo CD, Helm, Hubble and the like (their
  own pages, streams, backends) stay modules. Integrations that are columns,
  panels, tabs and lookups can be plugins: External Secrets, DRA and Kyverno
  are now bundled plugins (§13).
- Reading Secret values.

## 2. Concepts and layout

A plugin contributes to **kinds**. For each kind it can add:

| Contribution | Where it shows | Evaluated |
|---|---|---|
| Columns | the kind's table | per row, in the table builder |
| Panel sections | the inspector's Overview tab | per object change, streamed |
| Tabs | inspector tabs of their own, or sections of the Security tab | with the panel sections |
| Actions | inspector header, row menu, palette | on click |
| Alerts | Overview page and Alerts tiles | per object, on each overview poll |
| Status line | the plugin's row in Settings ▸ Integrations | per object, when the row is shown (at most every 30 s) |

Palette entries are not a separate contribution: plugin actions appear in the
palette wherever built-in actions do.

```
cert-manager/
  plugin.yaml          the plugin (one file in v1)
  README.md            shown in the in-app browser
  icon.png             optional, ≤ 64 KB, square
  fixtures/
    test.yaml          test settings (now, context)
    certificate-ready.yaml
    certificate-expiring.yaml
    __snapshots__/     golden output, written by `k8sman plugin test --update`
```

Installed plugins live next to the settings, in
`~/.config/k8sman/plugins/<id>/` on every platform (decided in §12, question
1). Dev plugins are loaded from wherever they are.

## 3. `plugin.yaml` reference

Fields marked **CEL** hold a CEL expression; all others are plain text or
literals. A field is never both. Plain text never contains expressions.

### Top level

| Field | Type | Notes |
|---|---|---|
| `apiVersion` | string | `k8sman.dev/v1` |
| `id` | string | `^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$`, unique in the index |
| `name` | string | display name |
| `version` | semver | |
| `description` | string | ≤ 200 characters |
| `authors` | list of string | |
| `homepage` | URL | optional |
| `minAppVersion` | semver | optional; older apps say "needs k8sman ≥ x" instead of failing to parse |
| `permissions` | Permissions | see §6 |
| `kinds` | map of kind key → Kind | |

Unknown fields are a load error (typos are caught), so new fields always come
with a `minAppVersion`.

A **kind key** is `group/Kind`, as in the UI: `/Pod`,
`cert-manager.io/Certificate`. The key `"*"` (any kind) may hold
`variables`, `related`, `metrics`, `panel` (sections and tabs, not
`generic`) and `actions`; columns, `hideColumns`, alerts, `status`,
`icon` and `version` are per kind. YAML anchors work, so two kinds can
share a definition (or one field of it).

### Kind

| Field | Type | Notes |
|---|---|---|
| `version` | string | optional; pin the API version read (default: the preferred version) |
| `variables` | map of name → **CEL** | named values, `variables.<name>`; evaluated lazily, at most once per evaluation |
| `related` | map of name → Related | §6 |
| `metrics` | map of name → Metric | §6 |
| `columns` | list of Column | |
| `hideColumns` | list of string | default columns to drop (by name, any case); `"*"`: all but Name, Namespace and Age |
| `panel` | `{generic, sections: [Section], tabs: [Tab]}` | §4; `generic`: `keep` (default), `collapse` or `replace` |
| `actions` | list of Action | |
| `alerts` | list of Alert | |
| `status` | Status | the kind's part of the plugin's status line (below) |

### Column

| Field | Type | Notes |
|---|---|---|
| `name` | string | a plugin column with the same name as a default (built-in or CRD printer) column replaces it in place; new ones go before Age |
| `value` | **CEL** | the cell; null or an empty optional renders empty |
| `type` | enum | `string` (default), `number`, `age`, `until`, `status`, `percent`, `bool`, `labels`, `quantity` |
| `description` | string | header tooltip |

`until` is new for plugins (and available to jq columns): a future
timestamp shown as time remaining ("29d"), red once it has passed. It keeps
`now` out of most column expressions, so rows stay memoised.

### Action

| Field | Type | Notes |
|---|---|---|
| `id`, `label` | string | |
| `icon` | string | from the icon list (§4) |
| `when` | **CEL** | whether the action is offered for this object |
| `shortcut` | string | e.g. `shift+R`; ignored with a warning if it clashes with a built-in |
| `dangerous` | bool | default `true`; dangerous actions are hidden and refused on read-only contexts |
| `confirm` | bool | shell actions only; default `true`; forced `true` when `dangerous` |
| `message` | string | extra text in the confirmation |
| `shell` | Shell | exactly one of `shell` and `patch` |
| `patch` | Patch | |
| `inputs` | list of Input | patch actions only |

Shell (k9s-compatible, see below):

| Field | Type | Notes |
|---|---|---|
| `command` | string | must be listed in `permissions.commands` |
| `args` | list of string | `$VAR` expanded per argument |
| `env` | map of string | extra environment, `$VAR` expanded |
| `background` | bool | run without a dock tab; report exit status and the last lines of output |

Patch:

| Field | Type | Notes |
|---|---|---|
| `type` | enum | `merge` or `json` |
| `body` | **CEL** | a map (merge) or a list of operations (json) |

Input: `name`, `label`, `type` (`string`, `int`, `bool`, `enum`), `options`
(enum only), `default` (**CEL**), `validate` (**CEL**, bool, sees `input`),
`validateMessage`.

Patch actions always confirm (the existing dialog: context named, a warning
on non-local clusters, a dry-run first) and are refused on read-only
contexts. There is no field to turn that off. Patch and scale are the only
API actions in v1; the core already offers Scale for any kind with a scale
subresource, so plugins don't redeclare it.

### Alert

| Field | Type | Notes |
|---|---|---|
| `id` | string | category id `plugin.<pluginId>.<id>` |
| `label` | string | tile label, e.g. "Certificates expiring" |
| `severity` | enum | `critical`, `warning`, `info` |
| `section` | enum | an existing overview section (`pods`, `workloads`, `jobs`, `nodes`, `storage`, `network`) or `custom` (default) |
| `when` | **CEL** | bool: whether this object has the problem |
| `message` | **CEL** | string |
| `since` | **CEL** | optional timestamp or RFC3339 string |

### Status

A plugin's status line is its kinds' `status` parts in file order, joined
with ` · `: "ExternalSecrets: 12 · not synced: 2". It is coloured by the
most severe count that isn't zero (critical red, warning amber).

| Field | Type | Notes |
|---|---|---|
| `label` | string | what the objects are called: "ExternalSecrets: 12" |
| `counts` | list of `{label, when` **CEL** bool`, severity}` | objects for which `when` is true: " · not synced: 2"; `severity` `critical`, `warning` (default) or `info` |

Counted over every namespace from the watch cache, with the alerts'
limits (100,000 per expression, 500 ms per plugin); `when` sees what an
alert's does (the object, `variables`, `now`; not `related` or `metrics`).
Served by `GET /api/plugins/status`.

### k9s compatibility

Shell actions follow k9s: `command` + `args` with variable expansion,
`background`, `confirm`, `dangerous`, `shortCut` → `shortcut`, `scopes` →
kind keys. Supported variables: `$NAME`, `$NAMESPACE`, `$CONTEXT`,
`$CLUSTER`, `$USER`, `$KUBECONFIG`, `$GROUP`, `$VERSION`, `$RESOURCE`,
`$KIND` and `$COL-<NAME>` (a column of the object's row, upper-cased,
spaces as `_`). `$POD`, `$CONTAINER` and `$FILTER` are not supported in v1.
`k8sman plugin import-k9s plugins.yaml` converts a k9s file; scopes are
mapped to kind keys through discovery, and a missing `dangerous` becomes
`true`.

Commands run without a shell (argv, one argument per entry), in a new tab of
the local shell dock, with the same `KUBECONFIG` as local shells (the
context on screen first). Values are also exported as environment variables
(`K8SMAN_NAME`, …). A plugin that wants a shell writes
`command: sh, args: [-c, 'cmctl renew "$K8SMAN_NAME"']`; the validator warns
when a `-c` script interpolates `$COL-…` directly.

### Example: cert-manager

The full plugin is bundled with the app, in
[`backend/internal/plugins/bundled/cert-manager`](../backend/internal/plugins/bundled/cert-manager);
the listing below is its shape from the design. A short commented copy to
start from is [`examples/plugins/cert-manager`](../examples/plugins/cert-manager).

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/matty234/k8sman-plugins/main/schema/plugin.v1.json
apiVersion: k8sman.dev/v1
id: cert-manager
name: cert-manager
version: 1.0.0
description: Columns, panels, renew and expiry alerts for cert-manager.
authors: [k8sman]
homepage: https://cert-manager.io

permissions:
  read:
    - cert-manager.io/Certificate
    - cert-manager.io/CertificateRequest
    - cert-manager.io/Issuer
    - cert-manager.io/ClusterIssuer
    - /Secret                 # names and keys only; values are never given to plugins
  commands: [cmctl]

kinds:
  cert-manager.io/Certificate:
    variables:
      notAfter: object.?status.?notAfter                  # optional
      issuer: related.?issuer.or(related.?clusterIssuer)  # optional; panels only (uses related)

    related:
      secret:
        kind: /Secret
        name: object.spec.secretName
      issuer:
        kind: cert-manager.io/Issuer
        when: >-
          object.spec.issuerRef.?group.orValue("cert-manager.io") == "cert-manager.io" &&
          object.spec.issuerRef.?kind.orValue("Issuer") == "Issuer"
        name: object.spec.issuerRef.name
      clusterIssuer:
        kind: cert-manager.io/ClusterIssuer
        when: >-
          object.spec.issuerRef.?group.orValue("cert-manager.io") == "cert-manager.io" &&
          object.spec.issuerRef.?kind.orValue("Issuer") == "ClusterIssuer"
        name: object.spec.issuerRef.name
      requests:
        kind: cert-manager.io/CertificateRequest
        owner: true

    hideColumns: [Status]     # the CRD's printer column; Ready says the same
    columns:
      - name: Ready           # replaces the printer column of the same name
        type: status
        value: 'conditionTrue(object, "Ready") ? "Ready" : condition(object, "Ready").?reason.orValue("Pending")'
      - name: Issuer
        value: object.spec.issuerRef.?kind.orValue("Issuer") + "/" + object.spec.issuerRef.name
      - name: Expires
        type: until
        value: variables.notAfter

    panel:
      sections:
        - title: Certificate
          icon: verified
          blocks:
            - type: message
              severity: error
              when: variables.notAfter.hasValue() && timestamp(variables.notAfter.value()) < now
              text: '"Expired " + humanDuration(age(variables.notAfter.value())) + " ago"'
            - type: message
              severity: warning
              when: >-
                variables.notAfter.hasValue() && timestamp(variables.notAfter.value()) >= now &&
                until(variables.notAfter.value()) < duration("336h")
              text: '"Expires in " + humanDuration(until(variables.notAfter.value()))'
            - type: fields
              items:
                - label: Secret
                  value: object.spec.secretName
                  link: ref("", "Secret", object.spec.secretName)
                - label: Issuer
                  value: object.spec.issuerRef.?kind.orValue("Issuer") + "/" + object.spec.issuerRef.name
                  link: >-
                    ref(object.spec.issuerRef.?group.orValue("cert-manager.io"),
                        object.spec.issuerRef.?kind.orValue("Issuer"), object.spec.issuerRef.name)
                - label: Issuer status
                  type: status
                  value: >-
                    !variables.issuer.hasValue() ? "Not found" :
                    conditionTrue(variables.issuer.value(), "Ready") ? "Ready" : "Not ready"
                - label: Common name
                  value: object.spec.?commonName
                - label: Expires
                  type: until
                  value: variables.notAfter
                - label: Renews
                  type: until
                  value: object.?status.?renewalTime
                - label: Duration
                  value: object.spec.?duration.orValue("2160h (default)")
        - title: DNS names
          icon: dns
          when: object.spec.?dnsNames.orValue([]).size() > 0
          blocks:
            - type: chips
              items: object.spec.dnsNames
        - title: Conditions
          blocks:
            - type: conditions
        - title: Secret
          icon: key
          blocks:
            - type: message
              severity: warning
              when: '!has(related.secret)'
              text: '"Secret " + object.spec.secretName + " does not exist yet"'
            - type: fields
              when: has(related.secret)
              items:
                - label: Name
                  value: related.secret.metadata.name
                  link: ref(related.secret)
                - label: Type
                  value: related.secret.type
                - label: Created
                  type: age
                  value: related.secret.metadata.creationTimestamp
            - type: chips
              when: has(related.secret)
              items: related.secret.?data.orValue({}).map(k, k)
        - title: Requests
          icon: history
          when: size(related.requests) > 0
          blocks:
            - type: table
              rows: related.requests
              sortBy: Created
              descending: true
              limit: 5
              columns:
                - name: Name
                  value: row.metadata.name
                  link: ref(row)
                - name: Ready
                  type: status
                  value: 'conditionTrue(row, "Ready") ? "Ready" : condition(row, "Ready").?reason.orValue("Pending")'
                - name: Created
                  type: age
                  value: row.metadata.creationTimestamp

    actions:
      - id: renew
        label: Renew
        icon: refresh
        shortcut: shift+R
        message: cmctl marks the certificate for renewal; cert-manager issues a new one now.
        shell:
          command: cmctl
          args: [renew, --context, $CONTEXT, -n, $NAMESPACE, $NAME]

    alerts:
      - id: expired
        label: Certificates expired
        severity: critical
        when: variables.notAfter.hasValue() && timestamp(variables.notAfter.value()) < now
        message: '"Expired " + humanDuration(age(variables.notAfter.value())) + " ago"'
        since: variables.notAfter.value()
      - id: expiring
        label: Certificates expiring within 14 days
        severity: warning
        when: >-
          variables.notAfter.hasValue() && timestamp(variables.notAfter.value()) >= now &&
          until(variables.notAfter.value()) < duration("336h")
        message: '"Expires in " + humanDuration(until(variables.notAfter.value()))'
      - id: not-ready
        label: Certificates not ready
        severity: warning
        when: condition(object, "Ready").hasValue() && !conditionTrue(object, "Ready")
        message: condition(object, "Ready").?message.orValue("Not ready")
        since: condition(object, "Ready").?lastTransitionTime.orValue(object.metadata.creationTimestamp)

  cert-manager.io/Issuer: &issuer
    columns:
      - name: Type
        value: >-
          has(object.spec.acme) ? "ACME" : has(object.spec.ca) ? "CA" :
          has(object.spec.vault) ? "Vault" : has(object.spec.venafi) ? "Venafi" :
          has(object.spec.selfSigned) ? "SelfSigned" : "Other"
      - name: Server
        value: object.spec.?acme.?server
    panel:
      sections:
        - title: Issuer
          blocks:
            - type: fields
              items:
                - label: ACME server
                  value: object.spec.?acme.?server
                - label: ACME email
                  value: object.spec.?acme.?email
                - label: CA secret
                  value: object.spec.?ca.?secretName
            - type: conditions
  cert-manager.io/ClusterIssuer: *issuer
```

Notes on the expressions: `object.?a.?b` is CEL's optional chaining (absent
fields give an empty optional instead of an error); `variables.issuer`
refers to `related`, so it may only be used in panels and actions (§5).
`dnsNames` and `secretName` are required by the CRD schema, so they are read
directly; a fixture without them shows an error in that cell or row, not a
crash.

### Example: Karpenter NodePool

```yaml
apiVersion: k8sman.dev/v1
id: karpenter
name: Karpenter
version: 0.1.0
description: NodePool limits, node claims and a CPU-limit action.
permissions:
  read: [karpenter.sh/NodePool, karpenter.sh/NodeClaim]
  patch: [karpenter.sh/NodePool]

kinds:
  karpenter.sh/NodePool:
    version: v1
    variables:
      cpuLimit: object.spec.?limits.?cpu                      # optional
      cpuUsed: object.?status.?resources.?cpu.orValue("0")
    related:
      claims:
        kind: karpenter.sh/NodeClaim
        selector: '{"karpenter.sh/nodepool": object.metadata.name}'
    columns:
      - name: Nodes
        type: quantity
        value: object.?status.?resources.?nodes.orValue("0")
      - name: CPU used
        type: percent
        value: >-
          variables.cpuLimit.hasValue()
            ? dyn(100.0 * quantity(variables.cpuUsed).asApproximateFloat()
                  / quantity(variables.cpuLimit.value()).asApproximateFloat())
            : dyn(null)
    panel:
      sections:
        - title: Capacity
          icon: memory
          blocks:
            - type: bar
              label: CPU
              when: variables.cpuLimit.hasValue()
              value: quantity(variables.cpuUsed).asApproximateFloat()
              max: quantity(variables.cpuLimit.value()).asApproximateFloat()
              format: quantity
            - type: fields
              items:
                - label: Node class
                  value: object.spec.template.spec.nodeClassRef.name
                  link: >-
                    ref(object.spec.template.spec.nodeClassRef.group,
                        object.spec.template.spec.nodeClassRef.kind,
                        object.spec.template.spec.nodeClassRef.name)
                - label: Consolidation
                  value: object.spec.?disruption.?consolidationPolicy
                - label: Weight
                  type: number
                  value: object.spec.?weight
        - title: Node claims
          blocks:
            - type: table
              rows: related.claims
              empty: No node claims.
              columns:
                - name: Name
                  value: row.metadata.name
                  link: ref(row)
                - name: Type
                  value: row.metadata.?labels[?"node.kubernetes.io/instance-type"]
                - name: Ready
                  type: status
                  value: 'conditionTrue(row, "Ready") ? "Ready" : "Not ready"'
        - title: Conditions
          blocks:
            - type: conditions
    actions:
      - id: set-cpu-limit
        label: Set CPU limit…
        icon: tune
        inputs:
          - name: cpu
            label: CPU limit
            type: string
            default: variables.cpuLimit.orValue("")
            validate: isQuantity(input.cpu)
            validateMessage: Enter a quantity such as 100 or 64000m.
        patch:
          type: merge
          body: '{"spec": {"limits": {"cpu": input.cpu}}}'
    alerts:
      - id: near-cpu-limit
        label: NodePools near their CPU limit
        severity: warning
        section: nodes
        when: >-
          variables.cpuLimit.hasValue() &&
          quantity(variables.cpuUsed).asApproximateFloat()
            >= 0.9 * quantity(variables.cpuLimit.value()).asApproximateFloat()
        message: '"Using " + string(variables.cpuUsed) + " of " + string(variables.cpuLimit.value()) + " CPU"'
```

## 4. Panel vocabulary v1

A panel is a list of **sections**: `title` (text), `icon` (text), `when`
(**CEL** bool), `summary` (**CEL** string: a short text at the right of the
header), `collapsed` (bool), `blocks` (list). Each section is a
`DetailSection`. Every block also takes `when`.

A panel's **tabs** (`panel.tabs`) are `{title, icon, when` **CEL** bool`,
into, sections}`: an inspector tab with its own sections, after the kind's
tabs, shown while `when` holds (default: always). `into: security` puts the
sections in the Security tab instead, on the kinds that have one (Pods and
workloads); there they are drawn as that tab's sections. A title may not be
Overview, YAML or Events, nor appear twice in a kind entry.

| Block | Widget | Fields |
|---|---|---|
| `fields` | `KeyValueTable` | `items`: list of `{label, value` **CEL**`, type, link` **CEL** `Ref, copy: bool, mono: bool, when}`. A row whose value is null or empty is hidden; `mono` draws it in the monospace font |
| `badges` | `StatusBadge` row | `items`: list of `{text` **CEL**`, severity` **CEL** optional`, when}`; without severity the badge colours itself from the text as today |
| `chips` | `Chipish` / `LabelChips` | `items` **CEL**: a list of strings, or a map (shown as `key=value`) |
| `conditions` | `ConditionsTable` | `from` **CEL**, default `object.status.conditions` |
| `links` | `ResourceLink` list | `items` **CEL**: a list of Refs; `empty` (text) |
| `table` | compact table | `rows` **CEL** list; `columns`: list of `{name, value` **CEL** (sees `row`)`, type, link, mono: bool, detail: bool}`; `sortBy` (column name), `descending`, `limit` (default 20, "Show all" beyond), `empty` (text). A `detail` column is drawn on its own line under its row, across the table |
| `settings` | `KeyValueTable` | `value` **CEL**: a map of any depth, flattened into sorted `path → value` rows; `limit` (default 14, at most 50; "and N more" beyond), `empty` (text). See below |
| `bar` | `UsageBar` | `label`, `value` **CEL** number, `max` **CEL** number, `format`: `number`, `quantity` or `percent`; amber from 80%, red from 90% |
| `code` | `CodeBlock` | `value` **CEL**: a string, or any value, shown as YAML (JSON with `language: json`); `language`: `text`, `yaml`, `json` or `shell` |
| `json` | `JsonTree` | `value` **CEL**, any value |
| `message` | `InlineMessage` / `Callout` | `text` **CEL** string, `severity`: `info`, `warning` or `error`; `title` **CEL** string, optional: a warning or error with a title is a callout headed by it, the text under it |

Value `type` in `fields` and `table` columns: `text` (default), `number`,
`bool`, `status`, `age` (with the timestamp in a tooltip), `until`,
`timestamp`, `quantity`, `labels`, `url` (opens the browser on click),
`code` (monospace, with copy; a value that isn't a string is shown as
YAML). A `status` value colours itself from its text (Ready, Failed,
Pending, …, and the policy-report results pass, warn and fail).

**The `settings` block** shows a configuration object (a store's provider,
an issuer's ACME or Vault settings) as the module panels did, which CEL
can't (it has no recursion). The host walks the map: nested keys join with
`.`; a list of scalars is one row (`a, b`), a list of maps says how many
entries it has; a value longer than 80 characters says how long it is;
nulls and empty strings are skipped. A map with a string `name` under a key
ending in `SecretRef`, `ConfigMapRef` or `ServiceAccountRef` (any case:
`tokenSecretRef`, `secretRef`, `serviceAccountRef`) is a **reference**: one
row, `Secret/<name> · <key>`, linked to that object in the map's
`namespace` or the object's (not linked when neither is known, as for a
cluster-scoped object). A reference shows a name and a key, never anything
read from the object it names: plugins never see Secret values, and this
block reads nothing beyond the value it is given.

`icon` is one of a fixed list of ~40 Material icon names (in the schema as an
enum: `verified`, `key`, `dns`, `history`, `memory`, `tune`, `refresh`,
`lock`, `storage`, `cloud`, `link`, `warning`, …). Flutter tree-shakes its
icon font, so arbitrary names can't be looked up at runtime.

**Placement.** Plugin sections come after the shared Metadata section. For a
kind with a compiled-in panel they follow its sections. For a kind that only
has the generic custom-resource panel, they replace its summary; the generic
spec and status trees stay, collapsed, at the end. Two plugins for one kind
appear in plugin id order. Panels get the shared YAML and Events tabs as
before; plugin tabs come after the kind's own tabs and before YAML. (As
built: plugin sections come before Owns and Metadata, and the generic
panel's sections follow them unless `panel.generic` says `collapse` or
`replace`; see §13. Tabs were added with the DRA and Kyverno ports.)

The vocabulary grows by adding blocks or fields; an older app shows "this
section needs k8sman ≥ x" for a block it doesn't know.

## 5. CEL environment v1

Built on [cel-go](https://github.com/google/cel-go) with:

- the standard library and macros (`has`, `all`, `exists`, `exists_one`,
  `map`, `filter`, `size`, `matches`, conversions, timestamp and duration
  arithmetic and accessors);
- `cel.OptionalTypes()` (`a.?b`, `m[?"k"]`, `.orValue()`, `.or()`,
  `.hasValue()`, `.value()`, `optional.of/none`);
- `ext.Strings()` (`lowerAscii`, `split`, `join`, `replace`, `trim`, …) and
  `ext.Sets()`;
- the Kubernetes libraries from `k8s.io/apiserver/pkg/cel/library`: Lists
  (`sum`, `min`, `max`, `isSorted`, `indexOf`), Regex (`find`, `findAll`),
  URLs (`url`, `isURL`, `getHost`, …), Quantity (`quantity`, `isQuantity`,
  `asApproximateFloat`, `compareTo`, `add`, …), IP, CIDR, Format and Semver;
- `cel.DefaultUTCTimeZone(true)` and `cel.CrossTypeNumericComparisons(true)`
  (so `1 < 1.5` type-checks).

Unlike Kubernetes, `HomogeneousAggregateLiterals` is **off**, so patch bodies
such as `{"spec": {"suspend": true, "replicas": 3}}` work. Branches of `?:`
must still have one type; use `dyn()` to mix (as in the Karpenter column).

### Variables

| Variable | Type | Columns | Alerts | Panels | Actions | `related`/`metrics` exprs |
|---|---|---|---|---|---|---|
| `object` | `map(string, dyn)` | ✓ | ✓ | ✓ | ✓ | ✓ |
| `variables` | `map(string, dyn)`, lazy | ✓¹ | ✓¹ | ✓ | ✓ | ✓¹ |
| `now` | `timestamp` | ✓ | ✓ | ✓ | ✓ | |
| `context` | `string`: kube context name | ✓ | ✓ | ✓ | ✓ | ✓ |
| `namespace` | `string`: the object's namespace, `""` if cluster-scoped | ✓ | ✓ | ✓ | ✓ | ✓ |
| `related` | `map(string, dyn)` | | | ✓ | ✓ | |
| `metrics` | `map(string, list(dyn))` | | | ✓ | | |
| `row` | `dyn` | | | `table` columns | | |
| `input` | `map(string, dyn)` | | | | patch `body`, `validate` | |
| `item` | `map(string, dyn)` | | | | | a related `filter`: the candidate |

¹ Only variables that don't (directly or through other variables) reference
`related` or `metrics`. The loader checks this from the compiled ASTs and
reports it with the file and line.

`related.<name>` is an object for `name` relations, present only when found
(test with `has(related.x)` or `related.?x`), and a list (possibly empty) for
`owner` and `selector` relations. `now` is fixed for one evaluation pass, so
all rows of a table see the same instant. Objects are as served by the API,
minus `managedFields`; Secrets have every `data` and `stringData` value
replaced with `""`.

### Functions

| Function | Returns | Notes |
|---|---|---|
| `ref(obj dyn)` | Ref | link to an object (group and kind from `apiVersion`/`kind`) |
| `ref(group, kind, name string)` | Ref | in `namespace`; ignored for cluster-scoped kinds |
| `ref(group, kind, namespace, name string)` | Ref | |
| `condition(obj dyn, type string)` | `optional(dyn)` | the entry of `obj.status.conditions` with that `type` |
| `conditionTrue(obj dyn, type string)` | bool | that condition exists with `status == "True"` |
| `age(t)` | duration | `now - t`; `t` a timestamp or RFC3339 string |
| `until(t)` | duration | `t - now` |
| `humanDuration(d duration)` | string | kubectl style: `45s`, `3h12m`, `29d`, `1y20d`; negative gets `-` |
| `promQuote(s string)` | string | `s` as an escaped PromQL string literal, for `metrics` queries |
| `l.sort()` | list | `l` in order (strings, numbers, booleans or timestamps); added in Milestone 2 |
| `l.flatten()` | list | the lists in `l` joined into one (one level; other elements kept) |
| `l.distinct()` | list | each value of `l` once, in first-seen order |

CEL durations have no day unit: write `duration("336h")`, not `"14d"`.

**Contract.** The vocabulary and this environment are the public API of
`k8sman.dev/v1`. Adding blocks, fields, variables, functions or libraries is
compatible; removing or changing them is not, and would need `v2` (the app
would keep loading `v1`). Library versions are pinned in the app, not taken
from the cluster.

**A future `logic:` field.** A later optional `logic:` (some richer
evaluator) would be a new kind-level field gated by `minAppVersion` and its
own permission. Its outputs would appear to CEL as one more variable (e.g.
`logic.<name>`), so the vocabulary and everything above stay as they are and
v1 plugins don't change. Nothing in v1 reserves more than the field name.

## 6. Data sources and permissions

**Related objects** are declared per kind, never fetched by plugin code:

| Field | Type | Notes |
|---|---|---|
| `kind` | kind key | must be in `permissions.read` |
| `name` | **CEL** string | one object by name |
| `owner` | bool | objects whose `ownerReferences` include this object's uid |
| `selector` | **CEL** | a `matchLabels` map or a `LabelSelector` object |
| `namespace` | **CEL** string | default `namespace`; `""` = every namespace; ignored for cluster-scoped kinds |
| `when` | **CEL** bool | skip the lookup |
| `filter` | **CEL** bool, sees `item` | keep the candidates for which it is true, before the cap; alone: every object of the kind in the namespace |
| `limit` | int | list relations: how many objects to keep (default 200, at most 2,000) |

At most one of `name`, `owner` and `selector`, and at least one of them or
`filter`. All are served from `kcache`: `name` reads the namespace's
stream, `selector` uses a label-selector key (which rides a warm broader
stream when there is one), `owner` filters the namespace's stream by uid,
and `filter` alone reads the namespace's stream; `filter` then runs on what
they found, and a list keeps `limit` objects (default 200).
While a panel is open its related streams stay subscribed, so a change to
the Secret re-renders the Certificate panel. A related kind the cluster
doesn't serve gives an empty result and a note in the panel.

**Metrics** (panels only, needs `permissions.prometheus: true` and the
Prometheus module on): `metrics: {name: {query: CEL string, instance?:
string}}`. Instant queries through the existing `/api/prom/query` code,
cached for 15 s per query string. `metrics.<name>` is a list of
`{labels: map, value: double}`, empty when Prometheus isn't there (with a
note in the section).

```yaml
    metrics:
      expiry:
        query: '"certmanager_certificate_expiration_timestamp_seconds{namespace=" + promQuote(namespace) + ", name=" + promQuote(object.metadata.name) + "}"'
```

**Permissions** in `plugin.yaml`:

| Field | Type | Grants |
|---|---|---|
| `read` | list of kind keys | the plugin's own kinds and related kinds |
| `patch` | list of kind keys | patch actions on these kinds |
| `commands` | list of string | executables shell actions may run |
| `prometheus` | bool | PromQL queries |

The loader checks both ways: anything used must be declared (load error),
anything declared but unused is a warning. Declared rather than inferred so
that a permission change is visible in review and triggers re-consent.

RBAC is enforced by the API server with the user's credentials as usual. A
forbidden list shows "not allowed to list Secrets in `cert-manager`" in the
section that needed it; the rest of the panel renders. Plugin actions go through `POST /api/actions/{action}` (so
`handleAction`'s read-only check, availability check and dry-run apply) and
the UI's `runResourceAction`/`confirmAction`. Dangerous shell actions are
refused by the backend on read-only contexts; non-dangerous ones print the
same notice as local shells.

## 7. Lifecycle

1. **Discovery.** At backend start, in a goroutine (the backend doesn't wait
   for it before `K8SMAN_LISTENING`), list the installed plugins folder and
   dev folders (`--plugin-dev <dir>`, repeatable, plus `devPlugins` in
   `settings.json`). Skip plugins in `disabledPlugins` or without matching
   consent (`pluginConsent: {id: permissionsHash}`).
2. **Load.** Parse `plugin.yaml` strictly (yaml.v3 nodes, so every value
   keeps its line and column), check structure and permissions, index
   contributions by kind. No CEL is compiled.
3. **Activate**, per (plugin, kind), on first use: a table, panel, action
   list or overview poll for that kind on a cluster that serves it. Compile
   every expression of that kind entry, type-check against §5, estimate
   cost, resolve kinds to resources through discovery. Activation is atomic
   per kind entry: one compile error disables that entry and the error shows
   in its panel and on the Plugins page; the plugin's other kinds still work.
4. **Hot reload** (dev plugins only). fsnotify on the folder, debounced
   150 ms. Dev plugins compile eagerly so errors appear on save. A good
   reload swaps the plugin atomically and bumps a generation number; the UI
   (`WS /api/plugins/events`) refetches table columns and panel streams. A
   bad reload keeps the previous version running and shows the errors.
5. **Errors.** Every error carries `file:line:col`, mapped from the CEL
   position into the YAML (block scalars included). Evaluation errors show
   in their cell (`columnErrors`, as for jq), field or section; they never
   fail the table, the panel, or the overview.

## 8. Performance design and budgets

Where the work happens:

- **Columns** are `columns.Column`s with a `cel` field instead of `query`,
  evaluated by the same `tableBuilder`, cached by the same row memo
  (UID, resourceVersion, column set). CEL doesn't write to its input, so a
  CEL-only row skips `columns.PrivateCopy`. Columns that reference `now` are
  found at compile time and re-evaluated on a 30 s tick, as the usage
  columns are on theirs; most expiry columns use `type: until` and don't.
- **Panels** are rendered in the backend into a tree of resolved blocks
  (plain JSON) and streamed over `WS /api/plugins/panel`. A new frame is sent
  only when the tree's hash changes. Panels using `now` re-render every
  30 s. The UI maps blocks to existing widgets; there is no plugin code on
  the render path.
- **Alerts** run inside the overview's `OverviewLists.Go`, over the same
  `kcache` lists the overview already uses.

Limits per evaluation (cel-go `CostLimit` plus `ContextEval` with
`InterruptCheckFrequency`):

| Contribution | Cost limit | Timeout |
|---|---|---|
| Column cell | 100,000 | 10 ms |
| Alert `when` + `message`, per object | 100,000 | 10 ms |
| Panel expression | 1,000,000 | — |
| Whole panel render | 5,000,000 | 250 ms |
| Action `when` / body / validate | 1,000,000 | 50 ms |
| All alerts of one plugin, per overview poll | — | 500 ms |

A contribution that hits a limit 5 times in a minute is suspended for 5
minutes ("suspended: too slow", with Resume on the Plugins page). Dev
plugins are never suspended; they show the error instead.

Targets (M1 Pro, release build; checked by benchmarks):

| | Target |
|---|---|
| Read and validate one manifest | ≤ 2 ms (20 plugins ≤ 20 ms, off the start-up path) |
| Compile one kind entry (≈30 expressions) | ≤ 15 ms, once |
| Simple column cell (field select, `?:`) | ≤ 2 µs; ≤ 1.2× a jq column doing the same |
| 1,500-row snapshot with 3 plugin columns, memo cold / warm | + ≤ 10 ms / + 0 ms over `BenchmarkTableSnapshot` |
| Panel render, related data warm | ≤ 5 ms p95 |
| Overview poll with 5 typical plugins | + ≤ 5 ms p50 |
| Memory per active plugin (compiled programs) | ≤ 2 MiB, plus whatever watch streams its related kinds keep warm |
| Backend binary growth (cel-go + k8s libraries) | ≤ 6 MB |

The Plugins settings page shows, per plugin: load and compile time, active
kinds, evaluations, p50/p95/max per contribution type, cost-limit hits,
timeouts and errors (`GET /api/plugins`).

## 9. Authoring workflow

1. Start from `k8sman plugin new cert-manager` (a skeleton with the schema
   comment and one fixture), or copy one from the plugins repo.
2. Run the app with `--plugin-dev ./cert-manager`, or **Plugins… → Load
   unpacked plugin…**. Edit and save; tables and panels update in place.
   Errors appear inline, e.g.
   `plugin.yaml:42:21: undeclared reference to 'objet'`, with the line and a
   caret.
3. The schema (`schema/plugin.v1.json` in the plugins repo, generated from
   the Go manifest types; a test fails when it is stale) gives completion
   and hover docs in VS Code and other YAML language server editors. It
   cannot check CEL; `k8sman plugin validate` does.
4. Add fixtures: each `fixtures/*.yaml` is multi-document YAML, the first
   document the subject and the rest the cluster the related lookups see.
   `fixtures/test.yaml` sets `now`, `context` and `readOnly`. Capture real
   objects with **Copy YAML** or `kubectl get -o yaml`.
5. `k8sman plugin test [--update]` renders every fixture and compares with
   `fixtures/__snapshots__/<fixture>.yaml`: the row cells, the resolved panel
   tree, the actions offered with their expanded argv or patch body, and the
   alerts raised. Snapshots are text, so diffs review well.

The commands are subcommands of the backend binary (`k8sman-server plugin
validate|test|render|new|import-k9s`), so they run headless in CI on Linux.
Homebrew and the Linux packages link it as `k8sman`.

## 10. Distribution and trust

- **Repo.** `matty234/k8sman-plugins`: `plugins/<id>/` folders,
  `schema/`, and CI that runs `validate` and `test` against the latest and
  the oldest supported app release. Changes need maintainer review
  (CODEOWNERS); a PR that changes `permissions` is labelled for closer
  review.
- **Index.** On merge, CI packs each plugin (tar.gz; only `.yaml`, `.md`,
  `.png`, `.svg`; ≤ 1 MiB) and writes `index.json`: `{generatedAt, expires,
  plugins: [{id, name, version, description, kinds, permissions,
  minAppVersion, url, sha256, size}], revoked: [id@version]}`. The exact
  bytes are signed with ed25519 (`index.json.sig`), with a key separate from
  the Sparkle key. `expires` is 30 days ahead and CI re-signs weekly, so an
  old index can't be replayed forever.
- **Install.** The backend fetches and verifies the index (public key built
  in), downloads the tarball, checks its sha256 against the signed index,
  extracts to a staging folder (rejecting absolute paths, `..` and links),
  validates, and asks for consent. On consent it renames the folder into
  place and stores the permissions hash.
- **Consent** reads like a browser extension's: "Reads Certificates,
  CertificateRequests, Issuers, ClusterIssuers and Secrets (names and keys
  only). Runs on this computer: `cmctl`. Changes: nothing." The Karpenter one
  adds "Changes: NodePools (with your confirmation)".
- **Updates** are checked when the Plugins page opens and daily while any
  plugin is installed. Same permissions: install on click (or
  automatically, if turned on). New permissions: ask again. Revoked
  versions are disabled on the next check.
- **Unsigned plugins** load only in dev mode, carry an "Unpacked" badge, and
  are never updated.

A plugin can't open connections, read files, or reach the cluster except
through its declared reads and the action path. Its two real powers are
patches (confirmed each time) and local commands (consented at install,
confirmed on each run with the full argv shown).

## 11. Mapping onto the existing code

Plugins are not modules, but the plugin host is: one built-in module,
`plugins`, that can be turned off in Integrations like any other, which
turns every plugin off. (As built, it turns off the user's own plugins;
bundled ones have a switch each: see [Bundled plugins](#bundled-plugins).)

**Backend**

| Where | What |
|---|---|
| `internal/plugins/manifest.go` | v1 types, strict decode with positions |
| `internal/plugins/load.go`, `devwatch.go` | discovery, dev folders, fsnotify |
| `internal/plugins/celenv.go` | the §5 environment and functions |
| `internal/plugins/compile.go` | per-kind activation, reference checks, cost estimates |
| `internal/plugins/eval.go`, `stats.go` | limits, suspension, timings |
| `internal/plugins/related.go`, `metrics.go` | lookups through `kcache` and `internal/prom` |
| `internal/plugins/render.go` | panel block trees |
| `internal/plugins/actions.go`, `shell.go` | patch bodies, k9s-style argv expansion |
| `internal/plugins/index.go` | index, signatures, install, consent |
| `internal/plugins/fixtures.go` | fixtures and snapshots for `plugin test` |
| `internal/server/plugins.go` | the `plugins` Module: routes (`/api/plugins`, `/api/plugins/panel`, `/api/plugins/events`, install/dev endpoints), `OverviewSource` (alerts), `ActionSource` (actions named `plugin.<id>.<action>`) |
| `internal/server/localshell.go` | `/api/local-shell?plugin=&action=&…`: the backend builds the argv from the loaded plugin, so the UI can't send a command |
| `internal/columns` | `Column.CEL`, `Column.Plugin`; the `Evaluator` takes CEL programs through a small interface (no import cycle); `until` type |
| `internal/server/server.go` | default columns = `columns.Defaults` + plugin columns, with replace-by-name and `hideColumns` |
| `internal/settings` | `disabledPlugins`, `devPlugins`, `pluginConsent` |
| `cmd/k8sman-server` | `--plugin-dev`, `plugin` subcommands |

**Frontend**

| Where | What |
|---|---|
| `lib/plugins/plugin_api.dart` | models and API calls |
| `lib/plugins/blocks.dart` | block JSON → widgets from `ui/widgets/common.dart` |
| `lib/plugins/plugin_panel.dart` | a `ResourcePanel` that subscribes to the panel stream (keyed by uid, per PANELS.md) and supplies `actions(ctx)` |
| `lib/plugins/plugins_dialog.dart` | installed and dev plugins, errors, timings, enable/disable, Load unpacked |
| `lib/plugins/plugin_browser.dart` | index browser and consent |
| `lib/modules/plugins_module.dart` | the `plugins` AppModule |
| `lib/panels/registry.dart` (shared) | `panelFor` composes a plugin panel with the built-in or fallback one |
| `lib/ui/resource_table.dart` (shared) | `until` cells |
| terminal dock (shared) | a tab for a plugin command |

Reused unchanged: `kcache` (streams, memo), the row memo and
`columnErrors`, `OverviewLists`, the actions endpoint and its read-only
guard, `confirmAction`, the local shell's kubeconfig handling, the widgets
in `common.dart`, the Integrations switch, and the ed25519 tooling from
the Sparkle feed.

### Milestones

1. **MVP.** Manifest, loader and lazy activation; the CEL environment
   without `related` and `metrics`; columns; panels (all blocks, object
   data only); shell actions in the dock with k9s variables; dev mode with
   hot reload and inline errors; the Plugins dialog with timings. Plugins
   load only in dev mode. The table benchmark gains a plugin-column case.
2. **Data and tooling.** Related objects; patch actions with inputs;
   alerts; PromQL; the JSON Schema; fixtures, `plugin test`/`validate`/
   `render`/`new`; `import-k9s`.
3. **Distribution.** The plugins repo with CI and the first plugins
   (cert-manager, Karpenter, external-secrets); the signed index; the
   browser, consent, updates and revocation.

## 12. Open questions

Answered by the owner for Milestone 1 (the questions are kept below):

1. **Install location:** follow the settings directory
   (`~/.config/k8sman/plugins`), not `os.UserConfigDir()`.
2. **Related data in columns and alerts:** out of scope for Milestone 1
   (related data itself is Milestone 2).
3. **Shell actions on read-only contexts:** hide (and refuse) all plugin
   shell actions there, dangerous or not.
4. **Kubernetes CEL libraries:** implementer's call; prefer copying if the
   import is large. Copied (see §13).
5. **Panel transport:** implementer's call, simplest is fine. HTTP per object
   version (see §13).
6. **CLI:** `k8sman-server plugin …` subcommands; Milestone 1 has
   `plugin validate <dir>`, the rest is Milestone 2.
7. **Navigation:** yes: plugins may add a sidebar section (`NavGroup`) and
   kind icons in v1, icons by name from the fixed list or the plugin's
   `icon.png`.
8. **Certificate details:** out of scope.
9. **Whole pages:** out of scope.

1. **Install location.** Using `os.UserConfigDir()` puts plugins in
   Application Support on macOS while settings live in `~/.config/k8sman`.
   Should plugins follow settings instead, for consistency?
2. **Related data in columns and alerts.** v1 keeps them object-only, which
   keeps tables cheap. "Number of failing child objects" is a common ask;
   a later version could allow owner/selector relations in columns with a
   per-table budget.
3. **Non-dangerous shell actions on read-only contexts.** They run with the
   user's credentials, as local shells do. Should read-only contexts hide
   all plugin shell actions instead?
4. **Kubernetes CEL libraries.** Importing
   `k8s.io/apiserver/pkg/cel/library` pulls in part of the apiserver module.
   If it costs more than the size budget, copy the libraries we use
   (Apache-2.0) instead.
5. **Panel transport.** A WebSocket per open panel is simplest. If several
   inspectors (or the editor) are open at once, one multiplexed stream may
   be better.
6. **CLI name.** `k8sman-server plugin …` linked as `k8sman`, or a separate
   small `k8sman-plugin` binary for CI?
7. **Navigation.** Plugins can't add sidebar sections or kind icons in v1;
   their kinds appear under Custom Resources. `NavGroup` and `kindIcons`
   already exist and would be cheap to expose.
8. **Certificate details.** Without Secret values, plugins can't show what
   is actually in `tls.crt`. A host-side `x509` helper that parses a
   Secret's certificate (never exposing the bytes) could be added later
   under its own permission.
9. **Whole pages** stay out of v1 as decided. If asked for, a filtered
   object list built from the same vocabulary would cover most cases.

## 13. As built

### Milestone 1

**Where.** Backend: `internal/plugins` (`decode.go` and `exprpos.go`
strict YAML with positions, `manifest.go`, `icons.go`, `celenv.go`,
`compile.go`, `eval.go`, `shell.go`, `stats.go`, `host.go` for loading, dev
folders, fsnotify and lookups, `k8scel/` the copied Kubernetes libraries),
`internal/server/plugins.go` (the `plugins` module and its routes),
`internal/server/localshell.go` (plugin actions), `columns.Column`
(`Plugin`, `Program`, `Rev`, `Description`) and `settings.PluginSettings`.
Frontend: `lib/plugins/` (`plugin_api.dart`, `plugin_host.dart`,
`blocks.dart`, `plugin_panel.dart`, `plugins_settings.dart`,
`plugin_icons.dart`) and `lib/modules/plugins_module.dart`.

**Loading and settings.**

- Plugins load only in developer mode: Settings ▸ Integrations ▸ Plugins ▸
  Developer mode, or `--plugin-dev <dir>` (repeatable; turns dev mode on).
  A dev folder is a plugin folder or a folder of them. In dev mode the
  installed folder (`~/.config/k8sman/plugins/*`) loads too. There is no
  install, index or signing yet; every plugin is "Unpacked".
- settings.json keeps them under one key, `plugins: {devMode, devFolders,
  disabled, consent}`, instead of `devPlugins`, `disabledPlugins` and
  `pluginConsent`.
- Discovery runs in a goroutine at start. Dev plugins compile every kind at
  load, so errors show on save; plugins from the installed folder compile a
  kind entry on first use. A kind entry is *active* where the current
  cluster serves its kind (shown on the Plugins page); contributions only
  ever apply to served kinds. A kind's `version` pin applies the entry only
  when the table reads that version.
- Fields of v1 that Milestone 1 doesn't build (`related`, `metrics`,
  `alerts`, patch actions and `inputs`, `permissions.patch` and
  `.prometheus`, `background`) are a warning and ignored, not an error, so
  a manifest written for the full v1 still loads. An expression that uses
  `related` fails to compile (undeclared reference). Milestone 2 builds
  them all; none warns any more.
- Unknown fields, wrong types, bad ids, icons, block fields and column
  types are errors at their `file:line:col`. CEL errors are mapped from the
  expression into the file, through quoting and block scalars.
- Hot reload: fsnotify on each plugin folder and on the folders of plugins,
  debounced 150 ms. A good load replaces the plugin and bumps a generation;
  a bad one keeps the previous version running, with the new errors shown.
  Open tables resubscribe (a fresh snapshot with the new columns) when a
  change alters their columns; the UI refetches panels and the plugin list
  on `WS /api/plugins/events`.

**CEL.**

- cel-go v0.27.0, with the standard library, optional types,
  `ext.Strings`, `ext.Sets`, UTC default time zone and cross-type numeric
  comparisons; homogeneous aggregate literals off.
- The Kubernetes Lists, Regex, URLs and Quantity libraries are copied from
  `k8s.io/apiserver` v0.33.3 into `internal/plugins/k8scel` (Apache-2.0,
  attribution in `doc.go` and each file). IP, CIDR, Format and Semver are
  not included yet. Importing the apiserver package instead would have
  pulled in most of its module.
- `namespace` is a reserved word in CEL (cel-go refuses it as a variable),
  so the object's namespace is **`ns`**; `ref(group, kind, name)` uses it.
- `variables` is not a map: each variable is declared as
  `variables.<name>` with the type its expression checks to, compiled in
  dependency order, and evaluated lazily at most once per evaluation. So
  `variables.notAfter.value()` type-checks like the expression it names (a
  `map(string, dyn)` made `timestamp(variables.x.value())` fail at run
  time). `variables.?x` and `has(variables.x)` aren't available (every
  variable is declared); an unknown name is an error at its position, a
  cycle an error naming the path.
- `age(t)`, `until(t)` and `ref(group, kind, name)` are macros for
  functions that take `now` / `ns`, so functions stay pure and a use of
  `now` is visible in the AST.
- Results are plain JSON: an empty optional is null, timestamps RFC3339,
  durations seconds, quantities and URLs strings. A Ref is
  `{group, kind, namespace, name}`.
- Secrets: plugins see `data` and `stringData` keys with `""` values, and
  no `last-applied-configuration` annotation.

**Columns.**

- `columns.Column` gains `Plugin` (the plugin id, serialised), `Program`
  (an interface the plugin package implements, so no import cycle) and
  `Rev`. The table builder's row-memo tag includes plugin revisions; a row
  without jq columns skips `PrivateCopy` (CEL doesn't write to its input).
- A column reading `now` puts a 30 s bucket in its memo key: it is
  re-evaluated on the next snapshot or event after the bucket turns, not on
  a timer. `type: until` columns don't need `now` and count down in the UI.
- Cells are bounded by the cost limit (100,000) only; there is no 10 ms
  per-cell timeout, since a timer per cell would cost more than the cell.
- A saved column set (an override or a view) keeps plugin columns by
  plugin and name; if the plugin isn't loaded the cell says so.
- Measured on an M1 Pro (`go test ./internal/server -bench
  TableSnapshot`), 1,500 pods: defaults 36.0 ms cold / 0.48 ms warm; three
  jq columns 45.3 / 0.49 ms; three plugin columns 41.4 / 0.50 ms. Plugin
  columns: +5.4 ms cold (budget 10), +0 warm, about 1.2 µs per cell, and
  cheaper than jq doing the same. The bundled cert-manager plugin loads in about
  1.3 ms and compiles (4 kinds, about 45 expressions) in about 9 ms.

**Panels.**

- Transport (question 5): plain HTTP, `GET /api/plugins/panel` for the
  object, refetched when its resourceVersion or the plugin generation
  changes; the backend reads the object from the inspector's warm watch
  (or its namespace's) before falling back to a GET.
- Placement: after the kind's own sections and before Owns and Metadata,
  for compiled-in and generic panels alike (the generic summary isn't
  replaced). `collapsed: true` sections start collapsed. Several plugins:
  plugin id order.
- Budgets as designed: 1,000,000 per expression, 5,000,000 and 250 ms per
  render.

**Shell actions.**

- Shell actions only (patch is Milestone 2). They appear in the inspector
  header (and in row menus once the inspector has loaded them for that
  object); not in the palette yet. `shortcut` is read but not bound yet
  (both are in Milestone 2).
- Hidden and refused on read-only contexts, dangerous or not (question 3).
  `dangerous` styles the confirmation; `confirm: false` is ignored with a
  warning: every run is confirmed, showing the full argv.
- First-use consent per plugin, stored as a hash of its permissions
  (re-asked when they change); also Allow… / Revoke in the Plugins
  settings.
- `GET /api/local-shell?plugin=&action=&group=&version=&resource=&namespace=&name=`:
  the backend re-checks the module, read-only, consent and the action's
  `when` on every run, expands the k9s variables (including `$COL-<NAME>`
  from the object's table row), looks the command up on the PATH and runs
  it without a shell in the dock, with `K8SMAN_<NAME>` exported. The dock
  tab's Restart doesn't re-run it (each run is confirmed).

**Navigation (question 7).** New top-level `nav: {title, kinds?}`
(a sidebar section; `kinds` defaults to the plugin's kinds in file order).
Integration sections list after the core ones, alphabetically by title; the
user can reorder them in Settings ▸ Sidebar. `after` is deprecated and
ignored (still accepted)
and per-kind `icon` (a name from the icon list, or `icon.png`). The icon
list is 62 Material names, in `internal/plugins/icons.go` and
`lib/plugins/plugin_icons.dart`.

**Not built in Milestone 1** (per the milestones): related objects,
metrics, alerts, patch actions and inputs, the JSON Schema, fixtures and
`plugin test`/`render`/`new`/`import-k9s`, distribution (index, signing,
install, updates), suspension after repeated limit hits (dev plugins are
never suspended in the design either), and the palette entries.

**Size.** The backend grows by 5.1 MiB (68.3 → 73.7 MB, stripped,
darwin/arm64), within the 6 MB budget; most of it is cel-go and its ANTLR
runtime.

### Milestone 2

**Where.** Backend, `internal/plugins`: `related.go` (the `Lookup`
interface, related objects and metrics), `actions.go` (input checks and
patch bodies), `alerts.go`, `fixtures.go` (`plugin test` and `render`),
`schema.go` (the JSON Schema), `scaffold.go` (`plugin new`) and `k9s.go`
(`import-k9s`). `internal/server/plugins_data.go`: the lookup over `kcache`
and the Prometheus module, the plugins module as `ActionSource` (patch
actions) and `OverviewSource` (alerts), and `POST /api/plugins/run`
(background shell actions). The schema is checked in as
[`schema/plugin.v1.json`](../schema/plugin.v1.json). Frontend:
`lib/plugins/plugin_actions.dart` (consent, the input form, the dry-run
preview, background runs); `plugin_panel.dart` gains notes and refresh;
plugin actions are in the palette (`ui/palette/palette_sources.dart`) and
bound to their shortcuts in the table (`ui/resource_table.dart`).

**Related objects and metrics.**

- Served by `kcache.List`, which starts a stream (one LIST) or reads a warm
  one and keeps it warm for its idle period (90 s), rather than subscribing
  while the panel is open. Instead of a push when a related object changes,
  the panel response carries `refresh` (5 s with related objects, 15 s with
  metrics, 30 s with `now`) and the UI fetches again while the panel is
  open; renders after the first come from memory.
- A `name` relation is a `metadata.name=` field-selector key, which rides a
  warm stream of the namespace when there is one; `owner` lists the
  namespace (cluster-wide for a cluster-scoped subject without
  `namespace`) and filters by uid; `selector` is a label-selector key.
  Lists are sorted by namespace and name and capped at 200 (with a note).
  An empty selector reads nothing rather than everything.
- Only the relations and metrics that panel (or action) expressions name
  are looked up; the names come from the parsed ASTs, through variables. A
  use of the whole map (`related` passed to a function) looks up all of them.
- Lookups run first, with their own budget (250 ms of CEL for their
  expressions, 5 s for the lookups); the 250 ms render budget starts after
  them.
- Question 2 (related data in columns and alerts) is unchanged: columns
  and alerts see the object only, as §5 has it. `related` or `metrics` in a
  column or alert, also through a variable, is a load error at the
  expression ("related isn't available in columns (only in panels and
  actions); a variable it reads uses related"). Lookup expressions and
  metric queries can't read `now`, `related` or `metrics` either.
- Action expressions (`when`, input `default` and `validate`, `body`) may
  read `related`, as §5 has it (not `metrics`). The panel endpoint looks up
  the relations they name when it lists actions.
- What couldn't be read is a `notes` line above the plugin's sections ("X
  aren't served by this cluster", "not allowed to list secrets in demo",
  "Prometheus isn't available: metrics are empty").
- Metrics use the Prometheus module's `QueryVectorAt` (the default instance
  or `instance`, an id or name) and need the module on; answers and errors
  are cached 15 s per context, instance and query.

**Patch actions.**

- The plugins module is an `ActionSource`: each patch action is
  `plugin.<id>.<action>` with the target `kind:<group>/<Kind>` (a new
  target form, beside `group/resource`), so `handleAction` refuses it on
  read-only contexts, checks availability and passes `dryRun` as for any
  action. `RunAction` reads the object (a GET), checks consent (the same
  permissions hash as shell actions), `when`, the inputs and
  `permissions.patch`, builds the body and patches with field manager
  `k8sman`.
- Never Secrets: `/Secret` in `permissions.patch` is a load error and the
  server refuses it too. A body may not change `apiVersion` or `kind`; a
  merge body must be a non-empty map, a JSON patch a list of `{op, path}`
  operations.
- Inputs missing from the request take their default (or "", 0, false or
  the first option); string inputs are at most 4,096 characters; unknown
  inputs are refused.
- The UI's flow: consent if needed, the form (**Preview** runs the dry run;
  a refusal shows in the form), then the confirmation with the patch, a
  diff of the object before and after (YAML without `managedFields`,
  `resourceVersion` and `generation`) and the context, then the change. A
  dry run answers `preview` in the action result. `dangerous` only styles
  the confirmation (default true, as for shell actions).
- `background` shell actions run through `POST /api/plugins/run` (the same
  checks as a dock-tab run, at most 2 minutes, the last 20 lines of
  output), reported in a snackbar with the output on request.
- `shortcut` is bound in the table, on the selected row once the inspector
  has loaded its actions: one letter or digit, optionally `shift+`. The
  table's own keys win; other forms (`ctrl+`, `alt+`) and clashes are a
  load warning. The palette lists the inspected object's plugin actions
  (after its panel has loaded) as **Plugin Action** items.

**Alerts.**

- One overview source, `plugins`, evaluates every active plugin's alerts
  (500 ms per plugin per poll) over `listCached` in the overview's scope
  and adds `overview.Finding`s: category `plugin.<id>.<alert>`, label and
  section from the alert, the issue's reason is the label. The pending
  source is reported under the `custom` section, which the Overview titles
  **Plugins**.
- There is no 10 ms per-object timeout, as for cells: each expression is
  bounded by the 100,000 cost limit, and the plugin by its 500 ms.
- Results are memoised per object version (uid and resourceVersion) for 30
  seconds, so a poll re-evaluates only changed objects, and alerts that
  read `now` move on with the next 30 s bucket (as `now` columns do).
- Evaluation errors (the first three per kind) are returned in the
  overview's `errors`; the object is skipped.

**CEL.** A `list.sort()` function is added (strings, numbers, booleans,
timestamps), a compatible addition: CEL iterates maps in no particular
order, so a list built from a map's keys needs sorting to be stable (in
panels and in snapshots). cel-go's whole `ext.Lists()` was tried first and
dropped: it made every plugin cell about 1 µs slower (+5 ms cold on the
1,500-row benchmark).

**JSON Schema.** Generated from the manifest types and the loader's own
lists (column and value types, block fields, icons, severities, sections,
input and patch types) by `k8sman-server plugin schema`, and checked in at
`schema/plugin.v1.json` in this repository (there is no plugins repository
yet); its `$id` and the files' `yaml-language-server` comment point to
`https://raw.githubusercontent.com/matty234/k8sman/main/schema/plugin.v1.json`.
A test fails when the file is stale, and checks that the cert-manager
example passes it and that a typo doesn't. It describes fields, types,
enums and per-block fields; rules across fields (exactly one of `name`,
`owner` and `selector`, the permissions, CEL) are `plugin validate`'s.

**Fixtures and the CLI.**

- `fixtures/test.yaml` also takes `metrics` (query string → samples);
  without it there is no Prometheus. Defaults: `now`
  2026-01-01T00:00:00Z, `context` demo.
- A snapshot has the object's key, the plugin's own cells (not the
  default columns, which need a cluster), the resolved panel (with
  `notes` and `refresh`), the actions (shell argv; patch inputs and the
  body built from their defaults) and the alerts. `$RESOURCE` is the
  kind's lower-case plural, and `$COL-<NAME>` covers the plugin's columns
  only.
- `plugin new <id> [<parent>]` writes the snapshot of its fixture, so a new
  plugin passes `plugin test` at once. `plugin schema` is new.
- `import-k9s` has no cluster to ask, so scopes are mapped with a table of
  built-in kinds and their k9s aliases; a `plural.group` scope is guessed
  (with a warning) and an unknown one skipped. Entries with `$POD`,
  `$CONTAINER` or `$FILTER` are skipped, `confirm: false` and unknown fields
  are dropped with a warning, and the plugin goes to stdout.

**Numbers** (M1 Pro, `go test -bench`):

- `BenchmarkPluginData` (the bundled cert-manager plugin): alerts over 1,000
  Certificates, about 10 ms when every object is new (once per 30 s
  bucket, or for changed objects) and about 0.2 ms on a poll that reuses
  the memo; the Certificate panel with its related objects and metric
  warm, about 0.15 ms (budget 5 ms p95).
- `BenchmarkTableSnapshot` (1,500 pods, three plugin columns) is unchanged
  by Milestone 2, as related data stays out of tables: measured back to
  back on a busy machine, 41–44 ms cold and 1.9 ms warm, against 46–52 ms
  and 1.9 ms for the Milestone 1 build in the same minutes.
- The backend grows by 0.27 MB (73.86 → 74.14 MB, stripped,
  darwin/arm64).

**Not built in Milestone 2:** distribution (Milestone 3), suspension after
repeated limit hits, the IP, CIDR, Format and Semver CEL libraries, and
`$POD`, `$CONTAINER` and `$FILTER` in shell actions.

### Bundled plugins: the External Secrets pilot

**Where.** `internal/plugins/bundled` (the embedded folders and
`ReplacesModule`); `host.go` loads them from an `fs.FS`
(`Options.Bundled`, `Options.Replaces`; every plugin now reads its files
through one, `os.DirFS` for folders). Settings: `plugins.useModule`.
Server: `moduleOff` (`module.go`) keeps a replaced module off and the
`plugins` module's routes mounted; `GET /api/settings/modules` adds
`superseded`. Frontend: bundled rows in `ui/settings/integrations_settings.dart`
(`BundledPluginTile`, sharing `IntegrationRow` with modules),
`AppState.supersededModules`, plugin sidebar sections from `pluginHost`
directly (`ui/resource_nav.dart`), and the comparison switch in
`plugins/plugins_settings.dart`.

**Changes to how plugins work, for every plugin:**

- Which plugins apply is decided by the backend (`Info.active`): bundled
  ones unless turned off, overridden or set aside for their module; the
  user's own in dev mode with the `plugins` module on. The `plugins`
  module's switch no longer turns bundled plugins off, and its routes stay
  mounted (they 404 only on an older backend).
- Panels: for a kind without a dedicated panel (the generic one), plugin
  sections now come *before* the generic sections, as §4 placed them,
  instead of after. Kinds with a compiled-in panel are unchanged (after).
- Plugin sidebar sections show whether the `plugins` module is on or not.
  Kind icons from plugins win over a module's for the same kind.
- New icon: `upload` (63 names).

**Size.** The backend grows by 51,664 bytes (74,020,258 → 74,071,922,
`-trimpath -ldflags="-s -w"`, darwin/arm64): the embedded `plugin.yaml` and
README and the loading code.

**What the plugin can't match yet.** Compared with the `external_secrets`
module and its panels (`frontend/lib/panels/externalsecrets/`), in order of
how much it shows:

1. **The generic panel stays.** ESO kinds have no compiled-in panel in
   plugin mode, so the inspector shows the plugin's sections and then the
   generic panel's (Health, Conditions, Spec and Status trees). The module's
   panels replaced the generic one. Longer and partly repeated (Ready shows
   in Health and Conditions too). Needs a way for a plugin to replace or
   collapse the generic sections (the rest of §4's placement).
2. **Store provider settings.** The module walks the provider's settings to
   any depth into up to 14 `path → value` rows, turning every `*SecretRef`
   into a Secret link (with its key) and `serviceAccountRef` into a
   ServiceAccount link, and shortening long values. CEL has no recursion or
   `flatten`, so the plugin shows the provider settings as a JSON tree; the
   references are text, not links.
3. **"ExternalSecrets using this store".** There is no "every object of a
   kind" relation; the plugin lists ExternalSecrets with a selector no
   object fails (`k8sman.dev/none DoesNotExist`) and filters by
   `secretStoreRef` in CEL. Related lists are capped at 200 objects
   *before* the filter (with a note), so in a namespace (or, for a
   ClusterSecretStore, a cluster) with more than 200 ExternalSecrets some
   users can be missed. The module read them all and showed 50.
4. **Refresh now asks first.** The module's action ran on one click
   (`confirm: false`). Plugin patch actions always run a dry run and show a
   confirmation with the diff (by design, §3). It is offered on PushSecrets
   too (the backend module accepted them; its UI never offered it).
5. **Integrations status.** The module's row said "ExternalSecrets: N · not
   synced: M" and turned red when any wasn't synced; the plugin's row says
   which of its kinds the cluster serves. Plugins have no status summary.
6. **Missing target Secret.** The module GETs the Secret and warns only on
   a 404. The plugin reads it through a `name` relation (a list with a field
   selector), so it needs list rights on Secrets; without them it warns too
   (with a note saying why).
7. **Section headers.** The module puts the Ready badge and counts
   (mappings, provisioned and failed namespaces) in section headers and
   draws the first section as a card. Plugin section titles are plain text
   with no trailing widget; the badge is the first block.
8. **Small renderings.** Ready not true is a message "Reason: message"
   (warning for Pending, Progressing, Unknown or Waiting, else error) rather
   than a callout titled with the reason; a Ready message is an info line
   rather than a hint. Last refresh is an age without the timestamp;
   Synced version and the mapping tables aren't monospace; selectors are
   chips, not monospace lines; `dataFrom` entries are rows of a table.

Not a gap: the module has no overview issues, so the plugin has no alerts
("ExternalSecrets not synced" would be a natural first one). Icons, the
sidebar section, the columns, the store and target links, the owning
ClusterExternalSecret, the target's keys (never values), data mapping and
template match.

**Managed by.** The core Secret panel's "Managed by ExternalSecret X" line
(`panels/externalsecrets/managed_by.dart`) is untouched and still shows in
plugin mode. A plugin could provide it with a `/Secret` kind entry (a
section with a link built from `ownerReferences`, or "External Secrets
Operator" from the `reconcile.external-secrets.io/managed` label), but it
would sit after the Secret panel's own sections rather than at the top,
and the plugin would be asked about every Secret panel. Keep it core: move
`managed_by.dart` into `panels/config` when the module goes.

### Closing the pilot's gaps; the module removed

Four additions to the vocabulary, each generic (none names ESO), close
the gaps that mattered; the External Secrets plugin uses all of them and
the `external_secrets` module is gone.

**Vocabulary added** (compatible, per §5's contract; in the schema):

- `panel.generic: keep | collapse | replace` (gap 1). The UI reads it from
  `GET /api/plugins` (`kinds[].generic`); `panelFor` in
  `lib/panels/registry.dart` composes the panel: `collapse` builds the
  generic panel with every section collapsed (`GenericPanel(collapsed:
  true)`), `replace` leaves its sections out (`PluginComposedPanel
  .replaceBase`), keeping its tabs and actions. If two plugins disagree,
  `replace` wins over `collapse` over `keep`. The inspector shell
  (`ui/detail/detail_sidebar.dart`) needed no change: its Owns and
  Metadata sections are its own, not the panel's.
- The `settings` block (gap 2), in `internal/plugins/settings_block.go`:
  the flattening and reference detection described in §4, done by the host
  because CEL can't recurse. Rows are sorted by path (the module kept the
  YAML's order). A reference whose namespace isn't known (a
  ClusterSecretStore's `secretRef` without `namespace`) is text, not a link
  (the module linked it with no namespace).
- `status` on a kind (gap 5), in `internal/plugins/status.go`, served by
  `GET /api/plugins/status`; the bundled plugin's Integrations row shows
  the line (fetched when the row is built, again after 30 s or on a
  context or plugin change), red for a critical count, amber for a
  warning (`ModuleState.warning`, new), else as before. **Why a manifest
  field and not lines derived from the alerts:** alerts answer "which
  objects have a problem", per object and in the overview's namespace
  scope, with labels written for the Overview ("ExternalSecrets not
  synced for over a day"); the status line answers "how many are there
  and how many are wrong" across the cluster, which needs the total count
  that no alert has, and short count labels. A shared predicate goes in a
  variable both read (as `notSynced` does). Snapshots include the line
  for the fixture's object.
- `mono: true` on `fields` items and `table` columns, and `title` on
  `message` blocks (gap 8): a warning or error with a title is a `Callout`
  headed by it, as the module's Ready callout was.

**Alerts.** ExternalSecrets have two: *not synced* (warning: Ready is
False) and *not synced for over a day* (critical: Ready False since a
`lastTransitionTime` at least 24 h ago). They show under Plugins on the
Overview and in the dock's Issues tab. Fixtures: `externalsecret-error`
(failing a day: critical) and `externalsecret-not-synced` (an hour:
warning).

**Columns.** The built-in ESO jq columns (`internal/columns`) are removed:
the plugin supplies every column, and `hideColumns` drops the CRD printer
columns it repeats (`Refresh Interval`, and the filter-based `Ready` and
`Status`, which the table skips anyway). With the plugin off, the tables
show the CRDs' printer columns.

**The pilot's list, now:**

1. Generic panel: replaced (`generic: replace` on every ESO kind with
   sections; PushSecret, which has none, keeps the generic panel, as the
   module did). Stores gained a Conditions section, as the module had.
2. Provider settings: `settings` rows with Secret and ServiceAccount links.
3. "ExternalSecrets using this store" capped at 200 before the filter:
   **accepted**, unchanged.
4. Refresh now confirms with a dry run: **accepted**, unchanged.
5. Integrations status: the status line.
6. Missing target Secret needs list rights on Secrets: unchanged (it warns,
   with a note, without them).
7. Section headers: unchanged; the Ready badge is the first block, and
   sections aren't drawn as cards.
8. Small renderings: callouts titled with the reason, monospace synced
   version, mappings and selectors (a one-column table); Last refresh is an
   age whose tooltip has the timestamp (`AgeText` already did). A Ready
   message is still an info line, and `dataFrom` entries rows of a table.

**Removed.** `lib/modules/external_secrets_module.dart`,
`lib/panels/externalsecrets/` (`managed_by.dart` moved to
`lib/panels/config/`, unchanged in behaviour),
`internal/server/externalsecrets.go` (the `externalsecrets-refresh`
action; the plugin's `plugin.external-secrets.refresh` replaces it), the
ESO built-in columns and their test, and the `external-secrets` entry of
`bundled.ReplacesModule` (now empty; the `useModule` mechanism stays for
the next module a plugin replaces).

### DRA and Kyverno ports: format changes

The `dra` and `kyverno` modules are now the bundled plugins
[`dra`](../backend/internal/plugins/bundled/dra) and
[`kyverno`](../backend/internal/plugins/bundled/kyverno), and both
modules are removed. Every change to the format is an addition (no v1
plugin breaks); each is generic, and the External Secrets plugin and the
bundled cert-manager plugin use the ones that fit them.

**Where.** Backend, `internal/plugins`: `manifest.go` (`Tab`,
`Section.Summary`, `TableColumn.Detail`, `Related.Filter` and `.Limit`,
the wider `"*"` rule, `hostTabs`), `compile.go` (tabs, summaries, filters
compiled with `item`), `related.go` (filters, limits), `eval.go` (tabs,
summaries, detail columns, code values as YAML, Secrets blanked by their
own kind), `host.go` (a plugin's kind and `"*"` entries render into one
panel; `hideColumns: ["*"]`; idle refresh), `celenv.go` (`item`,
`flatten`, `distinct`), `icons.go` (15 icons, 78 in all). Frontend:
`plugins/plugin_panel.dart` (`pluginPanels`, one fetch per object shared
by the tab bar, the Overview's sections, plugin tabs and the Security tab;
`PluginTabView`; `PluginSlotSections`), `plugins/blocks.dart` (summaries,
detail columns, sections drawn as the host tab's own), `panels/panel.dart`
(`PanelTab.slot`), `ui/security/security_tab.dart` (the `security` slot),
`ui/detail/detail_sidebar.dart` (rebuilds when plugin tabs arrive).

**Format changes**, with why:

1. **`panel.tabs`** (`title`, `icon`, `when`, `into`, `sections`). The
   Kyverno module added a "Policy results" tab to any kind
   (`inspectorTabs`) and the Security tab embedded its widget for Pods and
   workloads. A tab is the generic form of both: `into: security` is a
   *slot*, a tab of the app's own that the tab's sections join on kinds
   that have it; elsewhere it is a tab of its own. Any policy engine
   (Kyverno, Gatekeeper, Kubewarden) declares the same thing and lands in
   the same place, and the host decides where slots are. Rejected: a
   per-feature key such as `contributes: {securitySection: …}` (one key per
   host feature, nothing in common between them), and gating tabs on
   served kinds (the format has no detection; `when` over related objects
   is more precise: the tab appears on objects with results, not on every
   object of a cluster that runs the engine). `when` may read related, so
   tabs are dynamic: the UI learns them from the panel render and the tab
   bar is rebuilt when they arrive, as it already was for a module's tab
   appearing after detection.
2. **`"*"` holds more**: variables, related, metrics, panel sections and
   tabs, actions (not columns, `hideColumns`, alerts, `status`, `icon`,
   `version` or `panel.generic`: those run over whole tables or every
   object of a kind). A plugin's kind entry and its `"*"` entry render into
   one panel, the kind's first. **Security fix on the way:** objects seen
   through `"*"` are now prepared by their own kind, so a Secret's values
   are blanked there too (before, only an entry keyed `/Secret` blanked
   them, so a `"*"` action's `when` could have read a Secret's data).
3. **`related.filter`** (CEL bool over `item`) and **`related.limit`**
   (default 200, at most 2,000). DRA's Node section needs the
   ResourceSlices whose `spec.nodeName` is the node (no label to select
   on); a Kyverno policy needs the reports that mention it; External
   Secrets' "ExternalSecrets using this store" used a selector no object
   fails and filtered in CEL *after* the 200 cap (pilot gap 3). The host
   now filters before the cap, and `limit` lets a panel that summarises
   (a policy's results across the cluster) read more.
4. **`summary`** on sections: the modules put counts and states in section
   headers (requests, devices, slices, results); pilot gap 7 was the same.
   Text only.
5. **`detail`** on table columns: messages, CEL selectors, device
   attributes and rule definitions are too wide for a cell in the
   inspector; the modules drew them under the row.
6. **`code` values that aren't strings are YAML** (the `code` block, and
   `type: code` fields and cells): a Kyverno rule's definition. CEL can't
   serialise, and the host already had the object.
7. **`flatten()` and `distinct()`**: results of several reports,
   requests with `firstAvailable` alternatives, the distinct device classes
   and nodes the module's jq columns computed with `unique`. Custom
   functions, like `sort()`, not cel-go's `ext.Lists()` (Milestone 2
   measured it slowing every cell).
8. **`hideColumns: ["*"]`**, and column names matched in any case. Kyverno
   CRDs have upper-case printer columns (ADMISSION, BACKGROUND, READY,
   MESSAGE, …) that the module's built-in columns replaced wholesale; the
   plugin says "my columns are the table's" without guessing names.
9. Behaviour, not vocabulary: a panel that shows nothing re-renders every
   30 s instead of every 5 (a `"*"` tab on objects without results);
   notes about what couldn't be read show only beside a plugin's sections
   or in its tab (a `"*"` relation's "PolicyReports aren't served" stays
   quiet elsewhere); a bundled plugin's Integrations row counts its sidebar
   kinds as its own (DRA's `/Pod` and `/Node` entries don't make it look
   installed everywhere); `status` values colour `pass`, `warn` and `fail`
   (the policy-report results) like Ready, Pending and Failed.

**DRA: what moved, and the differences.** Columns, panels (claims,
templates, device classes, slices; DeviceTaintRule keeps the generic
panel), the sidebar section and icons are the plugin's; it adds a status
line ("ResourceClaims: 4 · pending: 1"). The **Pod and Node sections moved
too**: `/Pod` and `/Node` entries add them cleanly (a pod's claims come
from the pod alone; a node's slices through a `filter` relation), and
turning the plugin off now removes them as well. Differences from the
module:

1. Placement: plugin sections follow a compiled-in panel's own, so
   Resource claims is the Pod's last section (the module put it after
   Configuration) and DRA devices the Node's last (it was second). There
   is no placement field (freeze checklist).
2. A node's slices come from the warm cluster-wide ResourceSlice stream,
   filtered (about 1.3 ms per 1,000 slices), not a LIST with a field
   selector on every open.
3. The claim's state is a badge block, not a badge in the header; counts
   are header summaries (text).
4. Requests are table rows: a `firstAvailable` alternative is a row named
   `gpu/large (first available)` rather than an indented list; CEL
   selectors are monospace detail lines rather than boxed blocks.
5. A slice's devices: capacity and taints are text (taints were amber
   chips), attributes a detail line rather than chips; a claim's device
   conditions are text (`Ready=True (Configured)`) rather than a
   conditions table; driver config parameters are YAML rather than a
   collapsed JSON tree.
6. An allocation on several nodes lists them as text (one node is a link).
7. The claim's template is read through a `name` relation on Pods (list
   rights on Pods in the namespace), not a GET.

**Kyverno: what moved, and the differences.** Columns (with
`hideColumns: ["*"]`), the ClusterPolicy/Policy and PolicyReport/
ClusterPolicyReport panels, the sidebar section and icons (1.14+
`policies.kyverno.io` kinds have icon-only entries), a status line
("ClusterPolicies: 12 · not ready: 1 · Policies: 3", where the module said
"15 policies"), and the any-kind **Policy results**: a `"*"` tab with
`into: security`, from the PolicyReports (ClusterPolicyReports for
cluster-scoped objects) the object owns. `ObjectPolicyResults` is gone;
the Security tab draws the slot's sections (`PluginSlotSections`) and no
core widget had to move. Differences:

1. The tab (and the Security tab's section) appears only on objects that
   have results; the module showed it on every kind once Kyverno was
   detected, saying "No policy reports mention this object".
2. Only reports the object **owns** are read: Kyverno 1.10+ writes one per
   resource, owned by it (and other engines that write per-resource
   reports, such as Kubewarden's audit scanner, show too). The module also
   matched entries of the older aggregated reports (`results[].resources`)
   by uid or kind and name. Doing that for every inspected object would be
   a CEL scan of every report in the namespace on each inspection, so it
   was dropped; the policy and report panels still read the aggregated
   shape.
3. A policy's Results read up to 2,000 reports that mention it (with a
   note beyond); the module read all of them.
4. The report panel has no per-result filter chips: results are failures
   first, 50 then "Show all".
5. A rule is its name, type, the kinds it matches, its message and its
   definition as YAML, rather than formatted match, exclude and
   preconditions lines.
6. No Refresh button: open panels re-render every 5 s from the watch
   cache (the module cached reports for 30 s).
7. The Policy section isn't drawn as a card; result rows are table rows.

**Cost of the any-kind tab.** Every inspected object now asks for its
plugin panel (before, only kinds a plugin contributed to). With the
Kyverno plugin, the `"*"` entry looks up the object's reports with an
`owner` relation over the namespace's PolicyReports in the watch cache:
`BenchmarkPluginData` (M1 Pro), 2,000 reports in the namespace, **0.21 ms**
for a pod that owns one (the tab rendered) and **0.12 ms** for an object
that owns none. It runs again every 5 s while the tab shows and every 30 s
otherwise. Without Kyverno the relation stops at discovery (the kind isn't
served). The namespace's PolicyReport stream stays warm for 90 s after the
last read, as the module's list was cached for 30 s. Kyverno's own kinds,
reports and Events skip the lookup (`when`). The DRA Node filter over
1,000 slices is 1.3 ms.

**Tables.** `BenchmarkTableSnapshot` (1,500 pods) is unchanged: before,
33.8–49.8 ms cold and 2.09–2.13 ms warm for the defaults, 39.0–39.4 ms /
2.28–2.48 ms with three plugin columns; after, 32.9–36.0 / 2.11–2.40 ms
and 39.1–39.5 / 2.30–2.49 ms. The DRA and Kyverno jq columns became CEL
columns of their plugins; their tables are small and memoised like any.

**Removed.** `lib/modules/dra_module.dart`, `lib/panels/dra/` (with the
Pod and Node sections in `dra_sections.dart`), `lib/modules/kyverno_module.dart`,
`lib/panels/kyverno/` (with `ObjectPolicyResults`), the DRA columns of
`internal/columns/builtin.go` and `internal/columns/kyverno.go`.

## v1 freeze checklist

What should still change, or be decided, before third parties build on
`k8sman.dev/v1`:

1. **Section placement on compiled-in panels.** Plugin sections always come
   after a core panel's own (DRA's Pod and Node sections sit last). A
   `placement` (`top`, `bottom`, or after a named core section) needs core
   sections to have stable ids first.
2. **Header badges.** `summary` is text; a coloured state in a header (the
   ESO Ready badge, the DRA claim state) is still the first block. Decide
   between a `summarySeverity` and leaving it.
3. **Severity of table and field values.** `status` colours itself from a
   word list in the app; a plugin can't say "this cell is an error". A
   `severity` (CEL) on columns and fields, as badges have, would retire the
   list for plugins. Also make the badge severity names an enum in the
   schema (`error`, `critical`, `warning`, `warn`, `ok`, `success`,
   `info`, `neutral` are accepted today, undocumented).
4. **Host tab slots.** `into` accepts `security` only. Decide the slots
   (and their names, which become API) before others ask: a network or
   logs tab are candidates.
5. **Tab identity.** A tab is identified by its title (unique per entry).
   An `id` would let titles change without breaking remembered tabs.
6. **The `"*"` cost model.** Any `"*"` panel entry makes every inspection
   fetch the plugin panel. A `kinds` list or exclusions on `"*"` (so the UI
   can skip the fetch, and authors needn't write `when` for it) and a
   per-plugin budget for `"*"` lookups would bound it before many plugins
   do this.
7. **Naming.** `row` (table columns), `item` (related filters) and `input`
   (actions) are three names for "the thing being looked at"; `ns` is the
   CEL variable but `namespace` the related field. Settle or document as
   final.
8. **Interactive tables.** No filter chips or per-column sorting in the
   UI; a `filterBy: <column>` on tables would cover the Kyverno report
   panel.
9. **Aggregated policy reports.** If matching results by resource across a
   namespace's reports is wanted on every object, it needs an indexed
   lookup in the host (by uid), not a CEL filter.
10. **Distribution** (Milestone 3: index, signing, install, consent
    upgrades) is still unbuilt; `minAppVersion` is the only versioning a
    plugin has.
