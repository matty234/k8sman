// Package settings persists small app preferences (the chosen kubeconfig,
// recently used kubeconfigs, the last context per kubeconfig, the sidebar
// layout, read-only contexts, table preferences, turned-off integrations,
// saved views and integrations' own settings) in
// ~/.config/k8sman/settings.json.
package settings

import (
	"encoding/json"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sync"
)

// MaxRecent is how many recently used kubeconfig paths are kept.
const MaxRecent = 10

// Settings is the persisted document.
type Settings struct {
	// Kubeconfig is the kubeconfig path chosen in the UI ("" = default).
	Kubeconfig string `json:"kubeconfig,omitempty"`
	// RecentKubeconfigs is most recently used first.
	RecentKubeconfigs []string `json:"recentKubeconfigs,omitempty"`
	// LastContext maps kubeconfig path → last selected context.
	LastContext map[string]string `json:"lastContext,omitempty"`
	// RemoteIcons controls fetching CRD group icons from the internet
	// (chart icon URLs and website favicons). nil = automatic: on for local
	// clusters (kind, k3d, minikube, Docker Desktop, …), off otherwise.
	RemoteIcons *bool `json:"remoteIcons,omitempty"`
	// ArgoCDTokens and ArgoCDUseCLI are where releases before the module
	// settings kept Argo CD auth (kube context → API token, and kube
	// context → "use the argocd CLI's login"). They are only read, to move
	// their values into ModuleSettings["argocd"] when the file is opened
	// (see migrateArgoCD); the file is written without them afterwards.
	ArgoCDTokens map[string]string `json:"argocdTokens,omitempty"`
	ArgoCDUseCLI map[string]bool   `json:"argocdUseCli,omitempty"`
	// Sidebar is the user's layout of the sidebar's top section (pages and
	// pinned kinds). nil = the app's default layout.
	Sidebar *Sidebar `json:"sidebar,omitempty"`
	// ReadOnlyContexts maps kube context → the user's choice: true =
	// read-only, false = writable. Absent = automatic (see AutoReadOnly).
	ReadOnlyContexts map[string]bool `json:"readOnlyContexts,omitempty"`
	// ContextAppearance maps kube context → the icon and colour the user
	// picked for its badge. Absent = the default badge.
	ContextAppearance map[string]Appearance `json:"contextAppearance,omitempty"`
	// Tables maps a resource kind ("group/Kind", "" group for core) to its
	// table preferences.
	Tables map[string]TablePrefs `json:"tables,omitempty"`
	// DisabledModules lists the integrations the user turned off (module
	// ids such as "helm" or "argocd"). Absent = all on.
	DisabledModules []string `json:"disabledModules,omitempty"`
	// Views are the saved views (see View), in the user's order. Records
	// are kept as stored, so entries written by a newer version of the app
	// (a higher "version") survive a downgrade untouched.
	Views []json.RawMessage `json:"views,omitempty"`
	// LaunchView is the id of a view to open at launch instead of
	// reconnecting to the last context ("" = reconnect).
	LaunchView string `json:"launchView,omitempty"`
	// ModuleSettings holds integration modules' own settings: module id →
	// kube context → the module's JSON object. Opaque here; each module
	// validates and decodes its own (see ModuleSettings).
	ModuleSettings map[string]map[string]json.RawMessage `json:"moduleSettings,omitempty"`
	// Namespaces maps kube context → namespaces the user added by hand
	// (for clusters where Namespaces can't be listed), in the order added.
	Namespaces map[string][]string `json:"namespaces,omitempty"`
	// FavouriteNamespaces maps kube context → starred namespaces.
	FavouriteNamespaces map[string][]string `json:"favouriteNamespaces,omitempty"`
	// AppLinks makes "Copy link" copy the k8sman:// form instead of the
	// https://k8sman.dev/o/ one.
	AppLinks bool `json:"appLinks,omitempty"`
	// LinkClusterMap maps a cluster fingerprint from a shared link to the
	// local context the user chose to open such links in.
	LinkClusterMap map[string]string `json:"linkClusterMap,omitempty"`

	// LogsNewestFirst shows log lines newest first in every log view.
	LogsNewestFirst bool `json:"logsNewestFirst,omitempty"`
}

