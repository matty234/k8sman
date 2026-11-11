package plugins

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/Masterminds/semver/v3"

	"github.com/matty234/k8sman/backend/internal/settings"
)

// The plugin directory (docs/PLUGINS.md §10): a signed index of plugin
// packages. The backend fetches and verifies the index, downloads a
// package, checks it against the index, unpacks it into a staging folder,
// validates it and, once the user agrees to its permissions, renames it
// into <settings dir>/plugins/<id> and records it in settings.json
// (plugins.installed).

// DefaultIndexURL is where the plugin directory's index is published;
// its signature is at the same URL + ".sig".
const DefaultIndexURL = "https://matty234.github.io/k8sman-plugins/" + IndexFile

// IndexPublicKey is the index signing key (base64 ed25519; the private
// half is the k8sman-plugins CI secret). Empty: the
// directory isn't configured in this build.
var IndexPublicKey = "TcsP0f/fXzh3ZjUnqVHoyyfYtzbjp358OIjp2DD1kms="

// Limits on what the directory downloads and unpacks.
const (
	maxIndexSize    = 4 << 20
	maxSigSize      = 4 << 10
	maxPackageSize  = 1 << 20
	maxUnpackedSize = 8 << 20
	// indexFresh is how long a fetched index is reused for installs.
	indexFresh = 10 * time.Minute
	// checkEvery is how often installed directory plugins are checked
	// for updates and revocations.
	checkEvery = 24 * time.Hour
	// NoticeFresh is how old an index the app's notices (suggestions for
	// a context, updates) reuse: a context switch doesn't fetch again.
	NoticeFresh = checkEvery
	// IndexFresh is how old an index Browse reuses.
	IndexFresh = indexFresh
)

// packageExts are the file types a package may hold.
var packageExts = []string{".yaml", ".md", ".png", ".svg"}

// Directory states (DirectoryState.Status).
const (
	DirOK            = "ok"
	DirNotConfigured = "not-configured"
	DirOffline       = "offline" // the fetch failed (a cached index may still list)
	DirExpired       = "expired"
	DirInvalid       = "invalid" // bad signature or unreadable
)

// Directory installs, updates and uninstalls plugins from the plugin
// directory into the host's installed folder.
type Directory struct {
	host   *Host
	url    string
	key    ed25519.PublicKey
	client *http.Client
	now    func() time.Time

	mu      sync.Mutex
	idx     *Index
	fetched time.Time
	checked time.Time
	status  string
	lastErr string
	staged  map[string]*staged

	// installMu serialises installs and uninstalls.
	installMu sync.Mutex
	// migrateMu: one Migrate at a time (migrate.go).
	migrateMu sync.Mutex
}

// staged is a validated package waiting for consent.
type staged struct {
	tmp   string // the staging folder (removed after)
	root  string // the plugin folder in it
	entry IndexEntry
	hash  string
}

// NewDirectory makes a directory over indexURL ("" = DefaultIndexURL),
// verified with key (base64; "" = not configured).
func NewDirectory(h *Host, indexURL, key string) *Directory {
	if indexURL == "" {
		indexURL = DefaultIndexURL
	}
	d := &Directory{host: h, url: indexURL, client: &http.Client{Timeout: 30 * time.Second}, now: time.Now, staged: map[string]*staged{}}
	if key != "" {
		if k, err := ParseIndexKey(key); err == nil {
			d.key = k
		} else {
			log.Printf("plugins: directory: %v", err)
		}
	}
	// Leftovers of an install the app quit during.
	if dir := h.Opts().InstalledDir; dir != "" {
		for _, pat := range []string{".staging-*", ".*-old-*"} {
			old, _ := filepath.Glob(filepath.Join(dir, pat))
			for _, o := range old {
				_ = os.RemoveAll(o)
			}
		}
	}
	return d
}

// DirectoryFromEnv is the app's directory: the built-in URL and key, or
// $K8SMAN_PLUGIN_INDEX_URL and $K8SMAN_PLUGIN_INDEX_KEY (to test a
// directory of your own).
func DirectoryFromEnv(h *Host) *Directory {
	u, k := os.Getenv("K8SMAN_PLUGIN_INDEX_URL"), os.Getenv("K8SMAN_PLUGIN_INDEX_KEY")
	if k == "" {
		k = IndexPublicKey
	}
	return NewDirectory(h, u, k)
}

