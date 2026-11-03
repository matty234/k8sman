package helm

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"helm.sh/helm/v3/pkg/action"
	"helm.sh/helm/v3/pkg/chart"
	"helm.sh/helm/v3/pkg/chart/loader"
	"helm.sh/helm/v3/pkg/chartutil"
	"helm.sh/helm/v3/pkg/cli"
	"helm.sh/helm/v3/pkg/getter"
	"helm.sh/helm/v3/pkg/registry"
	"helm.sh/helm/v3/pkg/repo"
	"sigs.k8s.io/yaml"
)

// CacheDir holds downloaded charts and repository indexes. Overridable for tests.
var CacheDir = defaultCacheDir()

func defaultCacheDir() string {
	if home, err := os.UserHomeDir(); err == nil {
		return filepath.Join(home, ".cache", "k8sman", "helm")
	}
	return filepath.Join(os.TempDir(), "k8sman-helm")
}

// indexTTL is how long a downloaded repository index is reused.
const indexTTL = 10 * time.Minute

// envSettings returns Helm CLI settings that keep the user's registry
// credentials but download charts into CacheDir. No `helm repo add` state
// is read or written: repositories are addressed by URL.
func envSettings() *cli.EnvSettings {
	s := cli.New()
	s.RepositoryCache = CacheDir
	s.RepositoryConfig = filepath.Join(CacheDir, "repositories.yaml")
	return s
}

func newRegistryClient(s *cli.EnvSettings) (*registry.Client, error) {
	return registry.NewClient(
		registry.ClientOptCredentialsFile(s.RegistryConfig),
		registry.ClientOptEnableCache(true),
		registry.ClientOptWriter(io.Discard),
	)
}

// chartRef resolves repo + chart into the name LocateChart wants. For OCI the
// repo may be the registry path ("oci://ghcr.io/org/charts") or the full
// chart reference ("oci://docker.io/envoyproxy/gateway-helm").
func chartRef(repoURL, chartName string) (name string, oci bool, err error) {
	repoURL = strings.TrimSpace(repoURL)
	chartName = strings.TrimSpace(chartName)
	switch {
	case registry.IsOCI(repoURL):
		ref := strings.TrimSuffix(repoURL, "/")
		if chartName != "" && !strings.HasSuffix(ref, "/"+chartName) {
			ref += "/" + chartName
		}
		return ref, true, nil
	case strings.HasPrefix(repoURL, "https://") || strings.HasPrefix(repoURL, "http://"):
		if chartName == "" {
			return "", false, invalid("chart is required")
		}
		return chartName, false, nil
	default:
		return "", false, invalid("repo must be an https:// Helm repository URL or an oci:// reference")
	}
}

// InstallRequest is POST /api/helm/install.
type InstallRequest struct {
	Namespace   string `json:"namespace"`
	ReleaseName string `json:"releaseName"`
	// Repo is an https Helm repository URL or an oci:// reference.
	Repo    string `json:"repo"`
	Chart   string `json:"chart"`
	Version string `json:"version"`
	// Values are the user-supplied values (YAML).
	Values          string `json:"values"`
	CreateNamespace *bool  `json:"createNamespace"`
	Wait            bool   `json:"wait"`
	TimeoutSeconds  int    `json:"timeoutSeconds"`
	DryRun          bool   `json:"dryRun"`
}

// Install fetches a chart from a repository (https index or OCI registry)
// and installs it. With DryRun the rendered manifest and notes are returned.
func Install(ctx context.Context, cfg *action.Configuration, req InstallRequest) (*Result, error) {
	if req.Namespace == "" || req.ReleaseName == "" {
		return nil, invalid("namespace and releaseName are required")
	}
	if err := chartutil.ValidateReleaseName(req.ReleaseName); err != nil {
		return nil, invalid("%v", err)
	}
	vals := map[string]any{}
	if strings.TrimSpace(req.Values) != "" {
		if err := yaml.Unmarshal([]byte(req.Values), &vals); err != nil {
			return nil, invalid("values are not valid YAML: %v", err)
		}
		if vals == nil {
			vals = map[string]any{}
		}
	}
	if err := useRegistryClient(cfg); err != nil {
		return nil, err
	}
	inst := action.NewInstall(cfg)
	inst.ReleaseName = req.ReleaseName
	inst.Namespace = req.Namespace
	inst.CreateNamespace = req.CreateNamespace == nil || *req.CreateNamespace
	inst.DryRun = req.DryRun
	if req.DryRun {
		inst.DryRunOption = "client"
	}
	inst.Wait = req.Wait
	inst.Timeout = timeout(req.TimeoutSeconds)
	inst.Description = "Installed from k8sman"

	ch, err := fetchChart(&inst.ChartPathOptions, req.Repo, req.Chart, req.Version)
	if err != nil {
		return nil, err
	}
	rel, err := inst.RunWithContext(ctx, ch, vals)
	if err != nil {
		return nil, err
	}
	s := summarize(rel)
	res := &Result{DryRun: req.DryRun, Release: &s, Manifest: rel.Manifest}
	if rel.Info != nil {
		res.Notes = rel.Info.Notes
	}
	if req.DryRun {
		res.Message = fmt.Sprintf("Dry run: rendered %s %s as release %s", s.Chart, s.ChartVersion, req.ReleaseName)
	} else {
		res.Message = fmt.Sprintf("Installed %s %s as %s in %s (%s)", s.Chart, s.ChartVersion, req.ReleaseName, req.Namespace, s.Status)
	}
	return res, nil
}

