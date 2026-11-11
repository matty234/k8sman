package server

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/columns"
	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/kcache"
	"github.com/matty234/k8sman/backend/internal/plugins"
	"github.com/matty234/k8sman/backend/internal/settings"
)

// The plugin host is a module ("plugins"): turning it off in Integrations
// turns the user's own plugins off. Its routes stay mounted either way
// (see moduleOff): bundled plugins have their own switches, like modules.
// Plugins themselves are not modules: they are folders with a plugin.yaml
// loaded by internal/plugins (docs/PLUGINS.md).
//
//	GET    /api/plugins                 dev mode, folders and every plugin with its errors and timings
//	PUT    /api/plugins/settings        {devMode?, devFolders?, useModule?, autoUpdate?}
//	PUT    /api/plugins/{id}/enabled    {enabled}
//	PUT    /api/plugins/{id}/consent    {permissionsHash}: agree to the plugin's permissions
//	DELETE /api/plugins/{id}/consent
//	POST   /api/plugins/reload          reload every folder
//	GET    /api/plugins/{id}/icon       the plugin's icon.png
//	GET    /api/plugins/panel           ?group&version&resource&namespace&name: sections and actions for an object
//	GET    /api/plugins/status          {plugins: {id: {text, severity, kinds, errors}}}: status lines (plugins_data.go)
//	GET    /api/plugins/templates       ?kind=group/Kind: the active plugins' templates for the create editor (every kind without kind)
//	GET    /api/plugins/events          WebSocket: {"generation": n} on every change
//	POST   /api/plugins/run             ?plugin&action&group&version&resource&namespace&name: a background shell action
//	GET    /api/plugins/directory       ?refresh: the plugin directory (Browse), with the updates available
//	GET    /api/plugins/directory/updates     the app's notices: updates, plugins suggested for the current context, and whether any is unseen
//	POST   /api/plugins/directory/seen        {context, suggestions, updates}: the notices were reviewed or dismissed
//	POST   /api/plugins/directory/install     {id, permissionsHash?}: {consent} to ask, or (consented) installed: as GET /api/plugins
//	POST   /api/plugins/directory/uninstall   {id}
//
// Installing plugins changes this computer's state, not the cluster's, so
// --read-only doesn't apply (as for the other plugin settings).
//
// Shell actions run through GET /api/local-shell?plugin=&action=&… (see
// localshell.go), or POST /api/plugins/run in the background: the backend
// builds the command, the UI can't send one. Patch actions run through
// POST /api/actions/plugin.<id>.<action> (plugins_data.go).
type pluginsModule struct {
	s *Server
}

const pluginsModuleID = plugins.HostModule

func (m *pluginsModule) Name() string { return pluginsModuleID }

func (m *pluginsModule) Routes(r httpx.Router, d Deps) {
	s := m.s
	r.HandleFunc("GET /api/plugins", s.handlePlugins)
	r.HandleFunc("PUT /api/plugins/settings", s.handlePluginSettings)
	r.HandleFunc("PUT /api/plugins/{id}/enabled", s.handlePluginEnabled)
	r.HandleFunc("PUT /api/plugins/{id}/consent", s.handlePluginConsent)
	r.HandleFunc("DELETE /api/plugins/{id}/consent", s.handlePluginConsent)
	r.HandleFunc("POST /api/plugins/reload", s.handlePluginsReload)
	r.HandleFunc("GET /api/plugins/{id}/icon", s.handlePluginIcon)
	r.HandleFunc("GET /api/plugins/panel", s.handlePluginPanel)
	r.HandleFunc("GET /api/plugins/status", s.handlePluginStatus)
	r.HandleFunc("GET /api/plugins/templates", s.handlePluginTemplates)
	r.HandleFunc("GET /api/plugins/events", s.handlePluginEvents)
	r.HandleFunc("POST /api/plugins/run", s.handlePluginRun)
	r.HandleFunc("GET /api/plugins/directory", s.handlePluginDirectory)
	r.HandleFunc("GET /api/plugins/directory/updates", s.handlePluginDirectory)
	r.HandleFunc("POST /api/plugins/directory/seen", s.handlePluginNoticesSeen)
	r.HandleFunc("POST /api/plugins/directory/install", s.handlePluginInstall)
	r.HandleFunc("POST /api/plugins/directory/uninstall", s.handlePluginUninstall)
}

