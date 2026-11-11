// Package legacy holds the plugins that were bundled with the app up to
// 0.2.16 and now ship through the plugin directory (k8sman-plugins):
// external-secrets, cert-manager and kyverno. They are the fallback for
// one release: the host loads one only while its migration
// (plugins.Migrate, docs/PLUGINS.md "Bundled plugins moved to the
// directory") hasn't finished for a user who had it on, shown as
// "Built in · moving to Marketplace". Their fixtures and the maintained
// copies are in the directory repo.
//
// TODO(0.2.18): delete this package, Options.Legacy and the migration
// (plugins/migrate.go); 0.2.17 is the only release that carries them.
package legacy

import "embed"

// FS has one folder per legacy plugin, named by its id.
//
//go:embed */plugin.yaml */README.md
var FS embed.FS
