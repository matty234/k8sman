package helm

// The user's Helm repositories ("helm repo list/add/remove/update"): read
// and written exactly where the helm CLI keeps them (repositories.yaml and
// the repository cache, located by helmpath through cli.New, so
// HELM_REPOSITORY_CONFIG, HELM_REPOSITORY_CACHE, HELM_CONFIG_HOME and the
// XDG/OS defaults all apply). Credentials in repositories.yaml are used for
// fetching but never returned.

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/Masterminds/semver/v3"
	"github.com/gofrs/flock"
	"helm.sh/helm/v3/pkg/chart/loader"
	"helm.sh/helm/v3/pkg/cli"
	"helm.sh/helm/v3/pkg/getter"
	"helm.sh/helm/v3/pkg/helmpath"
	"helm.sh/helm/v3/pkg/repo"
)

// UserSettings returns the helm CLI's own settings (not the k8sman cache
// that installs use). A variable so tests can point it at a temp dir.
var UserSettings = cli.New

// UserAgent is sent on every request k8sman makes for charts and indexes.
const UserAgent = "k8sman"

const (
	repoFetchTimeout  = 60 * time.Second
	chartFetchTimeout = 30 * time.Second
	maxChartArchive   = 32 << 20
)

// Repo is one entry of GET /api/helm/repos.
type Repo struct {
	Name string `json:"name"`
	URL  string `json:"url"`
	// Updated is when the cached index was last downloaded ("" = never).
	Updated string `json:"updated,omitempty"`
	// Charts is the number of charts in the cached index (nil = unknown).
	Charts *int `json:"charts,omitempty"`
	// HasCredentials says a username/password or client certificate is
	// configured; the values themselves are never returned.
	HasCredentials        bool `json:"hasCredentials,omitempty"`
	InsecureSkipTLSVerify bool `json:"insecureSkipTLSVerify,omitempty"`
}

// Registry is an OCI registry the user logged in to (helm registry login).
type Registry struct {
	Host string `json:"host"`
}

// RepoList is GET /api/helm/repos.
type RepoList struct {
	Repositories   []Repo     `json:"repositories"`
	ConfigPath     string     `json:"configPath"`
	CachePath      string     `json:"cachePath"`
	Registries     []Registry `json:"registries"`
	RegistryConfig string     `json:"registryConfig"`
}

// ListRepos reads repositories.yaml (a missing file is an empty list) and
// the registry hosts in registry/config.json.
func ListRepos() (*RepoList, error) {
	s := UserSettings()
	f, err := loadRepoFile(s.RepositoryConfig)
	if err != nil {
		return nil, err
	}
	out := &RepoList{Repositories: []Repo{}, ConfigPath: s.RepositoryConfig, CachePath: s.RepositoryCache, Registries: registryHosts(s.RegistryConfig), RegistryConfig: s.RegistryConfig}
	for _, e := range f.Repositories {
		if e != nil {
			out.Repositories = append(out.Repositories, repoSummary(s, e))
		}
	}
	return out, nil
}

func loadRepoFile(path string) (*repo.File, error) {
	f, err := repo.LoadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) || os.IsNotExist(errors.Unwrap(err)) {
			return repo.NewFile(), nil
		}
		if _, statErr := os.Stat(path); os.IsNotExist(statErr) {
			return repo.NewFile(), nil
		}
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	return f, nil
}

func repoSummary(s *cli.EnvSettings, e *repo.Entry) Repo {
	r := Repo{
		Name: e.Name, URL: e.URL,
		HasCredentials:        e.Username != "" || e.Password != "" || e.CertFile != "" || e.KeyFile != "",
		InsecureSkipTLSVerify: e.InsecureSkipTLSverify,
	}
	if st, err := os.Stat(filepath.Join(s.RepositoryCache, helmpath.CacheIndexFile(e.Name))); err == nil {
		r.Updated = st.ModTime().UTC().Format(time.RFC3339)
	}
	// helm writes the chart names next to the index: cheap to count.
	if b, err := os.ReadFile(filepath.Join(s.RepositoryCache, helmpath.CacheChartsFile(e.Name))); err == nil {
		n := 0
		sc := bufio.NewScanner(bytes.NewReader(b))
		for sc.Scan() {
			if strings.TrimSpace(sc.Text()) != "" {
				n++
			}
		}
		r.Charts = &n
	}
	return r
}