// DirectoryPlugin is one plugin in Browse: its newest version this app
// can install, and how it relates to what is installed.
type DirectoryPlugin struct {
	IndexEntry
	// State: builtin (bundled with the app), installed, update (a newer
	// version is available, or a formerly bundled plugin still running
	// from the app's legacy copy needs the user's OK for the directory
	// version's permissions), install, or incompatible (needs a newer app;
	// Reason says so).
	State            string `json:"state"`
	Reason           string `json:"reason,omitempty"`
	InstalledVersion string `json:"installedVersion,omitempty"`
	PermissionsHash  string `json:"permissionsHash"`
	// PermissionsChanged: an update asks for other permissions than the
	// installed version (it needs consent again).
	PermissionsChanged bool `json:"permissionsChanged,omitempty"`
	// Matched are the plugin's kinds the current cluster serves (given a
	// served lookup); a suggestion has at least one.
	Matched []string `json:"matched,omitempty"`
}

// DirectoryState is GET /api/plugins/directory.
type DirectoryState struct {
	Status    string            `json:"status"`
	Error     string            `json:"error,omitempty"`
	URL       string            `json:"url"`
	CheckedAt *time.Time        `json:"checkedAt,omitempty"`
	Plugins   []DirectoryPlugin `json:"plugins"`
	// Updates are the installed directory plugins with a newer version.
	Updates []DirectoryPlugin `json:"updates"`
	// Suggested are the plugins to install for the current cluster: it
	// serves at least one of their kinds, and they are compatible, not
	// installed, built in or loaded unpacked. Nothing installs by itself.
	Suggested []DirectoryPlugin `json:"suggested"`
}

// Pending is an install waiting for consent, or one just done.
type Pending struct {
	ID              string      `json:"id"`
	Name            string      `json:"name"`
	Version         string      `json:"version"`
	Description     string      `json:"description,omitempty"`
	Authors         []string    `json:"authors,omitempty"`
	Permissions     Permissions `json:"permissions"`
	PermissionsHash string      `json:"permissionsHash"`
	// Update: another version is installed now.
	Update bool `json:"update,omitempty"`
	// Installed: done (no consent needed, or given).
	Installed bool `json:"installed,omitempty"`
}

func (d *Directory) settings() settings.PluginSettings { return d.host.settings() }

// get fetches u, refusing more than limit bytes.
func (d *Directory) get(ctx context.Context, u string, limit int64) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	resp, err := d.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GET %s: %s", u, resp.Status)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > limit {
		return nil, fmt.Errorf("GET %s: larger than %d bytes", u, limit)
	}
	return b, nil
}

// index returns the verified index: the cached one if fetched within
// maxAge, else a fresh fetch. A failed fetch falls back to the cached
// index while it hasn't expired (status offline).
func (d *Directory) index(ctx context.Context, maxAge time.Duration) (*Index, string, string) {
	if d.key == nil {
		return nil, DirNotConfigured, "the plugin directory isn't configured in this build"
	}
	d.mu.Lock()
	if d.idx != nil && d.now().Sub(d.fetched) < maxAge && d.now().Before(d.idx.Expires) {
		idx, st, e := d.idx, d.status, d.lastErr
		d.mu.Unlock()
		return idx, st, e
	}
	// The notices don't retry a failed fetch on every context switch.
	if d.idx == nil && maxAge > indexFresh && d.status != "" && d.status != DirOK && d.now().Sub(d.checked) < indexFresh {
		st, e := d.status, d.lastErr
		d.mu.Unlock()
		return nil, st, e
	}
	d.mu.Unlock()

	idx, status, err := d.fetch(ctx)
	d.mu.Lock()
	d.checked = d.now()
	if err != nil {
		defer d.mu.Unlock()
		d.status, d.lastErr = status, err.Error()
		if d.idx != nil && d.now().Before(d.idx.Expires) {
			return d.idx, status, d.lastErr
		}
		return nil, status, d.lastErr
	}
	d.idx, d.fetched, d.status, d.lastErr = idx, d.now(), DirOK, ""
	d.mu.Unlock()
	d.applyRevocations(idx)
	return idx, DirOK, ""
}

