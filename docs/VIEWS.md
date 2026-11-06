# Saved views and multi-namespace tables (design)

Status: proposal, nothing implemented. This doc covers two related requests:

- **Saved views:** save a table's state, for example "My back-end
  deployments" (Deployments, namespaces 1, 2, 3, 5, filter `back-end`), and
  open it again in one step.
- **Multi-namespace selection:** choose a *set* of namespaces instead of one
  namespace or all.

A view belongs to **one context**, or it applies to **any context**. Tables
that show several clusters at once are out of scope (see "Future work").

## How things work today

| Area | Today | Code |
|---|---|---|
| Namespace scope | `AppState.namespace` (`String?`, null = all), `setNamespace`, `recentNamespaces` (session only). Overview, Security, Alerts and Metrics each keep a single-namespace `PageScope`. | `state/app_state.dart`, `ui/widgets/namespace_picker.dart` |
| Table socket | `WS /api/watch`, `/api/table` and `/api/items` take one `namespace`, or none for all. One `kcache.Sub` per socket. | `server/stream.go`, `parseResource` |
| Watch cache | One `kcache.Cache` per context; key `{GVR, Namespace, selectors}`; tables with the same key share one upstream LIST+WATCH. `warmLocked` serves a one-namespace key from a warm all-namespaces stream. Streams nobody uses stop after 90 s. | `internal/kcache` |
| Table state | `TableController` keys rows by `uid`. Filter (`table_query.dart`) and sort run in the client and are saved **per kind** (`/api/settings/tables`). Column overrides are global per resource. | `state/table_controller.dart`, `state/table_prefs.dart` |
| Persistence | `settings.json` through `settings.Store`. `/api/settings/*` works without a connection. | `internal/settings`, `server/sidebar.go` |
| Pins | `SidebarPin{group, kind, namespace?}`: already a minimal view that applies to any context. | `state/sidebar_config.dart` |
| Startup | No welcome screen: the app reconnects to the last context and shows `ClusterErrorView` (with pickers) only on failure. | `ui/cluster_error_view.dart`, `ui/connecting_view.dart` |

## 1. What a view is

```jsonc
// settings.json → "views": [ ... ]
{
  "version": 1,
  "id": "9f2c…",                        // stable: renames don't break references
  "name": "My back-end deployments",
  "context": {"kubeconfig": "", "name": "us-east-a"},  // null = any context
  "kind": {"group": "apps", "kind": "Deployment"},     // group/Kind like pins; version resolved by discovery
  "namespaces": ["team-1", "team-2", "team-3", "team-5"], // [] = all; ignored for cluster-scoped kinds
  "filter": "back-end",                 // table_query.dart syntax
  "sort": {"column": "Age", "descending": false}       // optional; by column name, not index
}
```

- **Context identity** is (kubeconfig path, context name), the same as
  `portforward.Spec`. Context names alone can repeat across kubeconfig files.
  `""` means the default loading rules.
- **Views that apply to any context** (`context: null`) open on whatever
  context is current. This suits clusters with the same layout: "Deployments
  in team-1, 2, 3, filtered back-end" works on staging, us-east and eu-west.
  This is how pins already work, so it fits the app.
- **Bound views** (`context` set) are for state that only makes sense on one
  cluster. Opening one switches to that context first.
- **Not stored:** columns (the global per-resource override still applies),
  the selected row and the inspector tab. Any of these can be added later
  under the `version` field. A loader keeps entries with a newer `version`
  untouched rather than dropping them, so a downgrade doesn't lose views.

## 2. Phase 1a: multi-namespace selection

### Backend

`/api/watch`, `/api/table` and `/api/items` accept `namespaces=a,b,c`.
`namespace` stays for compatibility; sending both is a 400. There are two
ways to implement it:

| | One watch per namespace, merged | All-namespaces watch, filtered on the server |
|---|---|---|
| User with only namespaced RoleBindings | **Works.** Each namespace needs `list`/`watch` in that namespace only. | **Fails.** It needs cluster-wide `list`/`watch`: the same 403 the user already gets with "All namespaces". |
| Access to some of the namespaces only | The allowed namespaces show rows; each forbidden one shows its own error. | All or nothing. |
| Data transferred and held | Only the selected namespaces. | Every object of the kind in the cluster, to show four namespaces. Pods in a 1,000-namespace cluster are expensive. |
| Upstream connections | N watches, multiplexed over the context's single HTTP/2 connection (`buildClients` shares one `http.Client`), so they're cheap. | 1 |
| Sharing | Each namespace's stream uses the same `kcache.Key` as a one-namespace table, so they share. If an all-namespaces stream is already warm, `warmLocked` serves every namespace from it, so the merge costs nothing extra. | Shared only with all-namespaces tables. |

**Recommendation: one `kcache.Sub` per namespace, merged in the backend.**
This works for RBAC-limited users. Users who can list cluster-wide still get
the single-stream path through `warmLocked`. A small fan-in, either a
`kcache.MultiSub` or a loop in `handleWatch`:

- waits until every namespace has a snapshot or a terminal error before it
  sends the first SNAPSHOT, so the table doesn't fill in one namespace at a
  time;
- sends a new merged SNAPSHOT when any namespace re-lists (410 Gone);
- reports a namespace's terminal error (Forbidden, NotFound) as a new frame,
  `{type:"PARTIAL_ERROR", namespace, error, reason}`, and keeps the socket
  open. A plain `ERROR` would close it. Old clients ignore frame types they
  don't know.

Uids are unique within a cluster, so row identity doesn't change. For
`/api/table` and `/api/items`, `snapshot()` runs once per namespace (in
parallel) and the results are concatenated.

### Frontend

- `AppState.namespace` becomes a `NamespaceScope`: all, or a set.
  (`AppState.namespaces` is already taken: it holds the namespaces the cluster
  has.) A compatibility getter, `String? namespace`, returns the namespace
  when exactly one is selected and null otherwise. It serves the many call
  sites that need a single namespace: create dialogs, `showInList`, the
  palette object cache, the YAML apply default.
- **Picker:** the namespace picker gets checkboxes, plus "Only this" on hover
  and "All namespaces". The button shows `team-1, team-2 +2`.
  `recentNamespaces` stores sets.
- **Command mode:** `:ns a,b,c`, plus `:ns +a` / `:ns -a` to add or remove a
  namespace.
- **Table:** `TableController` and the `ValueKey` in `ResourceTable` take the
  scope. With more than one namespace the Namespace column shows, as it does
  for "all". A `PARTIAL_ERROR` shows a banner above the rows: "No access to
  team-5 (forbidden)".
- **Pins:** `SidebarPin.namespace` becomes `namespaces`, and the old key is
  still read.
- **Other pages:** Overview, Security, Alerts and Metrics keep their
  single-namespace `PageScope` for now (open question 2).

## 3. Phase 1b: saved views

- **Storage.** `Settings.Views []View` in `internal/settings`, served by
  `GET/PUT/DELETE /api/settings/views` (same pattern as `sidebar.go`). Like
  the other settings routes, it works without a connection, so the error
  screen can list views.
- **Opening a view.** `AppState.openView(view)`: when the view is bound to a
  context that isn't current, call `switchContext` (or `switchKubeconfig`)
  first; then set the namespace scope, call `selectType`, and give the new
  `TableController` the view's filter and sort.
- **View session.** Today every filter or sort change is written to the
  kind's prefs. While a view is open, the table runs a *view session*
  instead:
  - changes don't touch the kind's prefs;
  - the title gets a "modified" dot, and **Update view** / **Revert** buttons
    appear;
  - choosing another kind, namespace or context ends the session, and the
    kind's own prefs apply again.

  Without this, opening a view would overwrite the filter the user keeps for
  that kind.

## 4. UX

**Saving.** A bookmark button in the table toolbar (or ⌘S with the table
focused) opens *Save view…*:

```
┌ Save view ───────────────────────────────────────┐
│ Name      [My back-end deployments             ] │
│ Kind      Deployments                            │
│ Namespaces team-1 · team-2 · team-3 · team-5     │
│ Filter    back-end                               │
│ ☑ Remember sort (Age ↑)                          │
│ Context   (•) us-east-a only   ( ) Any context   │
│                                [Cancel]  [Save]  │
└──────────────────────────────────────────────────┘
```

- The name is pre-filled from the state, e.g. "Deployments · team-1 +3 ·
  back-end".
- The context defaults to **the current context only**. Choosing "Any
  context" is a deliberate step.
- Palette: *Save current table as view*, or `:view save <name>`.

**Updating, renaming, deleting.**

- **Update:** while a view session has changes, the header shows
  `My back-end deployments •` with **Update** and **Revert**. **Save as
  new…** makes a copy.
- **Right-click a view in the sidebar:** Rename, Duplicate, Change context
  (bound ↔ any), Copy as YAML, Delete. Delete shows an undo snackbar instead
  of a confirm dialog, since it doesn't touch the cluster.
- **Reorder:** in the sidebar editor (`ui/sidebar_editor.dart`).

**Where views appear.**

```
┌ Sidebar ─────────────────────┐   ⌘K "back"
│ Overview                     │   ┌───────────────────────────────────────────┐
│ Nodes                        │   │ VIEWS                                     │
│ ★ Deployments          (pin) │   │ ▸ My back-end deployments      any ctx    │
│ VIEWS                        │   │ ▸ Payments ingresses       eu-west-1  ⇄   │
│ ▸ My back-end deploys      ● │   │ KINDS …                                   │
│ ▸ Front-end ingresses        │   └───────────────────────────────────────────┘
│ KINDS …                      │   :view back<Tab>     open
└──────────────────────────────┘   :view save team-x   save the current table
```