// ViewVersion is the view record version this build writes.
const ViewVersion = 1

// MaxViews caps how many saved views are kept.
const MaxViews = 500

// View is a saved table: a kind, a namespace scope, a filter, a sort and
// columns, on one context or on any context. See docs/VIEWS.md.
type View struct {
	Version int    `json:"version"`
	ID      string `json:"id"`
	Name    string `json:"name"`
	// Context binds the view to one context; nil = any context.
	Context *ViewContext `json:"context"`
	Kind    ViewKind     `json:"kind"`
	// Namespaces is the scope; empty = all namespaces.
	Namespaces []string  `json:"namespaces"`
	Filter     string    `json:"filter,omitempty"`
	Sort       *ViewSort `json:"sort,omitempty"`
	// Columns is the view's own column set and order (nil = the kind's).
	Columns []ViewColumn `json:"columns,omitempty"`
}

// ViewContext is a context identity: (kubeconfig path, context name). The
// API server URL is kept so a view can be re-pointed to a renamed context.
type ViewContext struct {
	Kubeconfig string `json:"kubeconfig"`
	Name       string `json:"name"`
	Server     string `json:"server,omitempty"`
}

// ViewKind is a kind by API group and Kind, like a sidebar pin.
type ViewKind struct {
	Group string `json:"group"`
	Kind  string `json:"kind"`
}

// ViewSort is a sort by column name.
type ViewSort struct {
	Column     string `json:"column"`
	Descending bool   `json:"descending,omitempty"`
}

// ViewColumn is a table column (see internal/columns).
type ViewColumn struct {
	Name  string `json:"name"`
	Query string `json:"query"`
	Type  string `json:"type,omitempty"`
}

var viewID = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)

// Valid checks a view this build writes.
func (v View) Valid() error {
	switch {
	case v.Version != ViewVersion:
		return fmt.Errorf("version must be %d", ViewVersion)
	case !viewID.MatchString(v.ID):
		return fmt.Errorf("invalid view id %q", v.ID)
	case v.Name == "" || len(v.Name) > 200:
		return fmt.Errorf("a view needs a name (at most 200 characters)")
	case v.Kind.Kind == "":
		return fmt.Errorf("a view needs a kind")
	case v.Context != nil && v.Context.Name == "":
		return fmt.Errorf("a bound view needs a context name")
	case len(v.Namespaces) > 1000 || len(v.Filter) > 1000 || len(v.Columns) > 100:
		return fmt.Errorf("view too large")
	}
	return nil
}

// recordID reads the id of a stored view record of any version.
func recordID(raw json.RawMessage) string {
	var head struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(raw, &head)
	return head.ID
}

// TablePrefs is how a resource kind's table was last left.
type TablePrefs struct {
	// SortColumn is a column name ("" = default order).
	SortColumn     string `json:"sortColumn,omitempty"`
	SortDescending bool   `json:"sortDescending,omitempty"`
	// Widths maps column name → width the user dragged it to.
	Widths map[string]float64 `json:"widths,omitempty"`
	Filter string             `json:"filter,omitempty"`
	// Mode is the last mode of the page that is the kind's home ("table"
	// for its Table mode; "" = the page's default), e.g. the Nodes page.
	Mode string `json:"mode,omitempty"`
}

// MaxTables caps how many kinds' table preferences are kept.
const MaxTables = 500

var productionName = regexp.MustCompile(`(?i)(^|[^a-z])(prod|production|prd)([^a-z]|$)`)

// AutoReadOnly reports whether a context with no explicit choice is
// read-only: its name looks like production ("prod", "production" or "prd"
// as a word, e.g. "prod-eu", "gke_acme_prod", but not "product-api").
func AutoReadOnly(context string) bool { return productionName.MatchString(context) }