// fetch downloads index.json and its signature and verifies the
// signature before reading anything in the index.
func (d *Directory) fetch(ctx context.Context) (*Index, string, error) {
	data, err := d.get(ctx, d.url, maxIndexSize)
	if err != nil {
		return nil, DirOffline, err
	}
	sig, err := d.get(ctx, d.url+".sig", maxSigSize)
	if err != nil {
		return nil, DirOffline, err
	}
	// The zero time passes VerifyIndex's expiry check, so an expired
	// index can say so (below) rather than read as a bad one.
	idx, err := VerifyIndex(data, sig, d.key, time.Time{})
	if err != nil {
		return nil, DirInvalid, err
	}
	if !d.now().Before(idx.Expires) {
		return nil, DirExpired, fmt.Errorf("the plugin index expired on %s", idx.Expires.Format("2 Jan 2006"))
	}
	return idx, DirOK, nil
}

// applyRevocations turns off installed versions the index revokes (and
// back on, should a revocation be withdrawn).
func (d *Directory) applyRevocations(idx *Index) {
	changed := false
	err := d.host.opts.Settings.UpdatePlugins(func(p *settings.PluginSettings) {
		for id, rec := range p.Installed {
			why := ""
			if slices.Contains(idx.Revoked, id+"@"+rec.Version) {
				why = "Version " + rec.Version + " was withdrawn from the plugin directory."
			}
			if why != rec.Revoked {
				rec.Revoked = why
				p.Installed[id] = rec
				changed = true
			}
		}
	})
	if err != nil {
		log.Printf("plugins: directory: %v", err)
	}
	if changed {
		d.host.Bump()
	}
}

// best is plugin id's newest version this app can install: not revoked,
// and minAppVersion at most AppVersion. When none can, newest is the
// newest version anyway (and reason says why), for Browse.
func best(idx *Index, id string) (e *IndexEntry, newest *IndexEntry, reason string) {
	var have *semver.Version
	if AppVersion != "" {
		have, _ = semver.NewVersion(AppVersion)
	}
	newer := func(a, b *IndexEntry) bool {
		if b == nil {
			return true
		}
		va, err1 := semver.NewVersion(a.Version)
		vb, err2 := semver.NewVersion(b.Version)
		return err1 == nil && (err2 != nil || va.GreaterThan(vb))
	}
	for i := range idx.Plugins {
		c := &idx.Plugins[i]
		if c.ID != id || slices.Contains(idx.Revoked, c.ID+"@"+c.Version) {
			continue
		}
		if newer(c, newest) {
			newest = c
		}
		if c.MinAppVersion != "" && have != nil {
			if need, err := semver.NewVersion(c.MinAppVersion); err != nil || need.GreaterThan(have) {
				reason = "Needs k8sman " + c.MinAppVersion + " or later."
				continue
			}
		}
		if newer(c, e) {
			e = c
		}
	}
	if e != nil {
		reason = ""
	}
	return e, newest, reason
}

// versionNewer reports whether version a is newer than b.
func versionNewer(a, b string) bool {
	va, err1 := semver.NewVersion(a)
	vb, err2 := semver.NewVersion(b)
	return err1 == nil && err2 == nil && va.GreaterThan(vb)
}