// registryHosts lists the hosts in the registry credentials file (docker
// config format); only the host names, never the auth values.
func registryHosts(path string) []Registry {
	out := []Registry{}
	b, err := os.ReadFile(path)
	if err != nil {
		return out
	}
	var cfg struct {
		Auths       map[string]json.RawMessage `json:"auths"`
		CredHelpers map[string]string          `json:"credHelpers"`
	}
	if json.Unmarshal(b, &cfg) != nil {
		return out
	}
	seen := map[string]bool{}
	for h := range cfg.Auths {
		seen[h] = true
	}
	for h := range cfg.CredHelpers {
		seen[h] = true
	}
	for h := range seen {
		out = append(out, Registry{Host: h})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Host < out[j].Host })
	return out
}

// timedGetters are helm's getters with a timeout and k8sman's User-Agent
// added to every request.
func timedGetters(s *cli.EnvSettings, timeout time.Duration) getter.Providers {
	var out getter.Providers
	for _, p := range getter.All(s) {
		inner := p.New
		out = append(out, getter.Provider{Schemes: p.Schemes, New: func(opts ...getter.Option) (getter.Getter, error) {
			return inner(append(opts, getter.WithTimeout(timeout), getter.WithUserAgent(UserAgent))...)
		}})
	}
	return out
}

// lockRepoFile takes helm's lock next to repositories.yaml (the same
// <file>.lock that helm repo add uses).
func lockRepoFile(path string) (func(), error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	lockPath := path + ".lock"
	if ext := filepath.Ext(path); ext != "" && len(ext) < len(path) {
		lockPath = strings.TrimSuffix(path, ext) + ".lock"
	}
	l := flock.New(lockPath)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	ok, err := l.TryLockContext(ctx, time.Second)
	if err != nil {
		return nil, fmt.Errorf("lock %s: %w", lockPath, err)
	}
	if !ok {
		return nil, fmt.Errorf("%s is locked by another helm process", lockPath)
	}
	return func() { _ = l.Unlock() }, nil
}

func findRepo(s *cli.EnvSettings, name string) (*repo.Entry, error) {
	f, err := loadRepoFile(s.RepositoryConfig)
	if err != nil {
		return nil, err
	}
	if e := f.Get(name); e != nil {
		return e, nil
	}
	return nil, fmt.Errorf("%w: no repository named %q in %s", ErrNotFound, name, s.RepositoryConfig)
}

// UpdateRepo downloads a repository's index into the helm cache, like
// helm repo update <name>.
func UpdateRepo(name string) (*Repo, error) {
	s := UserSettings()
	e, err := findRepo(s, name)
	if err != nil {
		return nil, err
	}
	if err := downloadIndex(s, e); err != nil {
		return nil, err
	}
	r := repoSummary(s, e)
	return &r, nil
}

func downloadIndex(s *cli.EnvSettings, e *repo.Entry) error {
	cr, err := repo.NewChartRepository(e, timedGetters(s, repoFetchTimeout))
	if err != nil {
		return invalid("%v", err)
	}
	cr.CachePath = s.RepositoryCache
	if _, err := cr.DownloadIndexFile(); err != nil {
		return fmt.Errorf("%q is not a valid chart repository or cannot be reached: %w", e.URL, err)
	}
	return nil
}

// AddRepoRequest is POST /api/helm/repos/add.
type AddRepoRequest struct {
	Name                  string `json:"name"`
	URL                   string `json:"url"`
	Username              string `json:"username,omitempty"`
	Password              string `json:"password,omitempty"`
	PassCredentialsAll    bool   `json:"passCredentialsAll,omitempty"`
	InsecureSkipTLSVerify bool   `json:"insecureSkipTLSVerify,omitempty"`
}

var repoNameRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*$`)

// AddRepo adds a repository to repositories.yaml like helm repo add: under
// helm's lock, after downloading its index to check it is a repository.
func AddRepo(req AddRepoRequest) (*Repo, error) {
	req.Name, req.URL = strings.TrimSpace(req.Name), strings.TrimSpace(req.URL)
	if !repoNameRe.MatchString(req.Name) {
		return nil, invalid("repository name must be letters, digits, '.', '_' or '-' (no '/')")
	}
	u, err := url.Parse(req.URL)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" {
		if strings.HasPrefix(req.URL, "oci://") {
			return nil, invalid("OCI registries aren't added as repositories: use the oci:// reference directly (and helm registry login for credentials)")
		}
		return nil, invalid("url must be an http(s) Helm repository URL")
	}
	s := UserSettings()
	unlock, err := lockRepoFile(s.RepositoryConfig)
	if err != nil {
		return nil, err
	}
	defer unlock()
	f, err := loadRepoFile(s.RepositoryConfig)
	if err != nil {
		return nil, err
	}
	if f.Has(req.Name) {
		return nil, invalid("a repository named %q already exists", req.Name)
	}
	e := &repo.Entry{
		Name: req.Name, URL: req.URL, Username: req.Username, Password: req.Password,
		PassCredentialsAll: req.PassCredentialsAll, InsecureSkipTLSverify: req.InsecureSkipTLSVerify,
	}
	if err := downloadIndex(s, e); err != nil {
		return nil, err
	}
	f.Update(e)
	if err := f.WriteFile(s.RepositoryConfig, 0o600); err != nil {
		return nil, err
	}
	r := repoSummary(s, e)
	return &r, nil
}

// RemoveRepo removes a repository from repositories.yaml and its cached
// index, like helm repo remove.
func RemoveRepo(name string) error {
	s := UserSettings()
	unlock, err := lockRepoFile(s.RepositoryConfig)
	if err != nil {
		return err
	}
	defer unlock()
	f, err := loadRepoFile(s.RepositoryConfig)
	if err != nil {
		return err
	}
	if !f.Remove(name) {
		return fmt.Errorf("%w: no repository named %q", ErrNotFound, name)
	}
	if err := f.WriteFile(s.RepositoryConfig, 0o600); err != nil {
		return err
	}
	for _, p := range []string{helmpath.CacheChartsFile(name), helmpath.CacheIndexFile(name)} {
		_ = os.Remove(filepath.Join(s.RepositoryCache, p))
	}
	return nil
}

// ---- browsing --------------------------------------------------------------

// parsed indexes, keyed by path and invalidated by mtime/size.
var userIndexes = struct {
	sync.Mutex
	m map[string]cachedIndex
}{m: map[string]cachedIndex{}}

type cachedIndex struct {
	mod  time.Time
	size int64
	idx  *repo.IndexFile
}

// cachedRepoIndex loads a repository's cached index.yaml (nil, nil when it
// was never downloaded).
func cachedRepoIndex(s *cli.EnvSettings, name string) (*repo.IndexFile, error) {
	path := filepath.Join(s.RepositoryCache, helmpath.CacheIndexFile(name))
	st, err := os.Stat(path)
	if err != nil {
		return nil, nil
	}
	userIndexes.Lock()
	c, ok := userIndexes.m[path]
	userIndexes.Unlock()
	if ok && c.mod.Equal(st.ModTime()) && c.size == st.Size() {
		return c.idx, nil
	}
	idx, err := repo.LoadIndexFile(path)
	if err != nil {
		return nil, fmt.Errorf("read index of %s: %w", name, err)
	}
	idx.SortEntries()
	userIndexes.Lock()
	userIndexes.m[path] = cachedIndex{st.ModTime(), st.Size(), idx}
	userIndexes.Unlock()
	return idx, nil
}

// RepoChart is one chart of GET /api/helm/repos/charts.
type RepoChart struct {
	Repo        string   `json:"repo"`
	RepoURL     string   `json:"repoURL"`
	Name        string   `json:"name"`
	Version     string   `json:"version"`
	AppVersion  string   `json:"appVersion,omitempty"`
	Description string   `json:"description,omitempty"`
	Icon        string   `json:"icon,omitempty"`
	Keywords    []string `json:"keywords,omitempty"`
	Deprecated  bool     `json:"deprecated,omitempty"`
	Created     string   `json:"created,omitempty"`
}

// RepoCharts is GET /api/helm/repos/charts.
type RepoCharts struct {
	Charts []RepoChart `json:"charts"`
	// NotCached lists repositories whose index was never downloaded.
	NotCached []string `json:"notCached"`
	// Errors maps repository → why its index couldn't be read.
	Errors map[string]string `json:"errors,omitempty"`
}

// latestEntry is the newest stable version (or the newest when there are
// only pre-releases); entries are sorted newest first.
func latestEntry(vs repo.ChartVersions) *repo.ChartVersion {
	for _, v := range vs {
		if v != nil && v.Metadata != nil && !isPrerelease(v.Version) {
			return v
		}
	}
	for _, v := range vs {
		if v != nil && v.Metadata != nil {
			return v
		}
	}
	return nil
}

func isPrerelease(v string) bool {
	if sv, err := semver.NewVersion(v); err == nil {
		return sv.Prerelease() != ""
	}
	return strings.Contains(v, "-")
}

// ListRepoCharts lists the latest version of every chart in the cached
// indexes of repoName ("" = all repositories).
func ListRepoCharts(repoName string) (*RepoCharts, error) {
	s := UserSettings()
	f, err := loadRepoFile(s.RepositoryConfig)
	if err != nil {
		return nil, err
	}
	out := &RepoCharts{Charts: []RepoChart{}, NotCached: []string{}}
	found := false
	for _, e := range f.Repositories {
		if e == nil || (repoName != "" && e.Name != repoName) {
			continue
		}
		found = true
		idx, err := cachedRepoIndex(s, e.Name)
		if err != nil {
			if out.Errors == nil {
				out.Errors = map[string]string{}
			}
			out.Errors[e.Name] = err.Error()
			continue
		}
		if idx == nil {
			out.NotCached = append(out.NotCached, e.Name)
			continue
		}
		for name, vs := range idx.Entries {
			v := latestEntry(vs)
			if v == nil {
				continue
			}
			out.Charts = append(out.Charts, RepoChart{
				Repo: e.Name, RepoURL: e.URL, Name: name, Version: v.Version, AppVersion: v.AppVersion,
				Description: v.Description, Icon: v.Icon, Keywords: v.Keywords, Deprecated: v.Deprecated, Created: created(v),
			})
		}
	}
	if repoName != "" && !found {
		return nil, fmt.Errorf("%w: no repository named %q", ErrNotFound, repoName)
	}
	sort.Slice(out.Charts, func(i, j int) bool {
		a, b := out.Charts[i], out.Charts[j]
		if a.Name != b.Name {
			return a.Name < b.Name
		}
		return a.Repo < b.Repo
	})
	return out, nil
}

func created(v *repo.ChartVersion) string {
	if v.Created.IsZero() {
		return ""
	}
	return v.Created.UTC().Format(time.RFC3339)
}

// Maintainer of a chart.
type Maintainer struct {
	Name  string `json:"name"`
	Email string `json:"email,omitempty"`
	URL   string `json:"url,omitempty"`
}

// Link is a named URL (home, source, documentation…).
type Link struct {
	Name string `json:"name"`
	URL  string `json:"url"`
}

// ChartDetail is one chart, from a repository index or Artifact Hub.
type ChartDetail struct {
	// Source is "repo" (a configured repository) or "artifacthub".
	Source string `json:"source"`
	// Repo is the repository name; RepoURL what install/upgrade fetch from
	// (an https repository or an oci:// reference).
	Repo        string         `json:"repo"`
	RepoDisplay string         `json:"repoDisplay,omitempty"`
	RepoURL     string         `json:"repoURL"`
	Name        string         `json:"name"`
	Version     string         `json:"version"`
	AppVersion  string         `json:"appVersion,omitempty"`
	Description string         `json:"description,omitempty"`
	Icon        string         `json:"icon,omitempty"`
	Home        string         `json:"home,omitempty"`
	Keywords    []string       `json:"keywords,omitempty"`
	Maintainers []Maintainer   `json:"maintainers"`
	Links       []Link         `json:"links"`
	Deprecated  bool           `json:"deprecated,omitempty"`
	KubeVersion string         `json:"kubeVersion,omitempty"`
	Type        string         `json:"type,omitempty"`
	License     string         `json:"license,omitempty"`
	Versions    []ChartVersion `json:"versions"`
	// Artifact Hub only.
	PackageID string `json:"packageId,omitempty"`
	Readme    string `json:"readme,omitempty"`
	Official  bool   `json:"official,omitempty"`
	Verified  bool   `json:"verified,omitempty"`
}

// RepoChartDetail describes chart in repository repoName at version ("" =
// the latest stable), from the cached index.
func RepoChartDetail(repoName, chartName, version string) (*ChartDetail, error) {
	s := UserSettings()
	e, err := findRepo(s, repoName)
	if err != nil {
		return nil, err
	}
	idx, err := cachedRepoIndex(s, repoName)
	if err != nil {
		return nil, err
	}
	if idx == nil {
		return nil, invalid("the index of %s hasn't been downloaded: update the repository first", repoName)
	}
	vs, ok := idx.Entries[chartName]
	if !ok || len(vs) == 0 {
		return nil, fmt.Errorf("%w: chart %q in %s", ErrNotFound, chartName, repoName)
	}
	cv := latestEntry(vs)
	if version != "" {
		cv = nil
		for _, v := range vs {
			if v != nil && v.Version == version {
				cv = v
			}
		}
		if cv == nil {
			return nil, fmt.Errorf("%w: %s %s in %s", ErrNotFound, chartName, version, repoName)
		}
	}
	if cv == nil {
		return nil, fmt.Errorf("%w: chart %q in %s", ErrNotFound, chartName, repoName)
	}
	m := cv.Metadata
	d := &ChartDetail{
		Source: "repo", Repo: e.Name, RepoURL: e.URL, Name: m.Name, Version: m.Version, AppVersion: m.AppVersion,
		Description: m.Description, Icon: m.Icon, Home: m.Home, Keywords: m.Keywords, Deprecated: m.Deprecated,
		KubeVersion: m.KubeVersion, Type: m.Type, Maintainers: []Maintainer{}, Links: []Link{}, Versions: []ChartVersion{},
	}
	if d.Name == "" {
		d.Name = chartName
	}
	for _, mt := range m.Maintainers {
		if mt != nil && mt.Name != "" {
			d.Maintainers = append(d.Maintainers, Maintainer{Name: mt.Name, Email: mt.Email, URL: mt.URL})
		}
	}
	if m.Home != "" {
		d.Links = append(d.Links, Link{Name: "Home", URL: m.Home})
	}
	for _, src := range m.Sources {
		if src != "" {
			d.Links = append(d.Links, Link{Name: "Source", URL: src})
		}
	}
	for _, v := range vs {
		if v == nil || v.Metadata == nil {
			continue
		}
		d.Versions = append(d.Versions, ChartVersion{Version: v.Version, AppVersion: v.AppVersion, Created: created(v), Deprecated: v.Deprecated, Prerelease: isPrerelease(v.Version)})
	}
	return d, nil
}

// ChartFiles is GET /api/helm/repos/chart/files: the chart's README and
// default values.yaml, read from its archive.
type ChartFiles struct {
	Version string `json:"version"`
	Readme  string `json:"readme"`
	Values  string `json:"values"`
}

var chartFilesCache = struct {
	sync.Mutex
	m map[string]*ChartFiles
}{m: map[string]*ChartFiles{}}

// RepoChartFiles downloads chart at version ("" = latest stable) from a
// configured repository (with its credentials) and returns its README and
// values.yaml. Results are kept in memory.
func RepoChartFiles(repoName, chartName, version string) (*ChartFiles, error) {
	s := UserSettings()
	e, err := findRepo(s, repoName)
	if err != nil {
		return nil, err
	}
	idx, err := cachedRepoIndex(s, repoName)
	if err != nil {
		return nil, err
	}
	if idx == nil {
		return nil, invalid("the index of %s hasn't been downloaded: update the repository first", repoName)
	}
	var cv *repo.ChartVersion
	if version == "" {
		cv = latestEntry(idx.Entries[chartName])
	} else if cv, err = idx.Get(chartName, version); err != nil {
		cv = nil
	}
	if cv == nil || len(cv.URLs) == 0 {
		return nil, fmt.Errorf("%w: %s %s in %s", ErrNotFound, chartName, version, repoName)
	}
	key := e.URL + "\x00" + chartName + "\x00" + cv.Version
	chartFilesCache.Lock()
	if c, ok := chartFilesCache.m[key]; ok {
		chartFilesCache.Unlock()
		return c, nil
	}
	chartFilesCache.Unlock()

	href, err := repo.ResolveReferenceURL(e.URL, cv.URLs[0])
	if err != nil {
		return nil, err
	}
	u, err := url.Parse(href)
	if err != nil {
		return nil, err
	}
	g, err := timedGetters(s, chartFetchTimeout).ByScheme(u.Scheme)
	if err != nil {
		return nil, invalid("%v", err)
	}
	buf, err := g.Get(href,
		getter.WithURL(e.URL),
		getter.WithInsecureSkipVerifyTLS(e.InsecureSkipTLSverify),
		getter.WithTLSClientConfig(e.CertFile, e.KeyFile, e.CAFile),
		getter.WithBasicAuth(e.Username, e.Password),
		getter.WithPassCredentialsAll(e.PassCredentialsAll),
	)
	if err != nil {
		return nil, fmt.Errorf("download %s %s: %w", chartName, cv.Version, err)
	}
	if buf.Len() > maxChartArchive {
		return nil, fmt.Errorf("chart archive of %s is too large (%d bytes)", chartName, buf.Len())
	}
	ch, err := loader.LoadArchive(buf)
	if err != nil {
		return nil, fmt.Errorf("load chart %s: %w", chartName, err)
	}
	out := &ChartFiles{Version: cv.Version}
	for _, f := range ch.Raw {
		switch strings.ToLower(f.Name) {
		case "values.yaml":
			out.Values = string(f.Data)
		case "readme.md", "readme":
			out.Readme = string(f.Data)
		}
	}
	chartFilesCache.Lock()
	if len(chartFilesCache.m) > 64 {
		chartFilesCache.m = map[string]*ChartFiles{}
	}
	chartFilesCache.m[key] = out
	chartFilesCache.Unlock()
	return out, nil
}