func cloneTables(t map[string]TablePrefs) map[string]TablePrefs {
	if t == nil {
		return nil
	}
	out := make(map[string]TablePrefs, len(t))
	for k, v := range t {
		v.Widths = maps.Clone(v.Widths)
		out[k] = v
	}
	return out
}

// Sidebar lists the top-of-sidebar entries in display order. Each entry is
// either a page (View set) or a pinned resource kind (Kind set). Pins apply
// across clusters and are keyed by API group and kind, not version.
type Sidebar struct {
	Items []SidebarItem `json:"items"`
}

// SidebarItem is one entry of [Sidebar].
type SidebarItem struct {
	// View is a page id (e.g. "overview", "helm").
	View string `json:"view,omitempty"`
	// Hidden pages are folded under the sidebar's "More" item.
	Hidden bool `json:"hidden,omitempty"`
	// Group ("" = core) and Kind of a pinned resource kind.
	Group string `json:"group,omitempty"`
	Kind  string `json:"kind,omitempty"`
	// Namespace optionally scopes a pin ("" = whichever namespace is chosen).
	Namespace string `json:"namespace,omitempty"`
}

// Valid reports whether every item is either a page or a pin.
func (sb Sidebar) Valid() error {
	for i, it := range sb.Items {
		if (it.View == "") == (it.Kind == "") {
			return fmt.Errorf("item %d: set exactly one of view or kind", i)
		}
		if it.View != "" && (it.Group != "" || it.Namespace != "") {
			return fmt.Errorf("item %d: a view takes no group or namespace", i)
		}
	}
	return nil
}

func cloneSidebar(sb *Sidebar) *Sidebar {
	if sb == nil {
		return nil
	}
	return &Sidebar{Items: slices.Clone(sb.Items)}
}

// Store reads and writes the settings file. Methods are safe for concurrent use.
type Store struct {
	path string
	mu   sync.Mutex
	s    Settings
}

// DefaultPath is ~/.config/k8sman/settings.json.
func DefaultPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "k8sman", "settings.json")
}

// Open loads the file at path. A missing file yields empty settings. A
// corrupt file also yields an empty (usable) store plus the parse error, so
// callers can log it and carry on.
func Open(path string) (*Store, error) {
	st := &Store{path: path}
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return st, nil
		}
		return st, err
	}
	if err := json.Unmarshal(b, &st.s); err != nil {
		st.s = Settings{}
		return st, fmt.Errorf("parse %s: %w", path, err)
	}
	if st.s.migrateArgoCD() {
		// A failed write is fine: the migrated settings are in memory and
		// the next save writes them.
		_ = st.write(st.s)
	}
	return st, nil
}

// migrateArgoCD moves the legacy ArgoCDTokens / ArgoCDUseCLI values into
// ModuleSettings["argocd"][context] ({"token": …, "useCli": true}) and
// drops the old fields. A context that already has module settings keeps
// them: the new fields win, the old ones are read only where the new are
// absent. Reports whether anything changed. Never logs: the values are
// secrets.
func (s *Settings) migrateArgoCD() bool {
	if len(s.ArgoCDTokens) == 0 && len(s.ArgoCDUseCLI) == 0 {
		s.ArgoCDTokens, s.ArgoCDUseCLI = nil, nil
		return false
	}
	contexts := map[string]bool{}
	for c := range s.ArgoCDTokens {
		contexts[c] = true
	}
	for c := range s.ArgoCDUseCLI {
		contexts[c] = true
	}
	for c := range contexts {
		if s.ModuleSettings["argocd"][c] != nil {
			continue
		}
		obj := map[string]any{}
		if t := s.ArgoCDTokens[c]; t != "" {
			obj["token"] = t
		}
		if s.ArgoCDUseCLI[c] {
			obj["useCli"] = true
		}
		if len(obj) == 0 {
			continue
		}
		raw, err := json.Marshal(obj)
		if err != nil {
			continue
		}
		if s.ModuleSettings == nil {
			s.ModuleSettings = map[string]map[string]json.RawMessage{}
		}
		if s.ModuleSettings["argocd"] == nil {
			s.ModuleSettings["argocd"] = map[string]json.RawMessage{}
		}
		s.ModuleSettings["argocd"][c] = raw
	}
	s.ArgoCDTokens, s.ArgoCDUseCLI = nil, nil
	return true
}

