package server

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/mcpserver"
	"github.com/matty234/k8sman/backend/internal/settings"
)

// Claude Code access (Settings ▸ General ▸ Claude Code). While the setting
// is on, the server has a second, per-launch token that only allows the
// reads the MCP tools make (mcpAllowed), and writes it with the listen
// address to mcp.json, where `k8sman-server mcp` (the stdio MCP server
// Claude Code starts) finds it. Turning it off, or quitting, removes the
// file and forgets the token.

func (s *Server) mcpRoutes() {
	s.mux.HandleFunc("GET /api/settings/mcp", func(w http.ResponseWriter, r *http.Request) {
		httpx.WriteJSON(w, 200, s.mcpState())
	})
	s.mux.HandleFunc("PUT /api/settings/mcp", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Enabled *bool   `json:"enabled"`
			Folder  *string `json:"folder"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			writeErr(w, httpx.BadRequest("body must be {\"enabled\"?: bool, \"folder\"?: string}: %v", err))
			return
		}
		var folder string
		if body.Folder != nil {
			f, err := checkClaudeFolder(*body.Folder)
			if err != nil {
				writeErr(w, httpx.BadRequest("%v", err))
				return
			}
			folder = f
		}
		if err := s.settings.Update(func(st *settings.Settings) {
			if body.Enabled != nil {
				st.ClaudeCodeMCP = *body.Enabled
			}
			if body.Folder != nil {
				st.ClaudeCodeDir = folder
			}
		}); err != nil {
			writeErr(w, err)
			return
		}
		if err := s.syncMCP(); err != nil {
			writeErr(w, err)
			return
		}
		httpx.WriteJSON(w, 200, s.mcpState())
	})
}

func (s *Server) mcpState() map[string]any {
	exe, err := os.Executable()
	if err != nil {
		exe = "k8sman-server"
	}
	st := s.settings.Get()
	return map[string]any{
		"enabled":       st.ClaudeCodeMCP,
		"folder":        st.ClaudeCodeDir,
		"defaultFolder": filepath.Join(filepath.Dir(s.mcpPath), "claude"),
		"command":       []string{exe, "mcp"},
		"addCommand":    "claude mcp add --scope user k8sman -- " + shellQuote(exe) + " mcp",
	}
}

// syncMCP makes the token and mcp.json match the setting. Without a listen
// address (tests, or a server not started by main) there's nothing to
// advertise.
func (s *Server) syncMCP() error {
	s.mcpMu.Lock()
	defer s.mcpMu.Unlock()
	on := s.settings.Get().ClaudeCodeMCP && s.listenAddr != "" && s.mcpPath != ""
	if !on {
		if s.mcpToken != "" {
			mcpserver.RemoveDiscovery(s.mcpPath, s.mcpToken)
			s.mcpToken = ""
		}
		return nil
	}
	if s.mcpToken == "" {
		t, err := NewToken()
		if err != nil {
			return err
		}
		s.mcpToken = t
	}
	return mcpserver.WriteDiscovery(s.mcpPath, mcpserver.Discovery{Addr: s.listenAddr, Token: s.mcpToken, PID: os.Getpid()})
}

// CloseMCP removes mcp.json if this server wrote it. Call on shutdown.
func (s *Server) CloseMCP() {
	s.mcpMu.Lock()
	defer s.mcpMu.Unlock()
	if s.mcpToken != "" {
		mcpserver.RemoveDiscovery(s.mcpPath, s.mcpToken)
		s.mcpToken = ""
	}
}

func (s *Server) currentMCPToken() string {
	s.mcpMu.Lock()
	defer s.mcpMu.Unlock()
	return s.mcpToken
}

// mcpPaths are what the MCP token may read.
var mcpPaths = map[string]bool{
	"/api/health":     true,
	"/api/namespaces": true,
	"/api/resources":  true,
	"/api/table":      true,
	"/api/items":      true,
	"/api/object":     true,
	"/api/events":     true,
	"/api/owned":      true,
	"/api/overview":   true,
	"/api/logs/text":  true,
	"/api/security":   true,
}

// mcpWrites are the only writes the MCP token may make: adding Security
// ignore rules (local settings, marked by "claude", undone on the page).
var mcpWrites = map[string]bool{
	"POST /api/security/ignores": true,
}

// mcpAllowed reports whether a request carrying the MCP token may proceed:
// plain GETs (no WebSocket upgrades, so no exec, shells or watches) of
// mcpPaths, never Secrets, and mcpWrites.
func mcpAllowed(r *http.Request) bool {
	if r.Header.Get("Upgrade") != "" {
		return false
	}
	if mcpWrites[r.Method+" "+r.URL.Path] {
		return true
	}
	if r.Method != http.MethodGet || !mcpPaths[r.URL.Path] {
		return false
	}
	q := r.URL.Query()
	return !(q.Get("group") == "" && strings.EqualFold(q.Get("resource"), "secrets"))
}

// shellQuote quotes p for a POSIX shell when it needs it.
func shellQuote(p string) string {
	if p != "" && strings.IndexFunc(p, func(r rune) bool {
		return !(r == '/' || r == '.' || r == '-' || r == '_' || r == ':' || r == '\\' ||
			r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9')
	}) < 0 {
		return p
	}
	return "'" + strings.ReplaceAll(p, "'", `'\''`) + "'"
}

func logMCP(err error) {
	if err != nil {
		log.Printf("claude code access: %v", err)
	}
}

// maxClaudePrompt caps the prompt a Claude Code tab starts with.
const maxClaudePrompt = 5000

// claudeShellSpec turns spec into a Claude Code session (?claude=1, with an
// optional ?prompt=): the user's login shell runs `claude` with the k8sman
// MCP server for this session only (--mcp-config, nothing is added to the
// user's Claude Code config), then stays open as a normal shell. The command
// is fixed here; the prompt only travels as an environment variable, so it's
// never parsed by the shell. Needs Claude Code access on, since the MCP
// server reads through mcp.json.
func (s *Server) claudeShellSpec(spec *localShellSpec, prompt string) error {
	s.mcpMu.Lock()
	on := s.mcpToken != ""
	s.mcpMu.Unlock()
	if !on {
		return errors.New("turn on Settings ▸ General ▸ Claude Code first")
	}
	if len(prompt) > maxClaudePrompt {
		return fmt.Errorf("the prompt is longer than %d characters", maxClaudePrompt)
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	cfg, _ := json.Marshal(map[string]any{"mcpServers": map[string]any{"k8sman": map[string]any{
		"type": "stdio", "command": exe, "args": []string{"mcp", "--discovery", s.mcpPath},
	}}})
	spec.Env = append(spec.Env, "K8SMAN_CLAUDE_MCP="+string(cfg), "K8SMAN_CLAUDE_PROMPT="+prompt)
	// The prompt goes first: --mcp-config takes several values, so it would
	// swallow an argument after it.
	run := `claude --mcp-config "$K8SMAN_CLAUDE_MCP"`
	if prompt != "" {
		run = `claude "$K8SMAN_CLAUDE_PROMPT" --mcp-config "$K8SMAN_CLAUDE_MCP"`
	}
	const missing = "k8sman: Claude Code is not installed, or not on your PATH. See https://code.claude.com"
	then := "; exec " + shellQuote(spec.Shell) + " -l"
	var script string
	if filepath.Base(spec.Shell) == "fish" {
		script = "if command -v claude >/dev/null 2>&1; " + run + "; else; echo '" + missing + "'; end" + then
	} else {
		script = "if command -v claude >/dev/null 2>&1; then " + run + "; else echo '" + missing + "'; fi" + then
	}
	// -i too, so the rc files that put claude on the PATH are read.
	spec.Args = []string{"-l", "-i", "-c", script}
	// The chosen folder, else its own one rather than the home directory,
	// so Claude Code asks to trust that once and doesn't get the run of ~.
	if dir := s.settings.Get().ClaudeCodeDir; dir != "" {
		if _, err := checkClaudeFolder(dir); err != nil {
			return fmt.Errorf("the Claude Code folder in Settings: %w", err)
		}
		spec.Dir = dir
	} else if dir, err := claudeWorkDir(filepath.Dir(s.mcpPath)); err == nil {
		spec.Dir = dir
	} else {
		log.Printf("claude code folder: %v", err)
	}
	return nil
}

// checkClaudeFolder expands a leading ~ and checks the folder exists. ""
// (the default folder) is fine.
func checkClaudeFolder(dir string) (string, error) {
	dir = strings.TrimSpace(dir)
	if dir == "" {
		return "", nil
	}
	if dir == "~" || strings.HasPrefix(dir, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		dir = filepath.Join(home, dir[1:])
	}
	if !filepath.IsAbs(dir) {
		return "", fmt.Errorf("%q isn't an absolute path", dir)
	}
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		return "", fmt.Errorf("%s isn't a folder", dir)
	}
	return filepath.Clean(dir), nil
}

const claudeMD = `# k8sman

You were started from k8sman, a Kubernetes desktop app, to help with the
cluster it shows. The k8sman MCP tools read that cluster (its current kube
context): start with list_problems, then get_resource, get_events and
get_logs on the objects involved. They can't read Secrets.

For security work, list_security_findings and get_security_finding show
k8sman's Security page. ignore_security_findings hides findings the user
accepts as intended: always give the reason, and ask first.

kubectl in this shell targets the same context ($K8SMAN_CONTEXT) with the
user's own credentials. Prefer reading; ask before changing anything in
the cluster.

This file is yours to edit: k8sman only writes it when it's missing.
`

// claudeWorkDir is <settings dir>/claude, with a CLAUDE.md the first time.
func claudeWorkDir(settingsDir string) (string, error) {
	dir := filepath.Join(settingsDir, "claude")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	f, err := os.OpenFile(filepath.Join(dir, "CLAUDE.md"), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err == nil {
		_, err = f.WriteString(claudeMD)
		if cerr := f.Close(); err == nil {
			err = cerr
		}
	} else if errors.Is(err, os.ErrExist) {
		err = nil
	}
	return dir, err
}
