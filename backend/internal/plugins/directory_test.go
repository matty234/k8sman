package plugins

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/matty234/k8sman/backend/internal/settings"
)

// TestDirectoryInstall fetches a signed index from a test server and
// installs from it: a package whose sha256 doesn't match and one with a
// path escaping its folder are refused; a good one asks for consent, then
// installs and loads without dev mode.
func TestDirectoryInstall(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(nil)
	targz := func(name, body string) []byte {
		var buf bytes.Buffer
		gz := gzip.NewWriter(&buf)
		tw := tar.NewWriter(gz)
		_ = tw.WriteHeader(&tar.Header{Name: name, Mode: 0o644, Size: int64(len(body)), Typeflag: tar.TypeReg})
		_, _ = tw.Write([]byte(body))
		_ = tw.Close()
		_ = gz.Close()
		return buf.Bytes()
	}
	pkgs := map[string][]byte{
		"good.tar.gz":  targz("demo/plugin.yaml", demoManifest),
		"evil.tar.gz":  targz("../escape.yaml", demoManifest),
		"wrong.tar.gz": targz("demo/plugin.yaml", demoManifest),
		// Updates: 1.1.0 asks for another command, 1.2.0 for nothing new.
		"perms.tar.gz": targz("demo/plugin.yaml", strings.NewReplacer("version: 1.0.0", "version: 1.1.0", "commands: [widgetctl]", "commands: [widgetctl, otherctl]").Replace(demoManifest)),
		"same.tar.gz":  targz("demo/plugin.yaml", strings.Replace(demoManifest, "version: 1.0.0", "version: 1.2.0", 1)),
	}
	entry := func(id, pkg, sum string) IndexEntry {
		return IndexEntry{ID: id, Name: id, Version: "1.0.0", Permissions: Permissions{Read: []string{"example.com/Widget"}, Commands: []string{"widgetctl"}},
			URL: "pkg/" + pkg, SHA256: sum, Size: int64(len(pkgs[pkg]))}
	}
	sha := func(b []byte) string { s := sha256.Sum256(b); return hex.EncodeToString(s[:]) }
	idx := Index{GeneratedAt: time.Now(), Expires: time.Now().Add(IndexTTL), Plugins: []IndexEntry{
		entry("demo", "good.tar.gz", sha(pkgs["good.tar.gz"])),
		entry("evil", "evil.tar.gz", sha(pkgs["evil.tar.gz"])),
		entry("wrong", "wrong.tar.gz", strings.Repeat("0", 64)),
	}}
	var data atomic.Pointer[[]byte]
	publish := func() {
		b, _ := json.Marshal(idx)
		data.Store(&b)
	}
	publish()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/index.json":
			_, _ = w.Write(*data.Load())
		case r.URL.Path == "/index.json.sig":
			_, _ = w.Write(SignIndex(*data.Load(), priv))
		case strings.HasPrefix(r.URL.Path, "/pkg/"):
			_, _ = w.Write(pkgs[strings.TrimPrefix(r.URL.Path, "/pkg/")])
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	st, _ := settings.Open(filepath.Join(t.TempDir(), "settings.json"))
	h := NewHost(Options{InstalledDir: filepath.Join(t.TempDir(), "plugins"), Settings: st})
	d := NewDirectory(h, srv.URL+"/index.json", base64.StdEncoding.EncodeToString(pub))
	ctx := context.Background()

	if s := d.State(ctx, 0, nil); s.Status != DirOK || len(s.Plugins) != 3 || s.Plugins[0].State != "install" {
		t.Fatalf("state: %+v", s)
	}
	t.Run("sha mismatch", func(t *testing.T) {
		if _, err := d.Install(ctx, "wrong", ""); err == nil || !strings.Contains(err.Error(), "sha256") {
			t.Fatalf("err = %v", err)
		}
	})
	t.Run("path traversal", func(t *testing.T) {
		if _, err := d.Install(ctx, "evil", ""); err == nil || !strings.Contains(err.Error(), "unsafe path") {
			t.Fatalf("err = %v", err)
		}
	})
	t.Run("install", func(t *testing.T) {
		pend, err := d.Install(ctx, "demo", "")
		if err != nil || pend.Installed || pend.PermissionsHash == "" {
			t.Fatalf("pending = %+v, %v", pend, err)
		}
		if pend, err = d.Install(ctx, "demo", pend.PermissionsHash); err != nil || !pend.Installed {
			t.Fatalf("install = %+v, %v", pend, err)
		}
		list := h.List(nil)
		if len(list) != 1 || list[0].Source != SourceDirectory || !list[0].Active || !list[0].Consented || list[0].Unpacked {
			t.Fatalf("list = %+v", list)
		}
		if s := d.State(ctx, IndexFresh, nil); s.Plugins[0].State != "installed" {
			t.Fatalf("state after install: %+v", s.Plugins[0])
		}
	})
	// Automatic updates install only what asks for no new permissions,
	// and only with the setting on.
	t.Run("auto-update", func(t *testing.T) {
		version := func() string { return st.Get().Plugins.Installed["demo"].Version }
		perms := entry("demo", "perms.tar.gz", sha(pkgs["perms.tar.gz"]))
		perms.Version, perms.Permissions.Commands = "1.1.0", []string{"widgetctl", "otherctl"}
		idx.Plugins = append(idx.Plugins, perms)
		publish()
		d.State(ctx, 0, nil)
		_ = st.UpdatePlugins(func(p *settings.PluginSettings) { p.AutoUpdate = true })
		if got := d.AutoUpdate(ctx); len(got) != 0 || version() != "1.0.0" {
			t.Fatalf("new permissions updated without consent: %v, %s", got, version())
		}
		same := entry("demo", "same.tar.gz", sha(pkgs["same.tar.gz"]))
		same.Version = "1.2.0"
		idx.Plugins = append(idx.Plugins, same)
		publish()
		d.State(ctx, 0, nil)
		_ = st.UpdatePlugins(func(p *settings.PluginSettings) { p.AutoUpdate = false })
		if got := d.AutoUpdate(ctx); len(got) != 0 || version() != "1.0.0" {
			t.Fatalf("updated with the setting off: %v, %s", got, version())
		}
		_ = st.UpdatePlugins(func(p *settings.PluginSettings) { p.AutoUpdate = true })
		if got := d.AutoUpdate(ctx); len(got) != 1 || version() != "1.2.0" || h.List(nil)[0].Version != "1.2.0" {
			t.Fatalf("auto-update = %v, %s", got, version())
		}
	})
}
