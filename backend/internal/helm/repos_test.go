package helm

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const fixtureIndex = `apiVersion: v1
entries:
  web:
  - name: web
    version: 1.4.2
    appVersion: "2.0"
    description: A demo web server
    urls: [web-1.4.2.tgz]
  - name: web
    version: 1.5.0-rc.1
    urls: [web-1.5.0-rc.1.tgz]
  - name: web
    version: 1.3.0
    urls: [web-1.3.0.tgz]
  queue:
  - name: queue
    version: 0.2.0
    urls: [queue-0.2.0.tgz]
`

// Repositories are read from (and added to) the helm CLI's own files; the
// cached index becomes chart listings and update hints; credentials are
// stored but never returned.
func TestUserReposChartsAndCredentials(t *testing.T) {
	dir := t.TempDir()
	cfg, cache := filepath.Join(dir, "config", "repositories.yaml"), filepath.Join(dir, "cache")
	t.Setenv("HELM_REPOSITORY_CONFIG", cfg)
	t.Setenv("HELM_REPOSITORY_CACHE", cache)

	var gotAuth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _, ok := r.BasicAuth()
		gotAuth = r.Header.Get("User-Agent")
		if !ok || r.URL.Path != "/charts/index.yaml" {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write([]byte(fixtureIndex))
	}))
	defer srv.Close()

	if _, err := AddRepo(AddRepoRequest{Name: "demo", URL: srv.URL + "/charts", Username: "someone", Password: "s3cret-value"}); err != nil {
		t.Fatal(err)
	}
	if gotAuth != UserAgent {
		t.Errorf("User-Agent = %q", gotAuth)
	}
	if _, err := AddRepo(AddRepoRequest{Name: "demo", URL: srv.URL}); err == nil {
		t.Error("adding a duplicate name should fail")
	}
	raw, _ := os.ReadFile(cfg)
	if !strings.Contains(string(raw), "s3cret-value") {
		t.Fatalf("password not written to repositories.yaml:\n%s", raw)
	}
	if st, _ := os.Stat(cfg); st.Mode().Perm() != 0o600 {
		t.Errorf("mode = %v", st.Mode().Perm())
	}

	l, err := ListRepos()
	if err != nil {
		t.Fatal(err)
	}
	out, _ := json.Marshal(l)
	if strings.Contains(string(out), "s3cret") || strings.Contains(string(out), "someone") {
		t.Errorf("credentials leaked: %s", out)
	}
	if len(l.Repositories) != 1 || !l.Repositories[0].HasCredentials || l.Repositories[0].Updated == "" || *l.Repositories[0].Charts != 2 {
		t.Errorf("repos = %s", out)
	}

	charts, err := ListRepoCharts("")
	if err != nil {
		t.Fatal(err)
	}
	if len(charts.Charts) != 2 || charts.Charts[1].Name != "web" || charts.Charts[1].Version != "1.4.2" {
		t.Errorf("charts = %+v", charts.Charts)
	}
	ups := FindUpdates(t.Context(), []ChartQuery{{"web", "1.3.0"}, {"web", "1.4.2"}, {"other", "1.0.0"}}, false)
	if u := ups["web@1.3.0"]; len(ups) != 1 || u.Latest != "1.4.2" || u.Repo != "demo" {
		t.Errorf("updates = %+v", ups)
	}

	if err := RemoveRepo("demo"); err != nil {
		t.Fatal(err)
	}
	if l, _ := ListRepos(); len(l.Repositories) != 0 {
		t.Errorf("still listed: %+v", l.Repositories)
	}
	if _, err := os.Stat(filepath.Join(cache, "demo-index.yaml")); !os.IsNotExist(err) {
		t.Errorf("cached index kept: %v", err)
	}
}
