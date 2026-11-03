# k8sman

A native-feeling Kubernetes desktop app for macOS. Browse any resource type in
live tables, inspect objects in a detail sidebar with kind-specific panels, edit
YAML, run common actions, tail logs and keep port-forwards running. It is built
for day-to-day development work against your clusters.

k8sman is a Flutter macOS app with an embedded Go backend (client-go) that it
starts and supervises itself. You don't need to run a separate server.

<!-- Screenshots: add images under docs/ and reference them here. -->
_Screenshots coming soon._

## Features

- **Every resource type**: built-ins and CRDs are discovered automatically and
  grouped in the sidebar. Tables update live over watches.
- **Custom columns**: per-type columns are written as [jq](https://jqlang.org)
  expressions. You can edit and preview them in the app.
- **Detail sidebar**: kind-specific panels (pods, workloads, services, config,
  storage, RBAC, CRDs and more) plus events, YAML and related objects.
- **Edits and actions**: edit YAML with conflict detection and dry-run, scale,
  restart, roll back, pause or resume, suspend or trigger jobs, cordon nodes,
  and delete. Every destructive action asks for confirmation.
- **Logs**: follow container logs, including the previous container.
- **Port-forwards**: forwards to pods, services and workloads reconnect to a
  fresh pod when theirs goes away. They persist across launches, with optional
  auto-start.
- **Cluster health overview**: a summary of crash loops, image pull failures,
  stuck pods, failing jobs, node pressure and more.
- **Kubeconfig and context switching**: choose a kubeconfig file from
  `$KUBECONFIG`, `~/.kube` or anywhere on disk (**Choose file…**). k8sman
  remembers the file and the last context you used in each one.

## Install

1. Download `k8sman-<version>-macos.zip` from
   [Releases](https://github.com/matty234/k8sman/releases/latest) and unzip
   it. Or build it with `make release`.
2. Move `k8sman.app` to `/Applications`.
3. **First launch (Gatekeeper):** release builds are ad-hoc signed, not
   notarized, so macOS blocks the first launch. Control-click the app, choose
   **Open**, and confirm. On recent macOS versions you may instead need to open
   **System Settings → Privacy & Security** and click **Open Anyway**. For a
   local build, you can also clear the quarantine flag with
   `xattr -dr com.apple.quarantine /Applications/k8sman.app`.

You can check a download against the release's `SHA256SUMS` with
`shasum -a 256 -c SHA256SUMS`.

## Updates

k8sman updates itself with [Sparkle](https://sparkle-project.org).

- It checks for a new release once a day. You can turn this off in
  **k8sman → About k8sman**.
- When there's an update, a small banner offers **Install & Relaunch…**. You
  can also use **k8sman → Check for Updates…** at any time.
- Updates are EdDSA-signed and verified before installing. Installed updates
  open without another Gatekeeper prompt.
- Port-forwards that were running are restarted after the relaunch.
- Development builds (`flutter run`) never update.

See [docs/UPDATES.md](docs/UPDATES.md) for how updates and releases work.

The window opens at about 1440×900, centred. Its size and position are
remembered between launches.

## Development

Requirements: macOS, Flutter (stable), Go 1.24+, and for the dev cluster
[kind](https://kind.sigs.k8s.io) and kubectl.

```sh
make cluster    # create the k8sman-dev kind cluster (writes .kubeconfig-dev) and load samples
make app        # flutter run -d macos; builds and embeds the backend automatically
```

The Xcode project has a **Build k8sman-server** run-script phase
(`tools/build-backend.sh`). It compiles the Go backend for the target
architectures and copies it into `k8sman.app/Contents/MacOS/k8sman-server`, so
`flutter run -d macos` and `flutter build macos` both produce a self-contained
app. The script finds `go` in your PATH, `/opt/homebrew/bin` or
`/usr/local/go/bin`, and builds with `GOTOOLCHAIN=local`.

To work on the backend with a hot-restartable server instead:

```sh
make backend    # standalone server on 127.0.0.1:7443 against the dev cluster
make app-dev    # app using that server (--dart-define=K8SMAN_BACKEND=http://127.0.0.1:7443)
```

The embedded backend is started with `--addr 127.0.0.1:0` and the app learns
the port from its `K8SMAN_LISTENING <addr>` stdout line. To pass extra flags
to it, run for example
`defaults write dev.k8sman.app BackendArgs -array --read-only`.

Tests and checks:

```sh
make test       # go vet + go test, flutter analyze, flutter test
make icon       # regenerate the app icon PNGs (tools/app_icon)
```

## Release build

```sh
make release    # dist/k8sman-<version>-macos.zip + SHA256SUMS
make appcast    # dist/appcast.xml: EdDSA-signed update feed (needs the signing key)
make update-e2e # local update test: two versions, local feed, tamper checks
```

`make release` builds a universal (arm64 + x86_64) Release `.app` with the
embedded backend and Sparkle, verifies its ad-hoc signature, and zips it. The
version comes from `frontend/pubspec.yaml`.

Pushing a `v*` tag runs `.github/workflows/release.yml`, which builds, signs
and publishes the GitHub release. See [docs/UPDATES.md](docs/UPDATES.md)
for the signing keys, release steps and the notarization path.

## Architecture

```
frontend/  Flutter macOS app
  lib/app/          backend launcher (BackendController), kubeconfig picker, window chrome, updates/
  lib/api/          Dart client for the backend API
  lib/state/        app state (context, types, namespace, selection)
  lib/ui/, panels/  shell, tables, detail sidebar, kind-specific panels
  macos/Runner/     native window (vibrancy, titlebar), BackendSupervisor.swift, UpdateController.swift (Sparkle)
backend/   Go server (client-go)
  cmd/k8sman-server/   entry point and flags
  internal/cluster/    kubeconfig loading, context and kubeconfig switching, discovery
  internal/server/     HTTP and WebSocket API
  internal/portforward supervised port-forwards
  internal/settings/   ~/.config/k8sman/settings.json
  internal/icons/      CRD group icons: Helm chart icons, bundled icons, favicons
tools/     build-backend.sh, app icon generator, release/update tooling
packaging/ Homebrew cask template
```

- **API**: see [API.md](API.md) for every endpoint.
- **Panels**: see [docs/PANELS.md](docs/PANELS.md) for how kind-specific
  detail panels are built and registered.
- **Backend supervision** (`frontend/macos/Runner/BackendSupervisor.swift`):
  - The app spawns the backend with your login-shell environment (`$SHELL -l`),
    so kubeconfig exec credential plugins such as `aws`,
    `gke-gcloud-auth-plugin` and `kubelogin` are found.
  - It restarts the backend with exponential backoff if it crashes, and
    shows the backend's output with a Retry button if it can't start.
  - On quit it sends SIGTERM, and the backend stops its port-forwards. The
    backend also exits if its stdin closes, so it never outlives the app.
- **Local state** lives in `~/.config/k8sman/`:
  - `settings.json`: the chosen kubeconfig, recent kubeconfigs, the last
    context per kubeconfig, and `remoteIcons` (see below).
  - `columns.json`: custom columns.
  - `portforwards.json`: saved forwards.

## Security

- **Local only.** The backend listens on `127.0.0.1` (a random port in the
  app), never on external interfaces. Browser CORS is limited to localhost
  origins.
- **No App Sandbox.** The app runs unsandboxed (see
  `frontend/macos/Runner/*.entitlements`). The backend needs to read
  `~/.kube` and cloud credentials and run exec auth plugins, which the sandbox
  forbids. It uses your kubeconfig credentials exactly as kubectl would.
- **Read-only mode.** Run the backend with `--read-only` to refuse edits,
  actions and new port-forwards (HTTP 403). The UI hides those controls. For
  the app, run `defaults write dev.k8sman.app BackendArgs -array --read-only`.
- **CRD icons.** Icons for custom resource groups come from Helm chart
  metadata, icons bundled with the app, or the group's website favicon
  (fetched directly, never through a third-party favicon service). Internet
  fetches are on by default only for local clusters (kind, k3d, minikube,
  Docker Desktop, …). Set `"remoteIcons": false` (or `true`) in
  `settings.json`, or pass `--no-remote-icons`, to override. See
  [API.md](API.md#crd-group-icons).
- **Confirmations.** Mutating actions ask for confirmation, and the dialog
  names the target kube context (see `frontend/lib/actions/actions.dart`).
  YAML edits support server-side dry-run.
- k8sman never sends kubeconfig contents to the UI. The kubeconfig listing
  returns only file paths and context names.
