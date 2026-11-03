//go:build ignore

// Generates a throwaway EdDSA (ed25519) key pair in Sparkle's format, for
// the local update test only (tools/update-e2e.sh). Never use it for a real
// release: run Sparkle's generate_keys for that (docs/UPDATES.md).
//
//	go run tools/update-e2e/keygen.go <private-key-file>
//
// Writes the base64 32-byte seed (what `generate_keys -x` exports and
// `sign_update --ed-key-file` reads) with mode 0600, and prints the base64
// public key (the SUPublicEDKey value).
package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"os"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: keygen.go <private-key-file>")
		os.Exit(2)
	}
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		panic(err)
	}
	seed := base64.StdEncoding.EncodeToString(priv.Seed())
	if err := os.WriteFile(os.Args[1], []byte(seed+"\n"), 0o600); err != nil {
		panic(err)
	}
	fmt.Println(base64.StdEncoding.EncodeToString(pub))
}