// State lists the directory for Browse, with the updates available and,
// given served (the kind keys the current cluster serves; nil = unknown),
// the plugins suggested for the cluster. It reuses an index fetched
// within maxAge (0 = fetch again: the Plugins page opening).
func (d *Directory) State(ctx context.Context, maxAge time.Duration, served func(string) bool) DirectoryState {
	idx, status, errText := d.index(ctx, maxAge)
	out := DirectoryState{Status: status, Error: errText, URL: d.url, Plugins: []DirectoryPlugin{}, Updates: []DirectoryPlugin{}, Suggested: []DirectoryPlugin{}}
	d.mu.Lock()
	if !d.checked.IsZero() {
		t := d.checked
		out.CheckedAt = &t
	}
	d.mu.Unlock()
	if idx == nil {
		return out
	}
	st := d.settings()
	var ids []string
	for _, e := range idx.Plugins {
		if !slices.Contains(ids, e.ID) {
			ids = append(ids, e.ID)
		}
	}
	slices.Sort(ids)
	for _, id := range ids {
		e, newest, reason := best(idx, id)
		if newest == nil {
			continue // every version revoked
		}
		dp := DirectoryPlugin{IndexEntry: *newest, State: "install"}
		if e != nil {
			dp.IndexEntry = *e
		}
		dp.Icon, dp.Readme, dp.URL = d.resolve(dp.Icon), d.resolve(dp.Readme), d.resolve(dp.URL)
		dp.PermissionsHash = permissionsHash(id, dp.Permissions)
		rec, installed := st.Installed[id]
		bundled, unpacked := d.loaded(id)
		legacyVersion := d.host.legacyLoaded(id)
		moving := !installed && st.Migrated[id] == settings.MigratedConsent && legacyVersion != ""
		if served != nil {
			for _, k := range dp.Kinds {
				if served(k) {
					dp.Matched = append(dp.Matched, k)
				}
			}
		}
		switch {
		case bundled:
			dp.State = "builtin"
		case installed:
			dp.InstalledVersion = rec.Version
			dp.State = "installed"
			if e != nil && versionNewer(e.Version, rec.Version) {
				dp.State = "update"
				dp.PermissionsChanged = dp.PermissionsHash != rec.PermissionsHash
			}
		case e == nil:
			dp.State, dp.Reason = "incompatible", reason
		case moving:
			// Migrate didn't install it: other permissions than the
			// bundled copy's. Offered as an update that asks first.
			dp.State, dp.InstalledVersion, dp.PermissionsChanged = "update", legacyVersion, true
		}
		out.Plugins = append(out.Plugins, dp)
		if dp.State == "update" {
			out.Updates = append(out.Updates, dp)
		}
		// "install" is neither installed, built in nor incompatible.
		if (dp.State == "install" || moving) && !unpacked && len(dp.Matched) > 0 {
			out.Suggested = append(out.Suggested, dp)
		}
	}
	return out
}

// resolve makes u (relative to index.json) absolute.
func (d *Directory) resolve(u string) string {
	if u == "" {
		return ""
	}
	base, err1 := url.Parse(d.url)
	ref, err2 := url.Parse(u)
	if err1 != nil || err2 != nil {
		return u
	}
	return base.ResolveReference(ref).String()
}

// isBundled reports whether id is a plugin built into the app.
func (d *Directory) isBundled(id string) bool {
	bundled, _ := d.loaded(id)
	return bundled
}

// loaded reports whether plugin id is built into the app (a legacy copy
// doesn't count: it is to be installed from the directory), and whether
// one is loaded unpacked (a dev or --plugin-dev folder, or a folder in
// the installed folder without a directory record).
func (d *Directory) loaded(id string) (bundled, unpacked bool) {
	d.host.mu.RLock()
	defer d.host.mu.RUnlock()
	for _, p := range d.host.plugins {
		if p.ID() != id {
			continue
		}
		switch p.source {
		case SourceBundled:
			bundled = bundled || !p.legacy
		case SourceDev, SourceFlag, SourceInstalled:
			unpacked = true
		}
	}
	return bundled, unpacked
}

