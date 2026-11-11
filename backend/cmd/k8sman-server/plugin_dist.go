package main

import (
	"bufio"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/Masterminds/semver/v3"

	"github.com/matty234/k8sman/backend/internal/plugins"
)

// Distribution commands (docs/PLUGINS.md §10): keygen, pack, index and
// verify-index, used by the k8sman-plugins repo's CI. Each returns 2 for a
// usage error.

// splitFlags separates `--name value` flags (those in names) from
// positional arguments, in any order.
func splitFlags(args []string, names ...string) (pos []string, flags map[string]string, err error) {
	flags = map[string]string{}
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case slices.Contains(names, a):
			if i+1 >= len(args) {
				return nil, nil, fmt.Errorf("%s needs a value", a)
			}
			flags[a] = args[i+1]
			i++
		case strings.HasPrefix(a, "-") && len(a) > 1:
			return nil, nil, fmt.Errorf("unknown flag %s", a)
		default:
			pos = append(pos, a)
		}
	}
	return pos, flags, nil
}

func fail(err error) int {
	fmt.Fprintln(os.Stderr, err)
	return 1
}

func pluginKeygen(args []string) int {
	if len(args) != 1 {
		return 2
	}
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return fail(err)
	}
	f, err := os.OpenFile(args[0], os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return fail(err)
	}
	_, err = f.WriteString(base64.StdEncoding.EncodeToString(priv) + "\n")
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return fail(err)
	}
	fmt.Println(base64.StdEncoding.EncodeToString(pub))
	return 0
}

// packPlugin validates dir, then writes its package into outDir.
func packPlugin(dir, outDir string) (m *plugins.Manifest, file string, data []byte, err error) {
	if pluginValidate([]string{dir}) != 0 {
		return nil, "", nil, fmt.Errorf("%s: validation failed", dir)
	}
	if m, err = plugins.ReadManifest(dir); err != nil {
		return nil, "", nil, err
	}
	if data, err = plugins.Pack(dir); err != nil {
		return nil, "", nil, fmt.Errorf("%s: %w", dir, err)
	}
	if err = os.MkdirAll(outDir, 0o755); err != nil {
		return nil, "", nil, err
	}
	file = filepath.Join(outDir, m.ID+"-"+m.Version+".tar.gz")
	return m, file, data, os.WriteFile(file, data, 0o644)
}

