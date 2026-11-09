package helm

import (
	"context"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"helm.sh/helm/v3/pkg/chartutil"
	"helm.sh/helm/v3/pkg/repo"
)

// chartRepo serves an https-style Helm repository (index.yaml + packaged
// charts) with demo 1.2.3 and 2.0.0.
func chartRepo(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	for _, v := range []string{"1.2.3", "2.0.0"} {
		c := testChart()
		c.Metadata.Version = v
		if _, err := chartutil.Save(c, dir); err != nil {
			t.Fatal(err)
		}
	}
	srv := httptest.NewServer(http.FileServer(http.Dir(dir)))
	t.Cleanup(srv.Close)
	idx, err := repo.IndexDirectory(dir, srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	if err := idx.WriteFile(filepath.Join(dir, "index.yaml"), 0o644); err != nil {
		t.Fatal(err)
	}
	old := CacheDir
	CacheDir = t.TempDir()
	t.Cleanup(func() { CacheDir = old })
	return srv.URL
}

func TestInstallAndUpgradeFromRepo(t *testing.T) {
	url := chartRepo(t)
	cfg := testConfig(t, "apps")
	res, err := Install(context.Background(), cfg, InstallRequest{Namespace: "apps", ReleaseName: "web", Repo: url, Chart: "demo", Version: "1.2.3", Values: "replicas: 2\n"})
	if err != nil {
		t.Fatal(err)
	}
	if res.Release.ChartVersion != "1.2.3" || res.Release.Status != "deployed" {
		t.Fatalf("install: %+v", res.Release)
	}

	// With repo + chart the requested version is fetched instead of re-rendering the stored chart.
	res, err = Upgrade(context.Background(), cfg, UpgradeRequest{Namespace: "apps", Name: "web", Repo: url, Chart: "demo", Version: "2.0.0", Values: "replicas: 2\n", DryRun: true})
	if err != nil {
		t.Fatal(err)
	}
	if res.Release.ChartVersion != "2.0.0" || !strings.Contains(res.CurrentManifest, "replicas: 2") {
		t.Fatalf("dry run: %+v", res.Release)
	}
	res, err = Upgrade(context.Background(), cfg, UpgradeRequest{Namespace: "apps", Name: "web", Repo: url, Chart: "demo", Version: "2.0.0", Values: "replicas: 2\n"})
	if err != nil {
		t.Fatal(err)
	}
	if res.Release.Revision != 2 || res.Release.ChartVersion != "2.0.0" {
		t.Fatalf("upgrade: %+v", res.Release)
	}
	if h, _ := History(cfg, "web"); h[0].Description != "Upgraded to demo 2.0.0 from k8sman" {
		t.Fatalf("description: %q", h[0].Description)
	}
}