// Install installs (or updates) plugin id from the directory. It
// downloads and validates the package, then: if consentHash is the
// package's permissions hash, renames it into place; otherwise it keeps
// it staged and returns what to ask the user (Installed false).
func (d *Directory) Install(ctx context.Context, id, consentHash string) (*Pending, error) {
	d.installMu.Lock()
	defer d.installMu.Unlock()
	if d.host.opts.InstalledDir == "" {
		return nil, errors.New("this backend has no installed-plugins folder")
	}
	if d.isBundled(id) {
		return nil, fmt.Errorf("%s is built in", id)
	}
	idx, _, errText := d.index(ctx, indexFresh)
	if idx == nil {
		return nil, errors.New(errText)
	}
	e, _, reason := best(idx, id)
	if e == nil {
		if reason == "" {
			reason = "it isn't in the plugin directory"
		}
		return nil, fmt.Errorf("can't install %s: %s", id, reason)
	}
	rec, installed := d.settings().Installed[id]
	target := filepath.Join(d.host.opts.InstalledDir, id)
	if !installed {
		if _, err := os.Stat(target); err == nil {
			return nil, fmt.Errorf("%s already holds an unpacked plugin; remove it first", target)
		}
	}

	d.mu.Lock()
	s := d.staged[id]
	d.mu.Unlock()
	if s == nil || s.entry.Version != e.Version || s.entry.SHA256 != e.SHA256 {
		if s != nil {
			_ = os.RemoveAll(s.tmp)
		}
		var err error
		if s, err = d.stage(ctx, *e); err != nil {
			return nil, err
		}
		d.mu.Lock()
		d.staged[id] = s
		d.mu.Unlock()
	}
	pend := &Pending{ID: id, Name: e.Name, Version: e.Version, Description: e.Description, Authors: e.Authors, Permissions: e.Permissions,
		PermissionsHash: s.hash, Update: installed}
	if consentHash != s.hash {
		return pend, nil
	}

	// Into place: the old version aside, the new one in, the old removed.
	old := ""
	if installed {
		if _, err := os.Stat(target); err == nil {
			old = filepath.Join(d.host.opts.InstalledDir, "."+id+"-old-"+rec.Version)
			_ = os.RemoveAll(old)
			if err := os.Rename(target, old); err != nil {
				return nil, err
			}
		}
	}
	if err := os.Rename(s.root, target); err != nil {
		if old != "" {
			_ = os.Rename(old, target)
		}
		return nil, err
	}
	d.mu.Lock()
	delete(d.staged, id)
	d.mu.Unlock()
	_ = os.RemoveAll(s.tmp)
	if old != "" {
		_ = os.RemoveAll(old)
	}
	err := d.host.opts.Settings.UpdatePlugins(func(p *settings.PluginSettings) {
		if p.Installed == nil {
			p.Installed = map[string]settings.InstalledPlugin{}
		}
		p.Installed[id] = settings.InstalledPlugin{Version: e.Version, SHA256: e.SHA256, PermissionsHash: s.hash}
		if p.Consent == nil {
			p.Consent = map[string]string{}
		}
		p.Consent[id] = s.hash
	})
	if err != nil {
		return nil, err
	}
	d.host.Reload()
	pend.Installed = true
	return pend, nil
}

// stage downloads e's package, checks it against the index, unpacks it
// into a staging folder in the installed folder and validates it.
func (d *Directory) stage(ctx context.Context, e IndexEntry) (*staged, error) {
	if e.Size <= 0 || e.Size > maxPackageSize {
		return nil, fmt.Errorf("%s %s: package size %d is out of range", e.ID, e.Version, e.Size)
	}
	data, err := d.get(ctx, d.resolve(e.URL), e.Size)
	if err != nil {
		return nil, err
	}
	sum := sha256.Sum256(data)
	if !strings.EqualFold(hex.EncodeToString(sum[:]), e.SHA256) {
		return nil, fmt.Errorf("%s %s: the package doesn't match the index (sha256)", e.ID, e.Version)
	}
	if err := os.MkdirAll(d.host.opts.InstalledDir, 0o755); err != nil {
		return nil, err
	}
	tmp, err := os.MkdirTemp(d.host.opts.InstalledDir, ".staging-"+e.ID+"-")
	if err != nil {
		return nil, err
	}
	s, err := func() (*staged, error) {
		if err := unpack(data, tmp); err != nil {
			return nil, fmt.Errorf("%s %s: %w", e.ID, e.Version, err)
		}
		root := tmp
		if _, err := os.Stat(filepath.Join(tmp, ManifestFile)); err != nil {
			// One top-level folder holding the plugin.
			root = filepath.Join(tmp, e.ID)
			if _, err := os.Stat(filepath.Join(root, ManifestFile)); err != nil {
				return nil, fmt.Errorf("%s %s: the package has no %s", e.ID, e.Version, ManifestFile)
			}
		}
		p := loadPlugin(root, SourceDirectory, true)
		if p.failed || p.m == nil {
			msg := "doesn't load"
			if len(p.diags) > 0 {
				msg = p.diags[0].Message
			}
			return nil, fmt.Errorf("%s %s: %s", e.ID, e.Version, msg)
		}
		hash := p.PermissionsHash()
		if p.m.ID != e.ID || p.m.Version != e.Version || hash != permissionsHash(e.ID, e.Permissions) {
			return nil, fmt.Errorf("%s %s: the package doesn't match the index (id, version or permissions)", e.ID, e.Version)
		}
		if root == tmp {
			// Rename the plugin folder, not the staging folder, into place.
			root = filepath.Join(tmp, e.ID)
			if err := os.Mkdir(root, 0o755); err != nil {
				return nil, err
			}
			entries, _ := os.ReadDir(tmp)
			for _, en := range entries {
				if en.Name() != e.ID {
					if err := os.Rename(filepath.Join(tmp, en.Name()), filepath.Join(root, en.Name())); err != nil {
						return nil, err
					}
				}
			}
		}
		return &staged{tmp: tmp, root: root, entry: e, hash: hash}, nil
	}()
	if err != nil {
		_ = os.RemoveAll(tmp)
		return nil, err
	}
	return s, nil
}

