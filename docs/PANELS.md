# Writing detail panels

Clicking a table row opens the detail sidebar. It has these tabs:

- **Overview**: the shared `MetadataSection`, then your panel's `buildSections()`
- your panel's extra `tabs()`, if any (e.g. Logs)
- **YAML** and **Events**, which are shared and need no panel code

## Contract (`frontend/lib/panels/panel.dart`)

```dart
class MyPanel extends ResourcePanel {
  const MyPanel();
  @override
  Set<String> get kinds => {'apps/Deployment'};  // '<group>/<Kind>', core group = '' → '/Pod'
  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) => [
    DetailSection(title: 'Replicas', icon: Icons.layers, child: ...),
  ];
  @override
  List<PanelTab> tabs(PanelContext ctx) => const [];
}
```

`PanelContext` gives you `object` (the live JSON), `type`, `api` (an
`ApiClient`), `app` (`AppState`), and the shortcuts `name`, `namespace`,
`uid`, `spec`, `status` and `metadata`.

**Register** a panel by adding it to the list in your area's
`lib/panels/<area>/index.dart`. The registry already includes every area list,
so you never touch `registry.dart`.

## Rules

- **Live re-renders.** The object is watched, so `buildSections` runs again on
  every change. Anything that fetches (related pods, endpoints, events) must be a
  `StatefulWidget` that creates its future **once**, in `initState`. Key it by
  `ValueKey(ctx.uid)`, and refetch only when something meaningful changes,
  in `didUpdateWidget`. Never create futures inline in `buildSections`.
- **Fields may be missing.** Use `dig<T>(obj, [...])`, `asMap` and `asMapList`
  from `lib/util/k8s.dart`. Never index blindly. One panel exception is caught
  and shown inline, but don't rely on that.
- **Mutations go through `lib/actions/actions.dart`.** Never call `api.runAction` or `api.updateObject` directly from a panel.
  - The sidebar header already shows the standard actions for each kind
    (`standardActions()`): Scale, Restart, Pause/Resume, Roll back, Run now,
    Suspend, Cordon and Delete. Don't duplicate those as header buttons.
  - To put actions *in context* inside a section, use the drop-in widgets:
    - `ScaleControl(ctx)`: a − N + stepper, e.g. next to the replica bar
    - `ActionButton(ctx, action: 'rollback', body: {'revision': 3}, label: 'Roll back', icon: Icons.history, title: 'Roll back web to revision 3?', destructive: true)`
  - For anything custom, use `runResourceAction(context, ctx, action, title:, message:, destructive:, body:)`.
  All of these confirm the action, show the kube context, require typing the
  name for destructive actions on non-local clusters, and report the result.
  - Override `actions(ctx)` on your panel only for kind-specific extras that
    aren't in `standardActions`.
  - Hide mutating UI when `ctx.app.readOnly` is true.
  - The available actions are listed in `API.md`. Don't add backend endpoints.
- **Secrets:** pass `label:` to `copyToClipboard` so the snackbar doesn't echo the value.
- **Reuse shared widgets** from `lib/ui/widgets/common.dart`: `DetailSection`,
  `KeyValueTable`, `StatusBadge`, `LabelChips`, `Chipish`, `ConditionsTable`,
  `AgeText`, `CodeBlock`, `ResourceLink`, `JsonTree`, `InlineMessage`,
  `AsyncSection`. `EventList` lives in `lib/ui/detail/detail_sidebar.dart`.
  For helpers, `lib/util/k8s.dart` has quantities, ages, selectors,
  `ownerRefs` and `severityOf`.
- **Cross-links.** Use `ResourceLink(ObjectRef(group:, kind:, name:, namespace:))`
  for anything navigable: nodes, owners, services, PVCs, ConfigMaps, Secrets,
  ServiceAccounts and so on. It pushes onto the sidebar's back-stack.
- **Related objects.** Fetch them with
  `ctx.api.items(ResourceRef(group: 'apps', resource: 'replicasets'), namespace: ns, labelSelector: selectorToString(sel))`.
- **Shared code.** If you need a helper or widget that isn't shared yet, put it
  inside your own area folder. Don't edit shared files (`lib/ui/**`, `lib/util/**`,
  `lib/api/**`, `lib/state/**`, `lib/panels/panel.dart`, `lib/panels/registry.dart`).
  If a shared change is truly needed, describe it in your final report.

## Testing

`test/support/harness.dart` provides:

- `pumpPanel(tester, object, api: FakeApiClient(...))`, which renders your
  sections exactly as the Overview tab does. It returns the `AppState`, so you
  can assert `app.detail` after tapping a `ResourceLink`.
- `pumpPanelTab(tester, object, 'Logs', api: ...)`, which renders an extra tab.
- `FakeApiClient(itemsByResource: {'pods': [...]}, eventItems: [...], logLines: {...})`.

Real objects captured from the dev cluster live in `dev/fixtures/*.json`.
Load them with `jsonDecode(File('../dev/fixtures/pod-web.json').readAsStringSync())`.

**Visual check:** call `await loadRealFonts()` before pumping, then
`await saveScreenshot(tester, 'pod-web')` (from `test/support/screenshot.dart`).
This writes `frontend/build/screenshots/pod-web.png`, which you can view.
Look at it: overflow errors, clipped text and awkward layouts show up here.
The sidebar is about 560px wide in the real app, so render with
`size: Size(560, 2400)`.

Run your tests with `flutter test test/panels/<area>/` and analyze with
`flutter analyze`. Both must be clean.
