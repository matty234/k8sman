// Package settings persists small app preferences (the chosen kubeconfig,
// recently used kubeconfigs and the last context per kubeconfig) in
// ~/.config/k8sman/settings.json.
package settings

import (
	"encoding/json"
	"fmt"
	"maps"
	"os"
	"path/filepath"
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