- **Sidebar:** a "Views" section below the pins. It lists views that apply to
  any context and views bound to the *current* context. Views bound to other
  contexts are hidden here so the list stays short (they're in the palette).
  The open view is highlighted, as `selectedPin` is.
- **Palette:** a `PaletteGroup.views` source in `palette_sources.dart` lists
  **all** views. A view bound to another context shows that context's name
  and a ⇄ mark: opening it switches cluster.
- **Command mode:** `:view [name]` in `palette_commands.dart`, fuzzy matched
  like `:ctx`.
- **Welcome / startup:** there is no welcome screen today. Three small
  additions:
  1. `ClusterErrorView` and the no-kubeconfig screen list views grouped by
     context. They load without a connection, so a dead last context isn't a
     dead end.
  2. `ConnectingView` offers "Open a view instead" under Cancel.
  3. An optional setting, "At launch: reconnect to the last context | open
     view X". Opening a bound view at launch connects straight to its
     context.

  A full start page is out of scope.

**When a view can't be opened as saved.**

| Situation | Behaviour |
|---|---|
| Bound context missing from every kubeconfig | Don't fall back to the current context. Show "Context `us-east-b` not found" with **Re-point…** (pick a context; matches by API server URL from `ContextInfo.server` come first) and **Make it apply to any context**. |
| Bound kubeconfig file gone | Same, with **Locate file…** (reuses the kubeconfig picker). |
| Context unreachable, or sign-in fails | The usual connecting and error flow (`ConnectingView`, `ClusterErrorView`), with the view's name in the header. |
| Kind not served (CRD missing, common with any-context views) | The table area shows "Ingresses aren't served by `ctx`" (`errNotServed` already exists). |
| Some namespaces deleted (common with any-context views) | Open with the namespaces that exist. Missing ones show struck through in the picker ("team-4 not found"). The view isn't changed unless the user updates it. |
| RBAC forbids some namespaces | `PARTIAL_ERROR` banner. The other namespaces show their rows. |
| RBAC forbids all | The usual Forbidden table error. |
| Namespaces can't be listed (no cluster-wide `list namespaces`) | The view's namespaces are used as they are. The watches decide what is accessible, so this case works without extra handling. |
| Context is read-only | The view opens normally (it only reads). The lock and disabled actions behave as today. |

**Sharing.** *Copy as YAML* and *Import views…* use a small document:

```yaml
apiVersion: k8sman.dev/v1
kind: View
name: My back-end deployments
context: null          # or {name: us-east-a}; the kubeconfig path isn't exported
resource: {group: apps, kind: Deployment}
namespaces: [team-1, team-2, team-3, team-5]
filter: back-end
```

On import, a bound context that doesn't exist locally is re-pointed through
a dialog. Views that apply to any context import as they are, which makes
them the natural way for a team to share views. Views are stored in
`settings.json`, not in repo files. The app has no "project directory", and
context names belong to each person's kubeconfig.

## 5. Effort and risk

| Piece | Size | Risk | Changes |
|---|---|---|---|
| Multi-namespace (1a) | **M** | Low–medium: many call sites use the single `namespace`; merging must stay correct when one namespace re-lists. | `internal/kcache` (fan-in plus a test), `server/stream.go`, `server/server.go` (`parseResource`, `handleTable`, `handleItems`), `API.md`; `state/app_state.dart`, `state/table_controller.dart`, `ui/widgets/namespace_picker.dart`, `ui/resource_table.dart`, `ui/palette/palette_commands.dart`, `state/sidebar_config.dart`, `api/client.dart` |
| Saved views (1b) | **S–M** | Low. The subtle part is the view session vs the kind's prefs. | `internal/settings` (`View`), new `server/views.go`, `API.md`; new `state/saved_views.dart`, `state/app_state.dart` (`openView`, session), `state/table_controller.dart` (seed filter and sort, skip saving prefs during a session), the sidebar section, `palette_sources.dart`, `palette_commands.dart`, the save dialog, `cluster_error_view.dart`, `connecting_view.dart` |
| YAML import/export, launch setting | **S** | Low | The save/manage UI, `internal/settings` |

Both phases can ship separately. 1a is useful without 1b, and 1b without 1a
saves views with zero or one namespace.

## 6. Recommendation

Build **1a then 1b**:

- Merge per-namespace watches in the backend. This is the only approach that
  works for users without cluster-wide access, and `kcache` already reuses a
  warm all-namespaces stream when one exists.
- Views are bound to the current context by default, with "any context" as
  an option. They are stored in `settings.json`, versioned, and shared as
  YAML.
- A view session keeps a view's filter and sort separate from the kind's
  remembered prefs.

Views surface in the sidebar (current and any-context views), the ⌘K palette
and `:view` (all views), and on the error and connecting screens. A full
welcome page waits for demand.

## Future work: multi-cluster views

Showing several contexts in one table would need:

- per-request `context` parameters (today every handler uses the implicit
  `s.mgr.Clients()`);
- a read-only check per request;
- rows keyed by `context|uid`;
- a context carried by the inspector, actions, logs and terminals;
- several exec-plugin logins running at once;
- confirmations that make the target cluster impossible to miss.

The backend's data path is already partly ready: `cluster.Manager` caches a
`*Clients` per (kubeconfig, context) through `ClientsIn`, `kcache` keeps one
cache per context, and port-forwards already run on contexts that aren't
current.

This design leaves room for it. The context is a structured field in the
view (it could become a list), and multi-namespace merging is the same
fan-in that multiple clusters would need. A cheap first step would be a view
listing several contexts, with a strip to switch between them one at a time.

## Open questions for the owner

1. Should a view keep its filter and sort separate from the kind's remembered
   prefs (the view session above), or simply write through to them?
2. Should Overview, Security, Alerts and Metrics also accept a namespace set,
   or stay single-namespace for now?
3. Should new views default to the current context only, or to any context?
4. Should the sidebar hide views bound to other contexts (as proposed) or
   show them all?
5. Is listing views on the error and connecting screens, plus an optional
   "open view X at launch", enough of a welcome screen?
6. Should views store a column set, or is the global per-resource column
   override enough?
7. Is matching contexts by API server URL acceptable when re-pointing or
   importing a view?