// Get returns a copy of the current settings.
func (st *Store) Get() Settings {
	st.mu.Lock()
	defer st.mu.Unlock()
	out := st.s
	out.RecentKubeconfigs = slices.Clone(st.s.RecentKubeconfigs)
	if st.s.LastContext != nil {
		out.LastContext = make(map[string]string, len(st.s.LastContext))
		for k, v := range st.s.LastContext {
			out.LastContext[k] = v
		}
	}
	out.ArgoCDTokens = maps.Clone(st.s.ArgoCDTokens)
	out.ArgoCDUseCLI = maps.Clone(st.s.ArgoCDUseCLI)
	out.Sidebar = cloneSidebar(st.s.Sidebar)
	out.ReadOnlyContexts = maps.Clone(st.s.ReadOnlyContexts)
	out.ContextAppearance = maps.Clone(st.s.ContextAppearance)
	out.LinkClusterMap = maps.Clone(st.s.LinkClusterMap)
	out.Tables = cloneTables(st.s.Tables)
	out.DisabledModules = slices.Clone(st.s.DisabledModules)
	out.Views = slices.Clone(st.s.Views)
	out.ModuleSettings = cloneModuleSettings(st.s.ModuleSettings)
	out.Namespaces = cloneNamespaces(st.s.Namespaces)
	out.FavouriteNamespaces = cloneNamespaces(st.s.FavouriteNamespaces)
	return out
}

// Update applies fn and saves the result atomically.
func (st *Store) Update(fn func(*Settings)) error {
	st.mu.Lock()
	defer st.mu.Unlock()
	next := st.s
	next.RecentKubeconfigs = slices.Clone(st.s.RecentKubeconfigs)
	next.LastContext = map[string]string{}
	for k, v := range st.s.LastContext {
		next.LastContext[k] = v
	}
	next.ArgoCDTokens = maps.Clone(st.s.ArgoCDTokens)
	next.ArgoCDUseCLI = maps.Clone(st.s.ArgoCDUseCLI)
	next.Sidebar = cloneSidebar(st.s.Sidebar)
	next.ReadOnlyContexts = maps.Clone(st.s.ReadOnlyContexts)
	next.ContextAppearance = maps.Clone(st.s.ContextAppearance)
	next.LinkClusterMap = maps.Clone(st.s.LinkClusterMap)
	next.Tables = cloneTables(st.s.Tables)
	next.DisabledModules = slices.Clone(st.s.DisabledModules)
	next.Views = slices.Clone(st.s.Views)
	next.ModuleSettings = cloneModuleSettings(st.s.ModuleSettings)
	next.Namespaces = cloneNamespaces(st.s.Namespaces)
	next.FavouriteNamespaces = cloneNamespaces(st.s.FavouriteNamespaces)
	fn(&next)
	if err := st.write(next); err != nil {
		return err
	}
	st.s = next
	return nil
}

// UseKubeconfig records path as the chosen kubeconfig and moves it to the
// front of the recent list.
func (st *Store) UseKubeconfig(path string) error {
	return st.Update(func(s *Settings) {
		s.Kubeconfig = path
		if path == "" {
			return
		}
		s.RecentKubeconfigs = slices.DeleteFunc(s.RecentKubeconfigs, func(p string) bool { return p == path })
		s.RecentKubeconfigs = append([]string{path}, s.RecentKubeconfigs...)
		if len(s.RecentKubeconfigs) > MaxRecent {
			s.RecentKubeconfigs = s.RecentKubeconfigs[:MaxRecent]
		}
	})
}

