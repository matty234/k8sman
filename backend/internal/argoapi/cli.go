package argoapi

import (
	"context"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/yaml"
)

// AuthCLI: the token comes from the argocd CLI's own login
// (`argocd login <server> --sso`), read from its config file on each use, so
// re-logging in with the CLI refreshes k8sman too. The token is never copied
// into k8sman's settings, returned by the API, or logged.
const AuthCLI = "cli"

// cliConfig is the subset of the argocd CLI config we need.
type cliConfig struct {
	CurrentContext string `json:"current-context"`
	Contexts       []struct {
		Name   string `json:"name"`
		Server string `json:"server"`
		User   string `json:"user"`
	} `json:"contexts"`
	Users []struct {
		Name      string `json:"name"`
		AuthToken string `json:"auth-token"`
	} `json:"users"`
}

// cliConfigPath finds the argocd CLI config: $ARGOCD_CONFIG_DIR/config,
// ~/.config/argocd/config, or the legacy ~/.argocd/config.
func cliConfigPath() string {
	if d := os.Getenv("ARGOCD_CONFIG_DIR"); d != "" {
		return filepath.Join(d, "config")
	}
	home, _ := os.UserHomeDir()
	for _, p := range []string{filepath.Join(home, ".config", "argocd", "config"), filepath.Join(home, ".argocd", "config")} {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return filepath.Join(home, ".config", "argocd", "config")
}

// hostOf normalises "https://host:443/path", "host:443" or "host" to "host".
func hostOf(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	if !strings.Contains(s, "://") {
		s = "https://" + s
	}
	u, err := url.Parse(s)
	if err != nil {
		return ""
	}
	return strings.ToLower(u.Hostname())
}

// cliLogin is a usable login found in the CLI config.
type cliLogin struct {
	Context string // CLI context name
	Server  string // as written in the CLI config
	token   string // never serialised
}

// findCLILogin returns the CLI login whose server host equals wantHost (the
// cluster's Argo CD URL from argocd-cm). Matching is strict: a login for a
// different Argo CD is never used. ok=false when there is no matching login
// with a token.
func findCLILogin(path, wantHost string) (cliLogin, bool) {
	if wantHost == "" {
		return cliLogin{}, false
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return cliLogin{}, false
	}
	var cfg cliConfig
	if yaml.Unmarshal(raw, &cfg) != nil {
		return cliLogin{}, false
	}
	tokens := map[string]string{}
	for _, u := range cfg.Users {
		tokens[u.Name] = u.AuthToken
	}
	// Prefer the current context when it matches, then any other match.
	var best *cliLogin
	for _, c := range cfg.Contexts {
		if hostOf(c.Server) != wantHost || tokens[c.User] == "" {
			continue
		}
		l := cliLogin{Context: c.Name, Server: c.Server, token: tokens[c.User]}
		if c.Name == cfg.CurrentContext {
			return l, true
		}
		if best == nil {
			best = &l
		}
	}
	if best != nil {
		return *best, true
	}
	return cliLogin{}, false
}

// argoURLHost reads the externally visible Argo CD URL (argocd-cm `url`) in
// the server's namespace and returns its host ("" if unset/unreadable).
func argoURLHost(ctx context.Context, e env, s *Server) string {
	if s == nil {
		return ""
	}
	cm, err := e.typed.CoreV1().ConfigMaps(s.Namespace).Get(ctx, "argocd-cm", metav1.GetOptions{})
	if err != nil {
		return ""
	}
	return hostOf(cm.Data["url"])
}

// cliLoginFor finds the CLI login matching this cluster's Argo CD.
func (h *Handler) cliLoginFor(ctx context.Context, e env, s *Server) (cliLogin, bool) {
	return findCLILogin(h.cliFile(), argoURLHost(ctx, e, s))
}

// cliFile is the CLI config path (defaulted, so a zero Handler works).
func (h *Handler) cliFile() string {
	if h.cliPath != nil {
		return h.cliPath()
	}
	return cliConfigPath()
}