func (s *Server) pluginDirectory() *plugins.Directory {
	s.dirOnce.Do(func() {
		if s.directory == nil {
			s.directory = plugins.DirectoryFromEnv(s.plugins)
		}
	})
	return s.directory
}

func (s *Server) handlePluginDirectory(w http.ResponseWriter, r *http.Request) {
	if s.plugins == nil {
		writeErr(w, httpx.BadRequest("plugins are off"))
		return
	}
	served, kubeContext := s.servedKinds(r.Context()), ""
	if c := s.mgr.Clients(); c != nil {
		kubeContext = c.Context
	}
	if strings.HasSuffix(r.URL.Path, "/updates") {
		// The app's notices (on start, daily and after a context switch):
		// the cached index, unless it's a day old. First, the move of the
		// formerly bundled plugins, now that the cluster's kinds are known.
		// TODO(0.2.19): remove with plugins/migrate.go.
		s.pluginDirectory().Migrate(r.Context(), served)
		st := s.pluginDirectory().State(r.Context(), plugins.NoticeFresh, served)
		ps := settings.PluginSettings{}
		if p := s.settings.Get().Plugins; p != nil {
			ps = *p
		}
		unseenSuggestions := slices.ContainsFunc(st.Suggested, func(p plugins.DirectoryPlugin) bool {
			return !slices.Contains(ps.SeenSuggestions[kubeContext], p.ID)
		})
		unseenUpdates := slices.ContainsFunc(st.Updates, func(p plugins.DirectoryPlugin) bool {
			return !slices.Contains(ps.SeenUpdates, p.ID+"@"+p.Version)
		})
		httpx.WriteJSON(w, http.StatusOK, map[string]any{"status": st.Status, "error": st.Error, "context": kubeContext,
			"updates": st.Updates, "suggested": st.Suggested, "unseenSuggestions": unseenSuggestions, "unseenUpdates": unseenUpdates})
		return
	}
	maxAge := plugins.IndexFresh
	if r.URL.Query().Get("refresh") != "" {
		maxAge = 0
	}
	httpx.WriteJSON(w, http.StatusOK, s.pluginDirectory().State(r.Context(), maxAge, served))
}