// ContextReadOnly is the user's choice for a context, if they made one.
func (st *Store) ContextReadOnly(context string) (readOnly, chosen bool) {
	st.mu.Lock()
	defer st.mu.Unlock()
	readOnly, chosen = st.s.ReadOnlyContexts[context]
	return readOnly, chosen
}

// SetContextReadOnly records the choice for a context; nil forgets it (back
// to automatic).
func (st *Store) SetContextReadOnly(context string, readOnly *bool) error {
	return st.Update(func(s *Settings) {
		if readOnly == nil {
			delete(s.ReadOnlyContexts, context)
			if len(s.ReadOnlyContexts) == 0 {
				s.ReadOnlyContexts = nil
			}
			return
		}
		if s.ReadOnlyContexts == nil {
			s.ReadOnlyContexts = map[string]bool{}
		}
		s.ReadOnlyContexts[context] = *readOnly
	})
}

// Appearance is a context's badge: Icon is a stable id from the app's icon
// set (or "text:PR", a 1-2 character monogram), Color a palette id or
// "#rrggbb". Either may be empty (default). The store doesn't know the
// sets, so ids written by a newer version survive.
type Appearance struct {
	Icon  string `json:"icon,omitempty"`
	Color string `json:"color,omitempty"`
}

// SetContextAppearance saves a context's badge; an empty one forgets it.
func (st *Store) SetContextAppearance(context string, a Appearance) error {
	return st.Update(func(s *Settings) {
		if a == (Appearance{}) {
			delete(s.ContextAppearance, context)
			if len(s.ContextAppearance) == 0 {
				s.ContextAppearance = nil
			}
			return
		}
		if s.ContextAppearance == nil {
			s.ContextAppearance = map[string]Appearance{}
		}
		s.ContextAppearance[context] = a
	})
}

// SetTablePrefs saves (or, with nil, forgets) a kind's table preferences.
func (st *Store) SetTablePrefs(kind string, p *TablePrefs) error {
	return st.Update(func(s *Settings) {
		if p == nil {
			delete(s.Tables, kind)
			return
		}
		if s.Tables == nil {
			s.Tables = map[string]TablePrefs{}
		}
		if _, ok := s.Tables[kind]; !ok && len(s.Tables) >= MaxTables {
			return
		}
		s.Tables[kind] = TablePrefs{SortColumn: p.SortColumn, SortDescending: p.SortDescending, Widths: maps.Clone(p.Widths), Filter: p.Filter, Mode: p.Mode}
	})
}