// useRegistryClient gives cfg (and the actions created from it afterwards)
// a registry client with the user's credentials, for OCI charts.
func useRegistryClient(cfg *action.Configuration) error {
	rc, err := newRegistryClient(envSettings())
	if err != nil {
		return err
	}
	cfg.RegistryClient = rc
	return nil
}

// fetchChart downloads repo/chart at version ("" = latest), or reuses the
// cached copy, and loads it. cpo is the action's chart options, whose
// registry client comes from the action's configuration.
func fetchChart(cpo *action.ChartPathOptions, repoURL, chartName, version string) (*chart.Chart, error) {
	name, oci, err := chartRef(repoURL, chartName)
	if err != nil {
		return nil, err
	}
	cpo.Version = strings.TrimSpace(version)
	if !oci {
		cpo.RepoURL = strings.TrimSpace(repoURL)
	}
	path, err := cpo.LocateChart(name, envSettings())
	if err != nil {
		return nil, fmt.Errorf("fetch chart %s: %w", name, err)
	}
	ch, err := loader.Load(path)
	if err != nil {
		return nil, fmt.Errorf("load chart: %w", err)
	}
	if ch.Metadata != nil && ch.Metadata.Type != "" && ch.Metadata.Type != "application" {
		return nil, invalid("chart %s is a %s chart and can't be installed", ch.Name(), ch.Metadata.Type)
	}
	if ch.Metadata != nil && len(ch.Metadata.Dependencies) > 0 {
		if err := action.CheckDependencies(ch, ch.Metadata.Dependencies); err != nil {
			return nil, invalid("chart %s is missing dependencies: %v", ch.Name(), err)
		}
	}
	return ch, nil
}

// ChartVersion is one entry of GET /api/helm/chart-versions.
type ChartVersion struct {
	Version     string `json:"version"`
	AppVersion  string `json:"appVersion,omitempty"`
	Created     string `json:"created,omitempty"`
	Description string `json:"description,omitempty"`
	Deprecated  bool   `json:"deprecated,omitempty"`
	// Prerelease marks semver pre-releases (e.g. 1.11.0-rc.0).
	Prerelease bool `json:"prerelease,omitempty"`
}

// ChartVersions lists the versions of a chart, newest first. For https
// repositories it reads the index (cached for indexTTL); for OCI it lists
// the registry's semver tags.
func ChartVersions(repoURL, chartName string) ([]ChartVersion, error) {
	ref, oci, err := chartRef(repoURL, chartName)
	if err != nil {
		return nil, err
	}
	settings := envSettings()
	if oci {
		rc, err := newRegistryClient(settings)
		if err != nil {
			return nil, err
		}
		tags, err := rc.Tags(strings.TrimPrefix(ref, fmt.Sprintf("%s://", registry.OCIScheme)))
		if err != nil {
			return nil, fmt.Errorf("list tags of %s: %w", ref, err)
		}
		out := make([]ChartVersion, 0, len(tags))
		for _, t := range tags {
			out = append(out, ChartVersion{Version: t, Prerelease: strings.Contains(t, "-")})
		}
		return out, nil
	}
	idx, err := loadIndex(settings, repoURL)
	if err != nil {
		return nil, err
	}
	entries, ok := idx.Entries[chartName]
	if !ok {
		return nil, fmt.Errorf("%w: chart %q in %s", ErrNotFound, chartName, repoURL)
	}
	out := make([]ChartVersion, 0, len(entries))
	for _, e := range entries { // SortEntries: newest first
		if e.Metadata == nil {
			continue
		}
		cv := ChartVersion{Version: e.Version, AppVersion: e.AppVersion, Description: e.Description, Deprecated: e.Deprecated, Prerelease: strings.Contains(e.Version, "-")}
		if !e.Created.IsZero() {
			cv.Created = e.Created.UTC().Format(time.RFC3339)
		}
		out = append(out, cv)
	}
	return out, nil
}

func loadIndex(settings *cli.EnvSettings, repoURL string) (*repo.IndexFile, error) {
	sum := sha256.Sum256([]byte(strings.TrimSuffix(repoURL, "/")))
	name := "k8sman-" + hex.EncodeToString(sum[:8])
	dir := filepath.Join(CacheDir, "index")
	path := filepath.Join(dir, name+"-index.yaml")
	if st, err := os.Stat(path); err != nil || time.Since(st.ModTime()) > indexTTL {
		r, err := repo.NewChartRepository(&repo.Entry{Name: name, URL: repoURL}, getter.All(settings))
		if err != nil {
			return nil, err
		}
		r.CachePath = dir
		if path, err = r.DownloadIndexFile(); err != nil {
			return nil, fmt.Errorf("%q is not a valid chart repository or cannot be reached: %w", repoURL, err)
		}
	}
	idx, err := repo.LoadIndexFile(path)
	if err != nil {
		return nil, err
	}
	idx.SortEntries()
	return idx, nil
}
