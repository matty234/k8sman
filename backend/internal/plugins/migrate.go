package plugins

import (
	"context"
	"io/fs"
	"log"
	"slices"

	"github.com/matty234/k8sman/backend/internal/settings"
)

// Moving the formerly bundled plugins (external-secrets, cert-manager and
// kyverno, in Options.Legacy) to the plugin directory: docs/PLUGINS.md,
// "Bundled plugins moved to the directory". Once per install and per id,
// recorded in settings.json's plugins.migrated, so it never runs again:
//
//   - Turned off by the user (plugins.disabled): nothing (MigratedOff).
//   - Already installed from the directory: done (MigratedInstalled).
//   - In use: settings show it was used (consent recorded for it, or table
//     preferences saved for one of its kinds), or the current cluster
//     serves one of its kinds. Then it is installed from the directory
//     with the consent the bundled copy implied, but only when the
//     directory version asks for exactly the bundled permissions (the same
//     permissions hash). Otherwise MigratedConsent: it shows as an update
//     that needs the user's OK, and the legacy copy keeps loading.
//   - Not in use (the cluster is known and serves none of its kinds, and
//     settings show nothing): nothing (MigratedUnused); Marketplace
//     suggests it on clusters that serve its kinds.
//
// While undecided (no cluster known yet, or the directory unreachable or
// not configured), the legacy copy loads and the move is tried again on
// the next notice check (start, connecting, daily) or the hourly tick.
//
// TODO(0.2.18): remove this file, with the legacy package.

// legacyWanted reports whether the legacy copy of plugin id loads: its
// move isn't done and it isn't installed from the directory.
func legacyWanted(st settings.PluginSettings, id string) bool {
	if _, ok := st.Installed[id]; ok {
		return false
	}
	m := st.Migrated[id]
	return m == "" || m == settings.MigratedConsent
}

// legacyLoaded is the version of the legacy copy of plugin id that is
// loaded ("" for none).
func (h *Host) legacyLoaded(id string) string {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, p := range h.plugins {
		if p.legacy && p.m != nil && p.m.ID == id {
			return p.m.Version
		}
	}
	return ""
}

// inUse reports whether a formerly bundled plugin was in use, and whether
// that is known: settings evidence decides yes; otherwise the current
// cluster's kinds (served; nil = unknown) decide.
func inUse(s settings.Settings, m *Manifest, served func(string) bool) (used, known bool) {
	ps := settings.PluginSettings{}
	if s.Plugins != nil {
		ps = *s.Plugins
	}
	if ps.Consent[m.ID] != "" {
		return true, true
	}
	for _, k := range m.KindOrder {
		if _, ok := s.Tables[k]; ok && k != "*" {
			return true, true
		}
	}
	if served == nil {
		return false, false
	}
	for _, k := range m.KindOrder {
		if k != "*" && served(k) {
			return true, true
		}
	}
	return false, true
}

// Migrate moves the formerly bundled plugins that aren't decided yet to
// the directory (see above). served is the current cluster's kind lookup
// (nil = unknown). Safe to call often: decided ids are skipped, and a call
// while another runs returns at once.
func (d *Directory) Migrate(ctx context.Context, served func(string) bool) {
	legacy := d.host.opts.Legacy
	if legacy == nil || d.host.opts.Settings == nil || !d.migrateMu.TryLock() {
		return
	}
	defer d.migrateMu.Unlock()
	entries, err := fs.ReadDir(legacy, ".")
	if err != nil {
		return
	}
	dropped := false
	record := func(id, outcome string) {
		err := d.host.opts.Settings.UpdatePlugins(func(p *settings.PluginSettings) {
			if p.Migrated == nil {
				p.Migrated = map[string]string{}
			}
			p.Migrated[id] = outcome
		})
		if err != nil {
			log.Printf("plugins: moving %s to the directory: %v", id, err)
			return
		}
		log.Printf("plugins: moving %s to the directory: %s", id, outcome)
		dropped = dropped || outcome != settings.MigratedConsent
	}
	for _, e := range entries {
		id := e.Name()
		st := d.settings()
		if !e.IsDir() || !legacyWanted(st, id) {
			if _, ok := st.Installed[id]; ok && e.IsDir() && st.Migrated[id] != settings.MigratedInstalled {
				record(id, settings.MigratedInstalled)
			}
			continue
		}
		if slices.Contains(st.Disabled, id) {
			record(id, settings.MigratedOff)
			continue
		}
		sub, err := fs.Sub(legacy, id)
		if err != nil {
			continue
		}
		p := loadPluginFS(sub, "legacy/"+id, SourceBundled, false)
		if p.m == nil {
			continue
		}
		if st.Migrated[id] != settings.MigratedConsent {
			used, known := inUse(d.host.opts.Settings.Get(), p.m, served)
			if !known {
				continue // ask again once a cluster is known
			}
			if !used {
				record(id, settings.MigratedUnused)
				continue
			}
		}
		idx, _, _ := d.index(ctx, NoticeFresh)
		if idx == nil {
			return // offline or not configured: next time
		}
		entry, _, _ := best(idx, id)
		if entry == nil {
			continue // not in the directory (yet), or needs a newer app
		}
		hash := p.PermissionsHash()
		if permissionsHash(id, entry.Permissions) != hash {
			if st.Migrated[id] != settings.MigratedConsent {
				record(id, settings.MigratedConsent)
			}
			continue
		}
		// The bundled copy ran without a prompt: the same permissions
		// count as agreed to. Install refuses a package whose hash differs.
		pend, err := d.Install(ctx, id, hash)
		if err != nil {
			log.Printf("plugins: moving %s to the directory: %v", id, err)
			continue
		}
		if pend.Installed {
			record(id, settings.MigratedInstalled)
		}
	}
	if dropped {
		d.host.Reload()
	}
}
