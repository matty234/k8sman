# External Secrets (bundled plugin)

[External Secrets Operator](https://external-secrets.io) in k8sman, written
as a plugin and compiled into the backend. It is on by default and turned
off in **Settings ▸ Integrations ▸ External Secrets**, like a module. It
replaced the built-in `external_secrets` module, which has been removed:
see [docs/PLUGINS.md](../../../../../docs/PLUGINS.md#bundled-plugins).

What it adds, for `external-secrets.io` kinds the cluster serves:

- An **External Secrets** sidebar section, with icons.
- Columns: ExternalSecret Store, Refresh, Status, Last Sync and Target;
  ClusterExternalSecret External Secret, Namespaces, Failed, Refresh and
  Status; SecretStore and ClusterSecretStore Provider, Status and
  Capabilities; PushSecret Stores, Status and Last Sync. The CRD printer
  columns they repeat are hidden.
- Panels that replace the generic one (`panel.generic: replace`):
  - ExternalSecret: sync status (the Ready reason; a callout titled with
    it when not ready), the store (with its status), the
    ClusterExternalSecret that made it, the target Secret (a warning while
    it doesn't exist; its keys, never its values), the data mapping
    (`data` and `dataFrom`) and the template.
  - ClusterExternalSecret: status, store, namespace selection, provisioned
    and failed namespaces.
  - SecretStore and ClusterSecretStore: status, provider and its settings
    as `path → value` rows (Secret and ServiceAccount references are links
    with their name and key), conditions, and the ExternalSecrets that use
    the store.
  - PushSecret keeps the generic panel.
- Alerts, on the Overview (under Plugins) and in the dock's Issues tab:
  **ExternalSecrets not synced** (warning) and **not synced for over a day**
  (critical), from the Ready condition and its last transition.
- A status line on its Integrations row: "ExternalSecrets: 12 · not
  synced: 2", amber when any isn't synced.
- **Refresh now** on ExternalSecrets and PushSecrets: a merge patch that sets
  the `force-sync` annotation, with a dry run and a confirmation, never on
  read-only contexts.

Work on it like any plugin: load this folder in developer mode (it overrides
the bundled copy while loaded), and run its fixtures with
`k8sman-server plugin test backend/internal/plugins/bundled/external-secrets`
(`go test ./internal/plugins` runs them too).