func sum(b []byte) string {
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

func pluginPack(args []string) int {
	pos, fl, err := splitFlags(args, "-o")
	if err != nil || len(pos) != 1 || fl["-o"] == "" {
		return 2
	}
	_, file, data, err := packPlugin(pos[0], fl["-o"])
	if err != nil {
		return fail(err)
	}
	fmt.Printf("%s\nsha256 %s\nsize %d\n", file, sum(data), len(data))
	return 0
}

// readRevoked reads id@version lines; # starts a comment.
func readRevoked(file string) ([]string, error) {
	f, err := os.Open(file)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	out := []string{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line, _, _ := strings.Cut(sc.Text(), "#")
		if line = strings.TrimSpace(line); line != "" {
			out = append(out, line)
		}
	}
	return out, sc.Err()
}

// pluginIndex packs every <root>/*/plugin.yaml into <out>/packages and
// writes index.json (and index.json.sig when K8SMAN_PLUGIN_INDEX_KEY is
// set). The index holds each plugin's current version, plus older versions
// from --previous whose package file is still in <out>/packages.
func pluginIndex(args []string) int {
	pos, fl, err := splitFlags(args, "-o", "--base-url", "--revoked", "--previous")
	if err != nil || len(pos) != 1 || fl["-o"] == "" {
		return 2
	}
	root, out := pos[0], fl["-o"]
	base := strings.TrimRight(fl["--base-url"], "/")
	rel := func(p string) string {
		if base == "" {
			return p
		}
		return base + "/" + p
	}
	manifests, _ := filepath.Glob(filepath.Join(root, "*", plugins.ManifestFile))
	slices.Sort(manifests)
	idx := plugins.Index{Revoked: []string{}, Plugins: []plugins.IndexEntry{}}
	for _, mf := range manifests {
		dir := filepath.Dir(mf)
		m, file, data, err := packPlugin(dir, filepath.Join(out, "packages"))
		if err != nil {
			return fail(err)
		}
		e := plugins.IndexEntry{
			ID: m.ID, Name: m.Name, Version: m.Version, Description: m.Description,
			Authors: m.Authors, Homepage: m.Homepage, Kinds: m.KindOrder,
			Permissions: m.Permissions, MinAppVersion: m.MinAppVersion,
			URL: rel("packages/" + filepath.Base(file)), SHA256: sum(data), Size: int64(len(data)),
		}
		if e.Kinds == nil {
			e.Kinds = []string{}
		}
		for _, c := range []struct {
			src, dst string
			field    *string
		}{
			{"icon.png", path.Join("icons", m.ID+".png"), &e.Icon},
			{"README.md", path.Join("readme", m.ID+".md"), &e.Readme},
		} {
			b, err := os.ReadFile(filepath.Join(dir, c.src))
			if errors.Is(err, os.ErrNotExist) {
				continue
			} else if err != nil {
				return fail(err)
			}
			dst := filepath.Join(out, filepath.FromSlash(c.dst))
			if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
				return fail(err)
			}
			if err := os.WriteFile(dst, b, 0o644); err != nil {
				return fail(err)
			}
			*c.field = rel(c.dst)
		}
		idx.Plugins = append(idx.Plugins, e)
	}
	if prev := fl["--previous"]; prev != "" {
		if b, err := os.ReadFile(prev); err == nil {
			var old plugins.Index
			if json.Unmarshal(b, &old) == nil {
				for _, e := range old.Plugins {
					p := filepath.Join(out, "packages", e.ID+"-"+e.Version+".tar.gz")
					if _, err := os.Stat(p); err != nil {
						continue
					}
					if !slices.ContainsFunc(idx.Plugins, func(n plugins.IndexEntry) bool { return n.ID == e.ID && n.Version == e.Version }) {
						idx.Plugins = append(idx.Plugins, e)
					}
				}
			}
		}
	}
	slices.SortStableFunc(idx.Plugins, func(a, b plugins.IndexEntry) int {
		if c := strings.Compare(a.ID, b.ID); c != 0 {
			return c
		}
		va, ea := semver.NewVersion(a.Version)
		vb, eb := semver.NewVersion(b.Version)
		if ea != nil || eb != nil {
			return strings.Compare(b.Version, a.Version)
		}
		return vb.Compare(va)
	})
	if f := fl["--revoked"]; f != "" {
		if idx.Revoked, err = readRevoked(f); err != nil {
			return fail(err)
		}
	}
	idx.GeneratedAt = time.Now().UTC().Truncate(time.Second)
	idx.Expires = idx.GeneratedAt.Add(plugins.IndexTTL)
	data, err := json.MarshalIndent(idx, "", "  ")
	if err != nil {
		return fail(err)
	}
	data = append(data, '\n')
	if err := os.WriteFile(filepath.Join(out, plugins.IndexFile), data, 0o644); err != nil {
		return fail(err)
	}
	sigFile := filepath.Join(out, plugins.IndexSigFile)
	if k := strings.TrimSpace(os.Getenv("K8SMAN_PLUGIN_INDEX_KEY")); k != "" {
		raw, err := base64.StdEncoding.DecodeString(k)
		if err != nil || len(raw) != ed25519.PrivateKeySize {
			return fail(errors.New("K8SMAN_PLUGIN_INDEX_KEY: want a base64 ed25519 private key"))
		}
		if err := os.WriteFile(sigFile, plugins.SignIndex(data, ed25519.PrivateKey(raw)), 0o644); err != nil {
			return fail(err)
		}
	} else {
		os.Remove(sigFile)
		fmt.Fprintln(os.Stderr, "warning: K8SMAN_PLUGIN_INDEX_KEY is not set; index.json is unsigned")
	}
	fmt.Printf("%s: %d plugin versions\n", filepath.Join(out, plugins.IndexFile), len(idx.Plugins))
	return 0
}

func pluginVerifyIndex(args []string) int {
	pos, fl, err := splitFlags(args, "--key")
	if err != nil || len(pos) != 1 || fl["--key"] == "" {
		return 2
	}
	dir := pos[0]
	pub, err := plugins.ParseIndexKey(fl["--key"])
	if err != nil {
		return fail(err)
	}
	data, err := os.ReadFile(filepath.Join(dir, plugins.IndexFile))
	if err != nil {
		return fail(err)
	}
	sig, err := os.ReadFile(filepath.Join(dir, plugins.IndexSigFile))
	if err != nil {
		return fail(err)
	}
	idx, err := plugins.VerifyIndex(data, sig, pub, time.Now())
	if err != nil {
		return fail(err)
	}
	bad := 0
	for _, e := range idx.Plugins {
		name := e.URL
		if u, err := url.Parse(e.URL); err == nil && u.Host != "" {
			name = "packages/" + path.Base(u.Path)
		}
		b, err := os.ReadFile(filepath.Join(dir, filepath.FromSlash(name)))
		switch {
		case err != nil:
			fmt.Fprintf(os.Stderr, "%s@%s: %v\n", e.ID, e.Version, err)
			bad++
		case sum(b) != e.SHA256 || int64(len(b)) != e.Size:
			fmt.Fprintf(os.Stderr, "%s@%s: package does not match the index (sha256 or size)\n", e.ID, e.Version)
			bad++
		}
	}
	if bad > 0 {
		return 1
	}
	fmt.Printf("ok: signature valid, expires %s, %d packages match\n", idx.Expires.Format(time.RFC3339), len(idx.Plugins))
	return 0
}