// ModuleDisabled reports whether the user turned the integration off.
func (st *Store) ModuleDisabled(id string) bool {
	if st == nil {
		return false
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	return slices.Contains(st.s.DisabledModules, id)
}

var moduleID = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,39}$`)

// SetDisabledModules replaces the list of turned-off integrations (kept
// sorted, without duplicates). Ids are lowercase words such as "argocd".
func (st *Store) SetDisabledModules(ids []string) error {
	for _, id := range ids {
		if !moduleID.MatchString(id) {
			return fmt.Errorf("invalid module id %q", id)
		}
	}
	ids = slices.Compact(slices.Sorted(slices.Values(ids)))
	return st.Update(func(s *Settings) {
		s.DisabledModules = nil
		if len(ids) > 0 {
			s.DisabledModules = ids
		}
	})
}

// PutView adds a view, or replaces the one with the same id (keeping its
// place in the order).
func (st *Store) PutView(v View) error { return st.PutViewAt(v, -1) }

// PutViewAt is PutView with a position: index >= 0 places the view at that
// index of the order (clamped to the end), moving it if it already exists.
// Undoing a delete uses it to put the view back where it was.
func (st *Store) PutViewAt(v View, index int) error {
	if err := v.Valid(); err != nil {
		return err
	}
	raw, err := json.Marshal(v)
	if err != nil {
		return err
	}
	var full bool
	err = st.Update(func(s *Settings) {
		at := slices.IndexFunc(s.Views, func(r json.RawMessage) bool { return recordID(r) == v.ID })
		if at >= 0 && index < 0 {
			s.Views[at] = raw
			return
		}
		if at < 0 && len(s.Views) >= MaxViews {
			full = true
			return
		}
		if at >= 0 {
			s.Views = slices.Delete(s.Views, at, at+1)
		}
		if index < 0 || index > len(s.Views) {
			index = len(s.Views)
		}
		s.Views = slices.Insert(s.Views, index, raw)
	})
	if err == nil && full {
		err = fmt.Errorf("at most %d views can be saved", MaxViews)
	}
	return err
}

// ReorderViews puts the views named in ids in that order. They keep the
// slots they occupy now, so records this build doesn't read (newer
// versions) stay where they are. Unknown ids are ignored.
func (st *Store) ReorderViews(ids []string) error {
	return st.Update(func(s *Settings) {
		byID := map[string]json.RawMessage{}
		for _, r := range s.Views {
			byID[recordID(r)] = r
		}
		var order []json.RawMessage
		seen := map[string]bool{}
		for _, id := range ids {
			if r, ok := byID[id]; ok && !seen[id] {
				seen[id] = true
				order = append(order, r)
			}
		}
		for i, r := range s.Views {
			if seen[recordID(r)] {
				s.Views[i], order = order[0], order[1:]
			}
		}
	})
}

// DeleteView removes a view (and the launch setting if it pointed at it).
func (st *Store) DeleteView(id string) error {
	return st.Update(func(s *Settings) {
		s.Views = slices.DeleteFunc(s.Views, func(r json.RawMessage) bool { return recordID(r) == id })
		if len(s.Views) == 0 {
			s.Views = nil
		}
		if s.LaunchView == id {
			s.LaunchView = ""
		}
	})
}

// SetLaunchView sets the view to open at launch ("" = reconnect to the
// last context).
func (st *Store) SetLaunchView(id string) error {
	if id != "" && !viewID.MatchString(id) {
		return fmt.Errorf("invalid view id %q", id)
	}
	return st.Update(func(s *Settings) { s.LaunchView = id })
}

// ModuleSettings decodes module id's settings for a kube context into v
// (a pointer to the module's settings struct). It reports whether any were
// saved; v is left alone when not.
func (st *Store) ModuleSettings(id, context string, v any) (bool, error) {
	if st == nil {
		return false, nil
	}
	st.mu.Lock()
	raw := st.s.ModuleSettings[id][context]
	st.mu.Unlock()
	if raw == nil {
		return false, nil
	}
	return true, json.Unmarshal(raw, v)
}

// RawModuleSettings returns module id's settings for a kube context as
// saved (nil = none).
func (st *Store) RawModuleSettings(id, context string) json.RawMessage {
	st.mu.Lock()
	defer st.mu.Unlock()
	return slices.Clone(st.s.ModuleSettings[id][context])
}

// SetModuleSettings saves module id's settings (a JSON object) for a kube
// context; nil or {} removes them.
func (st *Store) SetModuleSettings(id, context string, raw json.RawMessage) error {
	if !moduleID.MatchString(id) {
		return fmt.Errorf("invalid module id %q", id)
	}
	var obj map[string]any
	if raw != nil {
		if err := json.Unmarshal(raw, &obj); err != nil || obj == nil {
			return fmt.Errorf("module settings must be a JSON object")
		}
	}
	return st.Update(func(s *Settings) { applyModuleSettings(s, id, context, raw, len(obj) == 0) })
}

// UpdateModuleSettings changes module id's settings for a kube context
// atomically: fn gets what is saved (nil = none) and returns what to save
// (nil or {} removes). Nothing changes when fn fails.
func (st *Store) UpdateModuleSettings(id, context string, fn func(saved json.RawMessage) (json.RawMessage, error)) error {
	if !moduleID.MatchString(id) {
		return fmt.Errorf("invalid module id %q", id)
	}
	var ferr error
	err := st.Update(func(s *Settings) {
		raw, e := fn(slices.Clone(s.ModuleSettings[id][context]))
		if e != nil {
			ferr = e
			return
		}
		var obj map[string]any
		if raw != nil && (json.Unmarshal(raw, &obj) != nil || obj == nil) {
			ferr = fmt.Errorf("module settings must be a JSON object")
			return
		}
		applyModuleSettings(s, id, context, raw, len(obj) == 0)
	})
	if ferr != nil {
		return ferr
	}
	return err
}

func applyModuleSettings(s *Settings, id, context string, raw json.RawMessage, remove bool) {
	if remove {
		delete(s.ModuleSettings[id], context)
		if len(s.ModuleSettings[id]) == 0 {
			delete(s.ModuleSettings, id)
		}
		if len(s.ModuleSettings) == 0 {
			s.ModuleSettings = nil
		}
		return
	}
	if s.ModuleSettings == nil {
		s.ModuleSettings = map[string]map[string]json.RawMessage{}
	}
	if s.ModuleSettings[id] == nil {
		s.ModuleSettings[id] = map[string]json.RawMessage{}
	}
	s.ModuleSettings[id][context] = slices.Clone(raw)
}

func cloneModuleSettings(m map[string]map[string]json.RawMessage) map[string]map[string]json.RawMessage {
	if m == nil {
		return nil
	}
	out := make(map[string]map[string]json.RawMessage, len(m))
	for id, byCtx := range m {
		out[id] = maps.Clone(byCtx)
	}
	return out
}

// SetLastContext remembers the selected context for a kubeconfig path.
func (st *Store) SetLastContext(kubeconfig, context string) error {
	return st.Update(func(s *Settings) { s.LastContext[kubeconfig] = context })
}

// SetSidebar saves the sidebar layout; nil restores the default.
func (st *Store) SetSidebar(sb *Sidebar) error {
	if sb != nil {
		if err := sb.Valid(); err != nil {
			return err
		}
	}
	return st.Update(func(s *Settings) { s.Sidebar = cloneSidebar(sb) })
}

func (st *Store) write(s Settings) error {
	if st.path == "" {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(st.path), 0o755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	tmp := st.path + ".tmp"
	if err := os.WriteFile(tmp, append(b, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, st.path)
}

func cloneNamespaces(m map[string][]string) map[string][]string {
	if m == nil {
		return nil
	}
	out := make(map[string][]string, len(m))
	for k, v := range m {
		out[k] = slices.Clone(v)
	}
	return out
}

// SetNamespaces saves the namespaces added by hand for a kube context
// (empty forgets them).
func (st *Store) SetNamespaces(context string, namespaces []string) error {
	return st.Update(func(s *Settings) {
		if len(namespaces) == 0 {
			delete(s.Namespaces, context)
			if len(s.Namespaces) == 0 {
				s.Namespaces = nil
			}
			return
		}
		if s.Namespaces == nil {
			s.Namespaces = map[string][]string{}
		}
		s.Namespaces[context] = slices.Clone(namespaces)
	})
}

// SetFavouriteNamespaces saves the starred namespaces for a kube context
// (empty forgets them).
func (st *Store) SetFavouriteNamespaces(context string, namespaces []string) error {
	return st.Update(func(s *Settings) {
		if len(namespaces) == 0 {
			delete(s.FavouriteNamespaces, context)
			if len(s.FavouriteNamespaces) == 0 {
				s.FavouriteNamespaces = nil
			}
			return
		}
		if s.FavouriteNamespaces == nil {
			s.FavouriteNamespaces = map[string][]string{}
		}
		s.FavouriteNamespaces[context] = slices.Clone(namespaces)
	})
}
