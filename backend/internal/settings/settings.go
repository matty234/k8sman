// Package settings persists small app preferences (the chosen kubeconfig,
// recently used kubeconfigs, the last context per kubeconfig, the sidebar
// layout, read-only contexts, table preferences and turned-off
// integrations) in
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
	// ArgoCDTokens maps kube context → an Argo CD API token the user entered
	// (for per-resource diffs). The file is written 0600; tokens are never
	// returned by the API or logged.
	ArgoCDTokens map[string]string `json:"argocdTokens,omitempty"`
	// ArgoCDUseCLI marks kube contexts whose Argo CD auth comes from the
	// argocd CLI's own login (~/.config/argocd/config). Only the choice is
	// stored here; the token is read from the CLI config on use.
	ArgoCDUseCLI map[string]bool `json:"argocdUseCli,omitempty"`
	// Sidebar is the user's layout of the sidebar's top section (pages and
	// pinned kinds). nil = the app's default layout.
	Sidebar *Sidebar `json:"sidebar,omitempty"`
	// ReadOnlyContexts maps kube context → the user's choice: true =
	// read-only, false = writable. Absent = automatic (see AutoReadOnly).
	ReadOnlyContexts map[string]bool `json:"readOnlyContexts,omitempty"`
	// Tables maps a resource kind ("group/Kind", "" group for core) to its
	// table preferences.
	Tables map[string]TablePrefs `json:"tables,omitempty"`
	// DisabledModules lists the integrations the user turned off (module
	// ids such as "helm" or "argocd"). Absent = all on.
	DisabledModules []string `json:"disabledModules,omitempty"`
}

// TablePrefs is how a resource kind's table was last left.
type TablePrefs struct {
	// SortColumn is a column name ("" = default order).
	SortColumn     string `json:"sortColumn,omitempty"`
	SortDescending bool   `json:"sortDescending,omitempty"`
	// Widths maps column name → width the user dragged it to.
	Widths map[string]float64 `json:"widths,omitempty"`
	Filter string             `json:"filter,omitempty"`
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
	return st, nil
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
	out.Tables = cloneTables(st.s.Tables)
	out.DisabledModules = slices.Clone(st.s.DisabledModules)
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
	next.Tables = cloneTables(st.s.Tables)
	next.DisabledModules = slices.Clone(st.s.DisabledModules)
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
		s.Tables[kind] = TablePrefs{SortColumn: p.SortColumn, SortDescending: p.SortDescending, Widths: maps.Clone(p.Widths), Filter: p.Filter}
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

// SetLastContext remembers the selected context for a kubeconfig path.
func (st *Store) SetLastContext(kubeconfig, context string) error {
	return st.Update(func(s *Settings) { s.LastContext[kubeconfig] = context })
}

// ArgoCDToken returns the Argo CD token saved for a kube context ("" = none).
func (st *Store) ArgoCDToken(context string) string {
	st.mu.Lock()
	defer st.mu.Unlock()
	return st.s.ArgoCDTokens[context]
}

// SetArgoCDToken saves (or, with an empty token, removes) the Argo CD token
// for a kube context.
func (st *Store) SetArgoCDToken(context, token string) error {
	return st.Update(func(s *Settings) {
		if token == "" {
			delete(s.ArgoCDTokens, context)
			if len(s.ArgoCDTokens) == 0 {
				s.ArgoCDTokens = nil
			}
			return
		}
		if s.ArgoCDTokens == nil {
			s.ArgoCDTokens = map[string]string{}
		}
		s.ArgoCDTokens[context] = token
	})
}

// ArgoCDUseCLI reports whether a kube context uses the argocd CLI's login.
func (st *Store) ArgoCDUseCLI(context string) bool {
	st.mu.Lock()
	defer st.mu.Unlock()
	return st.s.ArgoCDUseCLI[context]
}

// SetArgoCDUseCLI turns CLI-login auth on or off for a kube context.
func (st *Store) SetArgoCDUseCLI(context string, on bool) error {
	return st.Update(func(s *Settings) {
		if !on {
			delete(s.ArgoCDUseCLI, context)
			if len(s.ArgoCDUseCLI) == 0 {
				s.ArgoCDUseCLI = nil
			}
			return
		}
		if s.ArgoCDUseCLI == nil {
			s.ArgoCDUseCLI = map[string]bool{}
		}
		s.ArgoCDUseCLI[context] = true
	})
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