// unpack extracts a .tar.gz package into dir: regular files of the
// package types and folders only, no absolute paths, no "..", no links.
func unpack(data []byte, dir string) error {
	gz, err := gzip.NewReader(bytes.NewReader(data))
	if err != nil {
		return err
	}
	tr := tar.NewReader(io.LimitReader(gz, maxUnpackedSize))
	for {
		h, err := tr.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return fmt.Errorf("unreadable package: %w", err)
		}
		name := strings.TrimPrefix(h.Name, "./")
		if name == "" || name == "." {
			continue
		}
		if path.IsAbs(name) || strings.Contains(name, `\`) || slices.Contains(strings.Split(name, "/"), "..") {
			return fmt.Errorf("the package has an unsafe path %q", h.Name)
		}
		name = path.Clean(name)
		dst := filepath.Join(dir, filepath.FromSlash(name))
		switch h.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(dst, 0o755); err != nil {
				return err
			}
		case tar.TypeReg:
			if !slices.Contains(packageExts, strings.ToLower(path.Ext(name))) {
				return fmt.Errorf("the package has a file of a type plugins can't hold: %q", h.Name)
			}
			if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
				return err
			}
			f, err := os.OpenFile(dst, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
			if err != nil {
				return err
			}
			_, err = io.Copy(f, tr)
			if cerr := f.Close(); err == nil {
				err = cerr
			}
			if err != nil {
				return err
			}
		default:
			return fmt.Errorf("the package has a link or special file %q", h.Name)
		}
	}
}

// Uninstall removes plugin id installed from the directory.
func (d *Directory) Uninstall(id string) error {
	d.installMu.Lock()
	defer d.installMu.Unlock()
	if _, ok := d.settings().Installed[id]; !ok || d.host.opts.InstalledDir == "" {
		return fmt.Errorf("%s wasn't installed from the plugin directory", id)
	}
	if err := os.RemoveAll(filepath.Join(d.host.opts.InstalledDir, id)); err != nil {
		return err
	}
	err := d.host.opts.Settings.UpdatePlugins(func(p *settings.PluginSettings) {
		delete(p.Installed, id)
		delete(p.Consent, id)
	})
	if err != nil {
		return err
	}
	d.host.Reload()
	return nil
}

// AutoUpdate installs the updates that ask for no new permissions (the
// installed version's permissions hash is unchanged) when the setting is
// on; updates with other permissions wait for consent in the app. It
// returns the ids updated.
func (d *Directory) AutoUpdate(ctx context.Context) []string {
	if !d.settings().AutoUpdate {
		return nil
	}
	var done []string
	for _, u := range d.State(ctx, indexFresh, nil).Updates {
		rec, ok := d.settings().Installed[u.ID]
		if u.PermissionsChanged || !ok || rec.PermissionsHash != u.PermissionsHash {
			continue
		}
		// The installed hash as consent: Install refuses a package whose
		// permissions differ from it.
		pend, err := d.Install(ctx, u.ID, rec.PermissionsHash)
		if err != nil {
			log.Printf("plugins: directory: updating %s: %v", u.ID, err)
			continue
		}
		if pend.Installed {
			log.Printf("plugins: directory: updated %s to %s", u.ID, pend.Version)
			done = append(done, u.ID)
		}
	}
	return done
}

// Run checks the index daily while any directory plugin is installed
// (revoked versions are turned off, and with the AutoUpdate setting
// same-permission updates install), until ctx ends. At start and hourly
// it also retries moving formerly bundled plugins to the directory
// (Migrate) while any is undecided.
func (d *Directory) Run(ctx context.Context) {
	t := time.NewTicker(time.Hour)
	defer t.Stop()
	for {
		d.Migrate(ctx, nil)
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		d.mu.Lock()
		due := d.now().Sub(d.checked) >= checkEvery
		d.mu.Unlock()
		if due && d.key != nil && len(d.settings().Installed) > 0 {
			if idx, _, _ := d.index(ctx, 0); idx != nil {
				d.AutoUpdate(ctx)
			}
		}
	}
}
