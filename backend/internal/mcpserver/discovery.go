package mcpserver

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/matty234/k8sman/backend/internal/settings"
)

// Discovery is mcp.json: how `k8sman-server mcp` finds the running app.
// The backend writes it (mode 0600) while Claude Code access is on in
// Settings and removes it when that's turned off or the app quits. Token is
// a per-launch token the backend accepts only for read-only requests (see
// mcpAllowed in the server package).
type Discovery struct {
	Addr  string `json:"addr"`
	Token string `json:"token"`
	PID   int    `json:"pid"`
}

// DiscoveryPath is mcp.json next to the settings file.
func DiscoveryPath(settingsPath string) string {
	if settingsPath == "" {
		settingsPath = settings.DefaultPath()
	}
	return filepath.Join(filepath.Dir(settingsPath), "mcp.json")
}

// WriteDiscovery writes d to path atomically, readable only by the user.
func WriteDiscovery(path string, d Discovery) error {
	b, err := json.Marshal(d)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".mcp-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if err := f.Chmod(0o600); err != nil {
		f.Close()
		return err
	}
	if _, err := f.Write(b); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(f.Name(), path)
}

// RemoveDiscovery deletes path if it still holds token, so a second app
// instance's file survives the first one quitting.
func RemoveDiscovery(path, token string) {
	if d, err := ReadDiscovery(path); err == nil && d.Token == token {
		_ = os.Remove(path)
	}
}

// ErrNotRunning means there's no discovery file: the app isn't running, or
// Claude Code access is off.
var ErrNotRunning = errors.New("k8sman isn't running, or Claude Code access is off: open k8sman and turn on Settings ▸ General ▸ Claude Code")

// ReadDiscovery reads path.
func ReadDiscovery(path string) (Discovery, error) {
	var d Discovery
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return d, ErrNotRunning
	}
	if err != nil {
		return d, err
	}
	if err := json.Unmarshal(b, &d); err != nil {
		return d, fmt.Errorf("parse %s: %w", path, err)
	}
	if d.Addr == "" || d.Token == "" {
		return d, ErrNotRunning
	}
	return d, nil
}