// handlePluginNoticesSeen records that the app's plugin notices were
// reviewed or dismissed: the suggestions for a context, and updates
// (id@version). A notice shows again only for something not seen.
func (s *Server) handlePluginNoticesSeen(w http.ResponseWriter, r *http.Request) {
	body, ok := httpx.DecodeJSON[struct {
		Context     string   `json:"context"`
		Suggestions []string `json:"suggestions"`
		Updates     []string `json:"updates"`
	}](w, r, 64<<10)
	if !ok {
		return
	}
	err := s.settings.UpdatePlugins(func(p *settings.PluginSettings) {
		if len(body.Suggestions) > 0 && body.Context != "" {
			if p.SeenSuggestions == nil {
				p.SeenSuggestions = map[string][]string{}
			}
			seen := append(slices.Clone(p.SeenSuggestions[body.Context]), body.Suggestions...)
			slices.Sort(seen)
			p.SeenSuggestions[body.Context] = slices.Compact(seen)
		}
		if len(body.Updates) > 0 {
			seen := append(slices.Clone(p.SeenUpdates), body.Updates...)
			slices.Sort(seen)
			p.SeenUpdates = slices.Compact(seen)
		}
	})
	if err != nil {
		writeErr(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handlePluginInstall installs a plugin from the directory: without the
// package's permissions hash (or with another) it answers {consent} for
// the UI to ask; with it, the plugin is installed and the answer is the
// plugin list. An update whose permissions are unchanged installs at once
// when the UI sends the installed version's hash.
func (s *Server) handlePluginInstall(w http.ResponseWriter, r *http.Request) {
	body, ok := httpx.DecodeJSON[struct {
		ID              string `json:"id"`
		PermissionsHash string `json:"permissionsHash"`
	}](w, r, 0)
	if !ok {
		return
	}
	if s.plugins == nil || body.ID == "" {
		writeErr(w, httpx.BadRequest("no plugin to install"))
		return
	}
	pend, err := s.pluginDirectory().Install(r.Context(), body.ID, body.PermissionsHash)
	if err != nil {
		httpx.WriteError(w, http.StatusBadGateway, "", err.Error())
		return
	}
	if !pend.Installed {
		httpx.WriteJSON(w, http.StatusOK, map[string]any{"consent": pend})
		return
	}
	s.handlePlugins(w, r)
}

func (s *Server) handlePluginUninstall(w http.ResponseWriter, r *http.Request) {
	body, ok := httpx.DecodeJSON[struct {
		ID string `json:"id"`
	}](w, r, 0)
	if !ok {
		return
	}
	if s.plugins == nil {
		writeErr(w, httpx.BadRequest("plugins are off"))
		return
	}
	if err := s.pluginDirectory().Uninstall(body.ID); err != nil {
		writeErr(w, httpx.BadRequest("%v", err))
		return
	}
	s.handlePlugins(w, r)
}

// pluginsOn reports whether any plugin's contributions apply: a bundled
// one that is on, or the user's own in dev mode with this module on (the
// host decides, per plugin).
func (s *Server) pluginsOn() bool {
	return s.plugins != nil && s.plugins.Any()
}

// servedKinds is a lookup of the kind keys the current cluster serves,
// from the cached discovery (nil when unknown).
func (s *Server) servedKinds(ctx context.Context) func(string) bool {
	c := s.mgr.Clients()
	if c == nil {
		return nil
	}
	types, err := c.Resources(ctx, false)
	if err != nil {
		return nil
	}
	set := map[string]bool{}
	for _, t := range types {
		set[plugins.KindKey(t)] = true
	}
	return func(k string) bool { return set[k] }
}

func (s *Server) handlePlugins(w http.ResponseWriter, r *http.Request) {
	ps := settings.PluginSettings{}
	if p := s.settings.Get().Plugins; p != nil {
		ps = *p
	}
	folders := ps.DevFolders
	if folders == nil {
		folders = []string{}
	}
	flags, installed := s.plugins.Opts().FlagDirs, s.plugins.Opts().InstalledDir
	if flags == nil {
		flags = []string{}
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"devMode":      s.plugins.DevMode(),
		"devModeSaved": ps.DevMode,
		"autoUpdate":   ps.AutoUpdate,
		"devFolders":   folders,
		"flagFolders":  flags,
		"installedDir": installed,
		"generation":   s.plugins.Generation(),
		"readOnly":     s.isReadOnly(),
		"icons":        plugins.Icons,
		"plugins":      s.plugins.List(s.servedKinds(r.Context())),
	})
}

func (s *Server) handlePluginSettings(w http.ResponseWriter, r *http.Request) {
	body, ok := httpx.DecodeJSON[struct {
		DevMode    *bool     `json:"devMode"`
		DevFolders *[]string `json:"devFolders"`
		// UseModule: bundled plugin ids whose module replaces them (to
		// compare the two; see bundled.ReplacesModule).
		UseModule *[]string `json:"useModule"`
		// AutoUpdate: install same-permission updates from the directory.
		AutoUpdate *bool `json:"autoUpdate"`
	}](w, r, 64<<10)
	if !ok {
		return
	}
	if body.UseModule != nil {
		for _, id := range *body.UseModule {
			if s.plugins.Replaces(id) == "" {
				writeErr(w, httpx.BadRequest("%q isn't a bundled plugin that replaces a module", id))
				return
			}
		}
	}
	if body.DevFolders != nil {
		for _, d := range *body.DevFolders {
			if !filepath.IsAbs(d) {
				writeErr(w, httpx.BadRequest("plugin folders must be absolute paths: %q", d))
				return
			}
			if st, err := os.Stat(d); err != nil || !st.IsDir() {
				writeErr(w, httpx.BadRequest("%s is not a folder", d))
				return
			}
		}
	}
	err := s.settings.UpdatePlugins(func(p *settings.PluginSettings) {
		if body.DevMode != nil {
			p.DevMode = *body.DevMode
		}
		if body.DevFolders != nil {
			p.DevFolders = slices.Compact(slices.Clone(*body.DevFolders))
		}
		if body.UseModule != nil {
			p.UseModule = slices.Compact(slices.Sorted(slices.Values(*body.UseModule)))
		}
		if body.AutoUpdate != nil {
			p.AutoUpdate = *body.AutoUpdate
		}
	})
	if err != nil {
		writeErr(w, err)
		return
	}
	if body.AutoUpdate != nil && *body.AutoUpdate {
		// Turning it on applies the updates waiting now, not tomorrow.
		go s.pluginDirectory().AutoUpdate(context.Background())
	}
	s.plugins.Reload()
	s.handlePlugins(w, r)
}

func (s *Server) handlePluginEnabled(w http.ResponseWriter, r *http.Request) {
	body, ok := httpx.DecodeJSON[struct {
		Enabled bool `json:"enabled"`
	}](w, r, 0)
	if !ok {
		return
	}
	id := r.PathValue("id")
	err := s.settings.UpdatePlugins(func(p *settings.PluginSettings) {
		p.Disabled = slices.DeleteFunc(p.Disabled, func(x string) bool { return x == id })
		if !body.Enabled {
			p.Disabled = append(p.Disabled, id)
		}
	})
	if err != nil {
		writeErr(w, err)
		return
	}
	s.plugins.Bump()
	s.handlePlugins(w, r)
}

// handlePluginConsent records (PUT) or withdraws (DELETE) agreement to a
// plugin's permissions. PUT names the hash the UI showed, so consent
// given to an older version doesn't carry over to new permissions.
func (s *Server) handlePluginConsent(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	hash := ""
	if r.Method == http.MethodPut {
		body, ok := httpx.DecodeJSON[struct {
			PermissionsHash string `json:"permissionsHash"`
		}](w, r, 0)
		if !ok {
			return
		}
		p := s.plugins.Get(id)
		if p == nil {
			writeErr(w, httpx.BadRequest("plugin %q isn't loaded", id))
			return
		}
		if body.PermissionsHash != p.PermissionsHash() {
			writeErr(w, httpx.BadRequest("the plugin's permissions changed; review them again"))
			return
		}
		hash = body.PermissionsHash
	}
	err := s.settings.UpdatePlugins(func(p *settings.PluginSettings) {
		if hash == "" {
			delete(p.Consent, id)
			return
		}
		if p.Consent == nil {
			p.Consent = map[string]string{}
		}
		p.Consent[id] = hash
	})
	if err != nil {
		writeErr(w, err)
		return
	}
	s.plugins.Bump()
	s.handlePlugins(w, r)
}

func (s *Server) handlePluginsReload(w http.ResponseWriter, r *http.Request) {
	s.plugins.Reload()
	s.handlePlugins(w, r)
}

func (s *Server) handlePluginIcon(w http.ResponseWriter, r *http.Request) {
	b, err := s.plugins.Icon(r.PathValue("id"))
	if err != nil {
		httpx.WriteError(w, http.StatusNotFound, "NotFound", "no icon")
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "no-cache")
	_, _ = w.Write(b)
}

// pluginObject reads one object for plugins: from a warm shared watch
// (the inspector's own, or its namespace's), else with a GET.
func (s *Server) pluginObject(ctx context.Context, c *cluster.Clients, rq resourceQuery, name string) (*unstructured.Unstructured, error) {
	kc := kcache.For(c)
	ns := namespaceFor(rq)
	for _, key := range []kcache.Key{
		{GVR: rq.Type.GVR(), Namespace: ns, FieldSelector: "metadata.name=" + name},
		{GVR: rq.Type.GVR(), Namespace: ns},
	} {
		if snap, ok := kc.Cached(key); ok {
			for _, u := range snap.Items {
				if u.GetName() == name {
					return u, nil
				}
			}
		}
	}
	return rq.client(c).Get(ctx, name, metav1.GetOptions{})
}

// shellVars are the k9s-style variables of an object for plugin shell
// actions, including its table row's cells as COL-<NAME>.
func (s *Server) shellVars(ctx context.Context, c *cluster.Clients, rq resourceQuery, u *unstructured.Unstructured, kubeconfig string) plugins.ShellVars {
	v := plugins.ShellVars{
		"NAME": u.GetName(), "NAMESPACE": u.GetNamespace(), "CONTEXT": c.Context, "KUBECONFIG": kubeconfig,
		"GROUP": rq.Type.Group, "VERSION": rq.Type.Version, "RESOURCE": rq.Type.Resource, "KIND": rq.Type.Kind,
		"CLUSTER": "", "USER": "",
	}
	if _, ctxs, err := s.mgr.Contexts(); err == nil {
		for _, ci := range ctxs {
			if ci.Name == c.Context {
				v["CLUSTER"], v["USER"] = ci.Cluster, ci.User
			}
		}
	}
	cols, _ := s.columnsFor(ctx, c, rq.Type)
	row := newTableBuilder(cols, false).row(u)
	for i, col := range cols {
		if i < len(row.Cells) && row.Cells[i] != nil {
			v[plugins.ColumnVar(col.Name)] = cellString(row.Cells[i])
		}
	}
	return v
}

func cellString(v any) string {
	switch x := v.(type) {
	case string:
		return x
	case []any:
		parts := make([]string, len(x))
		for i, p := range x {
			parts[i] = fmt.Sprint(p)
		}
		return strings.Join(parts, ",")
	}
	return fmt.Sprint(v)
}

// handlePluginPanel renders the plugins' sections for one object, and
// the shell actions offered for it (none on read-only contexts).
func (s *Server) handlePluginPanel(w http.ResponseWriter, r *http.Request) {
	out := map[string]any{"generation": s.plugins.Generation(), "panels": []plugins.PanelOut{}, "actions": []plugins.ActionOut{}}
	if !s.pluginsOn() {
		httpx.WriteJSON(w, http.StatusOK, out)
		return
	}
	c, rq, err := s.parseResource(r.Context(), r)
	if err != nil {
		writeErr(w, err)
		return
	}
	name := r.URL.Query().Get("name")
	if name == "" {
		writeErr(w, httpx.BadRequest("name is required"))
		return
	}
	u, err := s.pluginObject(r.Context(), c, rq, name)
	if err != nil {
		writeErr(w, err)
		return
	}
	if panels := s.plugins.Panels(s.pluginEnv(c), rq.Type, u.Object); panels != nil {
		out["panels"] = panels
	}
	if !s.isReadOnly() {
		home, _ := os.UserHomeDir()
		// Built only when an action is offered (it evaluates the row).
		vars := func() plugins.ShellVars {
			return s.shellVars(r.Context(), c, rq, u, kubeconfigChain(s.mgr.Kubeconfig(), os.Getenv("KUBECONFIG"), home))
		}
		if acts := s.plugins.Actions(s.pluginEnv(c), rq.Type, u.Object, vars); acts != nil {
			out["actions"] = acts
		}
	}
	out["resourceVersion"] = u.GetResourceVersion()
	httpx.WriteJSON(w, http.StatusOK, out)
}

// handlePluginEvents tells the UI about every plugin change (a load, a
// hot reload, a setting), so it refetches panels and the plugin list.
// Tables refresh on their own (handleWatch follows the same changes).
func (s *Server) handlePluginEvents(w http.ResponseWriter, r *http.Request) {
	ws, ctx, cancel, err := upgrade(w, r)
	if err != nil {
		return
	}
	defer cancel()
	defer ws.close()
	for {
		changed := s.plugins.Changed()
		if ws.send(map[string]any{"generation": s.plugins.Generation()}) != nil {
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-changed:
		}
	}
}

// pluginColumnsKey identifies a column set including plugin revisions, so
// a watch can tell whether a plugin change touched its columns.
func pluginColumnsKey(cols []columns.Column) string {
	var b strings.Builder
	for _, c := range cols {
		fmt.Fprintf(&b, "%s|%s|%s|%s|%d;", c.Name, c.Query, c.Type, c.Plugin, c.Rev)
	}
	return b.String()
}
