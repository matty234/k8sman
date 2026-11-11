package main

import (
	"bytes"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Packing is deterministic and leaves fixtures out; an index built from it
// verifies with the key that signed it, and not once a package changes.
func TestPluginPackAndIndexRoundtrip(t *testing.T) {
	root := t.TempDir()
	src := filepath.Join("..", "..", "..", "examples", "plugins", "cert-manager")
	dst := filepath.Join(root, "plugins", "cert-manager")
	if err := os.CopyFS(dst, os.DirFS(src)); err != nil {
		t.Fatal(err)
	}
	for i, out := range []string{"a", "b"} {
		if rc := pluginPack([]string{dst, "-o", filepath.Join(root, out)}); rc != 0 {
			t.Fatalf("pack %d: exit %d", i, rc)
		}
	}
	pkgA, _ := os.ReadFile(filepath.Join(root, "a", "cert-manager-1.0.0.tar.gz"))
	pkgB, _ := os.ReadFile(filepath.Join(root, "b", "cert-manager-1.0.0.tar.gz"))
	if len(pkgA) == 0 || !bytes.Equal(pkgA, pkgB) {
		t.Fatal("packing twice gave different bytes")
	}

	keyFile := filepath.Join(root, "key")
	if pluginKeygen([]string{keyFile}) != 0 || pluginKeygen([]string{keyFile}) == 0 {
		t.Fatal("keygen must write once and refuse to overwrite")
	}
	priv, _ := os.ReadFile(keyFile)
	t.Setenv("K8SMAN_PLUGIN_INDEX_KEY", strings.TrimSpace(string(priv)))
	site := filepath.Join(root, "site")
	if rc := pluginIndex([]string{filepath.Join(root, "plugins"), "-o", site}); rc != 0 {
		t.Fatalf("index: exit %d", rc)
	}
	pub := pubFromPrivate(t, strings.TrimSpace(string(priv)))
	if rc := pluginVerifyIndex([]string{site, "--key", pub}); rc != 0 {
		t.Fatalf("verify-index: exit %d", rc)
	}
	pkg := filepath.Join(site, "packages", "cert-manager-1.0.0.tar.gz")
	if err := os.WriteFile(pkg, append(pkgA, 0), 0o644); err != nil {
		t.Fatal(err)
	}
	if rc := pluginVerifyIndex([]string{site, "--key", pub}); rc == 0 {
		t.Fatal("verify-index accepted a changed package")
	}
}

// pubFromPrivate is the public half of a base64 ed25519 private key (its
// last 32 bytes), base64-encoded.
func pubFromPrivate(t *testing.T, priv string) string {
	t.Helper()
	raw, err := base64.StdEncoding.DecodeString(priv)
	if err != nil || len(raw) != 64 {
		t.Fatal("bad private key")
	}
	return base64.StdEncoding.EncodeToString(raw[32:])
}
