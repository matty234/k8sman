# Plugins

Status: **Milestone 1 implemented** (dev mode only). Sections 1–12 are the
design; [§13 As built](#13-as-built-milestone-1) says where Milestone 1
differs from it, and [Writing a plugin](#writing-a-plugin) is how to use it.

Deep integrations (Argo CD, Helm, Gateway API, …) are compile-time modules
(see [DEVELOPMENT.md](DEVELOPMENT.md#adding-an-integration)). Plugins cover
the long tail of CRDs (cert-manager, Karpenter, Crossplane, …): a folder
with a `plugin.yaml`, in YAML and [CEL](https://cel.dev), loaded at runtime.

## Writing a plugin

In Milestone 1 plugins load only in **developer mode**, from folders on your
computer, and reload as you save.

1. Turn it on: **Settings ▸ Integrations ▸ Plugins ▸ Developer mode** (or
   the palette's **Integrations…**). Or start the backend with
   `--plugin-dev <folder>` (repeatable), e.g.
   `make backend BACKEND_ARGS="--plugin-dev examples/plugins/cert-manager"`
   with `make app-dev`, or for the packaged macOS app
   `defaults write dev.k8sman.app BackendArgs -array --plugin-dev /path/to/plugin`.
2. **Load plugin folder…** and pick a folder with a `plugin.yaml` (or a
   folder of such folders). Start from
   [`examples/plugins/cert-manager`](../examples/plugins/cert-manager): it
   has columns, every common panel block, a sidebar section with kind icons,
   and two `cmctl` shell actions.
3. Open a table of one of its kinds: the plugin's columns are there (hover a
   header for its description). Open an object: its sections are on the
   Overview tab, its actions in the inspector header.
4. Edit `plugin.yaml` and save. Tables and open panels update within a
   moment. A mistake shows inline in Settings ▸ Integrations ▸ Plugins as
   `plugin.yaml:42:21: undeclared reference to 'objet'` with the line and a
   caret, and the previous version keeps running until the file loads again.
   A failing expression shows its error (with its line) in its cell, field or
   block; the rest still renders.
5. Check it without the app, e.g. in CI:
   `k8sman-server plugin validate ./my-plugin` (exit 1 on errors).

The Plugins settings also list, per plugin, its kinds (active where the
cluster serves them), its permissions, consent (Allow… / Revoke), and load,
compile and evaluation timings (p50/p95/max per contribution type).

Shell actions run on your computer in a dock tab: the first run asks you to
allow the plugin's permissions, and every run shows the full command and asks
first. They are hidden on read-only contexts.

What Milestone 1 reads: `apiVersion`, `id`, `name`, `version`,
`description`, `authors`, `homepage`, `minAppVersion`, `permissions.read` and
`.commands`, `nav`, and per kind `version`, `icon`, `variables`, `columns`,
`hideColumns`, `panel` and shell `actions`. `related`, `metrics`, `alerts`
and patch actions are accepted with a warning and ignored until Milestone 2.
Differences from the design below (notably `ns` instead of `namespace`) are
in [§13](#13-as-built-milestone-1).

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
- Replacing compiled-in modules. Argo CD, Helm, Hubble and the like stay
  modules.
- Reading Secret values.

## 2. Concepts and layout

A plugin contributes to **kinds**. For each kind it can add:

| Contribution | Where it shows | Evaluated |
|---|---|---|
| Columns | the kind's table | per row, in the table builder |
| Panel sections | the inspector's Overview tab | per object change, streamed |
| Actions | inspector header, row menu, palette | on click |
| Alerts | Overview page and Alerts tiles | per object, on each overview poll |

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
`cert-manager.io/Certificate`. The key `"*"` (any kind) may hold only
`actions`. YAML anchors work, so two kinds can share a definition.

### Kind

| Field | Type | Notes |
|---|---|---|
| `version` | string | optional; pin the API version read (default: the preferred version) |
| `variables` | map of name → **CEL** | named values, `variables.<name>`; evaluated lazily, at most once per evaluation |
| `related` | map of name → Related | §6 |
| `metrics` | map of name → Metric | §6 |
| `columns` | list of Column | |
| `hideColumns` | list of string | default columns to drop (by name) |
| `panel` | `{sections: [Section]}` | §4 |
| `actions` | list of Action | |
| `alerts` | list of Alert | |

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
(**CEL** bool), `collapsed` (bool), `blocks` (list). Each section is a
`DetailSection`. Every block also takes `when`.

| Block | Widget | Fields |
|---|---|---|
| `fields` | `KeyValueTable` | `items`: list of `{label, value` **CEL**`, type, link` **CEL** `Ref, copy: bool, when}`. A row whose value is null or empty is hidden |
| `badges` | `StatusBadge` row | `items`: list of `{text` **CEL**`, severity` **CEL** optional`, when}`; without severity the badge colours itself from the text as today |
| `chips` | `Chipish` / `LabelChips` | `items` **CEL**: a list of strings, or a map (shown as `key=value`) |
| `conditions` | `ConditionsTable` | `from` **CEL**, default `object.status.conditions` |
| `links` | `ResourceLink` list | `items` **CEL**: a list of Refs; `empty` (text) |
| `table` | compact table | `rows` **CEL** list; `columns`: list of `{name, value` **CEL** (sees `row`)`, type, link}`; `sortBy` (column name), `descending`, `limit` (default 20, "Show all" beyond), `empty` (text) |
| `bar` | `UsageBar` | `label`, `value` **CEL** number, `max` **CEL** number, `format`: `number`, `quantity` or `percent`; amber from 80%, red from 90% |
| `code` | `CodeBlock` | `value` **CEL** string, `language`: `text`, `yaml`, `json` or `shell` |
| `json` | `JsonTree` | `value` **CEL**, any value |
| `message` | `InlineMessage` | `text` **CEL** string, `severity`: `info`, `warning` or `error` |

Value `type` in `fields` and `table` columns: `text` (default), `number`,
`bool`, `status`, `age`, `until`, `timestamp`, `quantity`, `labels`, `url`
(opens the browser on click), `code` (monospace, with copy).

`icon` is one of a fixed list of ~40 Material icon names (in the schema as an
enum: `verified`, `key`, `dns`, `history`, `memory`, `tune`, `refresh`,
`lock`, `storage`, `cloud`, `link`, `warning`, …). Flutter tree-shakes its
icon font, so arbitrary names can't be looked up at runtime.

**Placement.** Plugin sections come after the shared Metadata section. For a
kind with a compiled-in panel they follow its sections. For a kind that only
has the generic custom-resource panel, they replace its summary; the generic
spec and status trees stay, collapsed, at the end. Two plugins for one kind
appear in plugin id order. Panels get the shared YAML and Events tabs as
before; plugins can't add tabs in v1.

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
| `namespace` | **CEL** string | default `namespace`; ignored for cluster-scoped kinds |
| `when` | **CEL** bool | skip the lookup |

Exactly one of `name`, `owner` and `selector`. All three are served from
`kcache`: `name` reads the namespace's stream, `selector` uses a
label-selector key (which rides a warm broader stream when there is one),
and `owner` filters the namespace's stream by uid (`limit` 200 objects).
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
turns every plugin off.

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

## 13. As built (Milestone 1)

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
  `related` fails to compile (undeclared reference).
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
  cheaper than jq doing the same. The cert-manager example loads in about
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
  object); not in the palette yet. `shortcut` is read but not bound yet.
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

**Navigation (question 7).** New top-level `nav: {title, after?, kinds?}`
(a sidebar section; `kinds` defaults to the plugin's kinds in file order)
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
