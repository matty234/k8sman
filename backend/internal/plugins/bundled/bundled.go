// Package bundled holds the plugins compiled into the backend: one folder
// per plugin (plugin.yaml, README.md and fixtures), the same format as any
// plugin (docs/PLUGINS.md, "Bundled plugins"). They load without developer
// mode, need no consent, and each has its own switch in Settings ▸
// Integrations. Only plugin.yaml and README.md are embedded; the fixtures
// run in go test (internal/plugins TestPluginTestGolden) and with
// `k8sman-server plugin test internal/plugins/bundled/<id>`.
package bundled

import "embed"

// FS has one folder per bundled plugin, named by its id.
//
//go:embed */plugin.yaml */README.md
var FS embed.FS

// ReplacesModule maps a bundled plugin id to the compiled-in module it
// replaces, while that module is still in the app (off), so the two can
// be compared: settings.json's plugins.useModule (a list of plugin ids)
// turns the module back on and the plugin off. Never both at once. Empty
// now: external-secrets replaced the external_secrets module, which has
// since been removed.
var ReplacesModule = map[string]string{}
