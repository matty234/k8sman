package plugins

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

// The plugin index (docs/PLUGINS.md §10): index.json, written by
// `k8sman-server plugin index` in the k8sman-plugins repo's CI, and
// index.json.sig, an ed25519 signature over its exact bytes (base64, one
// line). The app verifies the signature with a public key built in before
// it reads anything else in the file.

// IndexFile and IndexSigFile are the names the index is published under.
const (
	IndexFile    = "index.json"
	IndexSigFile = "index.json.sig"
)

// IndexTTL is how long an index is valid for; CI re-signs weekly.
const IndexTTL = 30 * 24 * time.Hour

// Index is index.json.
type Index struct {
	GeneratedAt time.Time    `json:"generatedAt"`
	Expires     time.Time    `json:"expires"`
	Plugins     []IndexEntry `json:"plugins"`
	// Revoked is id@version; the app disables those on its next check.
	Revoked []string `json:"revoked"`
}

// IndexEntry is one plugin version in the index: what the directory and
// the app's Browse list show, and where the package is.
type IndexEntry struct {
	ID            string      `json:"id"`
	Name          string      `json:"name"`
	Version       string      `json:"version"`
	Description   string      `json:"description"`
	Authors       []string    `json:"authors,omitempty"`
	Homepage      string      `json:"homepage,omitempty"`
	Kinds         []string    `json:"kinds"`
	Permissions   Permissions `json:"permissions"`
	MinAppVersion string      `json:"minAppVersion,omitempty"`
	// URL of the .tar.gz, absolute or relative to index.json.
	URL    string `json:"url"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
	// Icon and Readme are URLs (relative to index.json) of the plugin's
	// icon.png and README.md, if it has them, for the directory pages.
	Icon   string `json:"icon,omitempty"`
	Readme string `json:"readme,omitempty"`
}

// SignIndex signs the exact bytes of index.json.
func SignIndex(data []byte, key ed25519.PrivateKey) []byte {
	return []byte(base64.StdEncoding.EncodeToString(ed25519.Sign(key, data)) + "\n")
}

// VerifyIndex checks sig against data with pub, then parses the index and
// checks that it hasn't expired at now.
func VerifyIndex(data, sig []byte, pub ed25519.PublicKey, now time.Time) (*Index, error) {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(sig)))
	if err != nil || len(pub) != ed25519.PublicKeySize || !ed25519.Verify(pub, data, raw) {
		return nil, errors.New("plugin index: bad signature")
	}
	var idx Index
	if err := json.Unmarshal(data, &idx); err != nil {
		return nil, fmt.Errorf("plugin index: %w", err)
	}
	if !now.Before(idx.Expires) {
		return nil, fmt.Errorf("plugin index: expired %s", idx.Expires.Format(time.RFC3339))
	}
	return &idx, nil
}

// ParseIndexKey reads a base64 ed25519 public key.
func ParseIndexKey(s string) (ed25519.PublicKey, error) {
	b, err := base64.StdEncoding.DecodeString(strings.TrimSpace(s))
	if err != nil || len(b) != ed25519.PublicKeySize {
		return nil, errors.New("plugin index key: want a base64 ed25519 public key")
	}
	return ed25519.PublicKey(b), nil
}
