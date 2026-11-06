package cluster

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"k8s.io/client-go/tools/clientcmd"
)

// KubeconfigInfo describes a kubeconfig file the user can switch to.
type KubeconfigInfo struct {
	Path           string   `json:"path"`
	Contexts       []string `json:"contexts"`
	CurrentContext string   `json:"currentContext,omitempty"`
	// Source says why the file is listed: "KUBECONFIG", "default", "kube-dir"
	// or "recent".
	Source string `json:"source,omitempty"`
	Error  string `json:"error,omitempty"`
}

// maxKubeconfigSize skips huge files when scanning ~/.kube.
const maxKubeconfigSize = 4 << 20

// InspectKubeconfig loads a kubeconfig file and lists its contexts. Problems
// are reported in Error rather than returned, so listings can show them.
func InspectKubeconfig(path string) KubeconfigInfo {
	info := KubeconfigInfo{Path: path, Contexts: []string{}}
	st, err := os.Stat(path)
	switch {
	case err != nil:
		info.Error = err.Error()
		return info
	case st.IsDir():
		info.Error = fmt.Sprintf("%s is a directory", path)
		return info
	case st.Size() > maxKubeconfigSize:
		info.Error = fmt.Sprintf("%s is too large to be a kubeconfig", path)
		return info
	}
	cfg, err := clientcmd.LoadFromFile(path)
	if err != nil {
		info.Error = fmt.Sprintf("not a valid kubeconfig: %v", err)
		return info
	}
	for name := range cfg.Contexts {
		info.Contexts = append(info.Contexts, name)
	}
	sort.Strings(info.Contexts)
	info.CurrentContext = cfg.CurrentContext
	return info
}

// SplitKubeconfigEnv splits a $KUBECONFIG value into its non-empty entries.
func SplitKubeconfigEnv(env string) []string {
	var out []string
	for _, p := range filepath.SplitList(env) {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// DefaultKubeconfig resolves what the default loading rules would use to a
// single file: the only $KUBECONFIG entry, or ~/.kube/config when
// $KUBECONFIG is unset. It returns "" when $KUBECONFIG lists several files
// (they are merged, so there is no single path).
func DefaultKubeconfig(home, env string) string {
	entries := SplitKubeconfigEnv(env)
	switch len(entries) {
	case 0:
		return filepath.Join(home, ".kube", "config")
	case 1:
		return entries[0]
	default:
		return ""
	}
}

// KubeconfigKey is the identity of a kubeconfig path: the same file gets
// the same key however it was spelled. "" (the default loading rules) is
// resolved as the loader does ($KUBECONFIG, else ~/.kube/config); `~/` is
// expanded; the path is made absolute and clean, and symlinks are resolved
// when the file exists. Several $KUBECONFIG files (merged) give one key
// from all of their resolved paths.
func KubeconfigKey(home, env, path string) string {
	if path == "" {
		if path = DefaultKubeconfig(home, env); path == "" {
			var parts []string
			for _, p := range SplitKubeconfigEnv(env) {
				parts = append(parts, resolveKubeconfigPath(home, p))
			}
			return strings.Join(parts, string(filepath.ListSeparator))
		}
	}
	return resolveKubeconfigPath(home, path)
}

func resolveKubeconfigPath(home, path string) string {
	path = filepath.Clean(ExpandHome(path, home))
	if !filepath.IsAbs(path) {
		if abs, err := filepath.Abs(path); err == nil {
			path = abs
		}
	}
	if real, err := filepath.EvalSymlinks(path); err == nil {
		path = real
	}
	return path
}

// DiscoverKubeconfigs lists candidate kubeconfig files, in display order:
// each $KUBECONFIG entry, ~/.kube/config, other files under ~/.kube that
// parse as kubeconfig with at least one context (cache dirs skipped), and
// recently used paths. Paths are deduplicated.
func DiscoverKubeconfigs(home, env string, recent []string) []KubeconfigInfo {
	var out []KubeconfigInfo
	seen := map[string]bool{}
	add := func(path, source string, requireContexts bool) {
		path = filepath.Clean(ExpandHome(path, home))
		if seen[path] {
			return
		}
		info := InspectKubeconfig(path)
		if requireContexts && (info.Error != "" || len(info.Contexts) == 0) {
			return
		}
		seen[path] = true
		info.Source = source
		out = append(out, info)
	}
	for _, p := range SplitKubeconfigEnv(env) {
		add(p, "KUBECONFIG", false)
	}
	kubeDir := filepath.Join(home, ".kube")
	if _, err := os.Stat(filepath.Join(kubeDir, "config")); err == nil {
		add(filepath.Join(kubeDir, "config"), "default", false)
	}
	for _, p := range scanKubeDir(kubeDir) {
		add(p, "kube-dir", true)
	}
	for _, p := range recent {
		add(p, "recent", false)
	}
	if out == nil {
		out = []KubeconfigInfo{}
	}
	return out
}

// scanKubeDir lists regular files in dir and one level of subdirectories,
// skipping hidden entries and client-go's cache dirs.
func scanKubeDir(dir string) []string {
	var out []string
	_ = filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			if p == dir {
				return err
			}
			return nil
		}
		rel, _ := filepath.Rel(dir, p)
		if p != dir && strings.HasPrefix(d.Name(), ".") {
			if d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		if d.IsDir() {
			if p == dir {
				return nil
			}
			if d.Name() == "cache" || d.Name() == "http-cache" || strings.Count(rel, string(filepath.Separator)) >= 1 {
				return fs.SkipDir
			}
			return nil
		}
		if d.Type().IsRegular() || d.Type()&fs.ModeSymlink != 0 {
			out = append(out, p)
		}
		if len(out) >= 100 {
			return fs.SkipAll
		}
		return nil
	})
	sort.Strings(out)
	return out
}

// ExpandHome turns a leading "~/" into the home directory.
func ExpandHome(path, home string) string {
	if path == "~" {
		return home
	}
	if strings.HasPrefix(path, "~/") {
		return filepath.Join(home, path[2:])
	}
	return path
}
