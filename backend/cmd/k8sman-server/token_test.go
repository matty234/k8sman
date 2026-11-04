package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/matty234/k8sman/backend/internal/server"
)

func TestAuthTokenFromEnvIsClearedAfterReading(t *testing.T) {
	want := strings.Repeat("a", 64)
	t.Setenv(server.AuthTokenEnv, want)
	got, err := authToken()
	if err != nil || got != want {
		t.Fatalf("%q %v", got, err)
	}
	if _, ok := os.LookupEnv(server.AuthTokenEnv); ok {
		t.Fatal("token left in the environment for child processes")
	}
}

func TestAuthTokenRejectsShortEnvToken(t *testing.T) {
	t.Setenv(server.AuthTokenEnv, "short")
	if _, err := authToken(); err == nil {
		t.Fatal("short token accepted")
	}
}

func TestWriteDevTokenIsPrivate(t *testing.T) {
	path := filepath.Join(t.TempDir(), "k8sman", "dev-token")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	// An existing, world-readable file is replaced, not reused.
	if err := os.WriteFile(path, []byte("old"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := writeDevToken(path, "tok"); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", fi.Mode().Perm())
	}
	if b, _ := os.ReadFile(path); string(b) != "tok\n" {
		t.Fatalf("%q", b)
	}
}
