package overview

import (
	"encoding/json"
	"os"
	"testing"
)

// Real Applications captured from the dev cluster (shared with the Flutter tests).
func argoFixture(t *testing.T, name string) map[string]any {
	t.Helper()
	b, err := os.ReadFile("../../../frontend/test/panels/argocd/fixtures/app-" + name + ".json")
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func TestArgoAppsIssues(t *testing.T) {
	names := []string{"guestbook", "helm-guestbook", "guestbook-degraded", "guestbook-no-namespace", "bad-path", "multi-source"}
	var apps []map[string]any
	for _, n := range names {
		apps = append(apps, argoFixture(t, n))
	}
	res := Analyze(Input{Now: now, ArgoApps: apps})

	got := map[string]Issue{}
	for _, is := range res.Issues {
		if is.Group == "argoproj.io" {
			if _, dup := got[is.Name]; dup {
				t.Errorf("%s reported twice", is.Name)
			}
			got[is.Name] = is
		}
	}
	want := map[string][2]string{
		"helm-guestbook":         {Warning, "argoMissing"},
		"guestbook-degraded":     {Critical, "argoDegraded"},
		"guestbook-no-namespace": {Critical, "argoSyncFailed"},
		"bad-path":               {Critical, "argoSyncFailed"},
	}
	for name, w := range want {
		is, ok := got[name]
		if !ok {
			t.Errorf("%s: no issue", name)
			continue
		}
		if is.Severity != w[0] || is.Category != w[1] {
			t.Errorf("%s: got %s/%s, want %s/%s", name, is.Severity, is.Category, w[0], w[1])
		}
		if is.Kind != "Application" || is.Namespace != "argocd" || is.Message == "" {
			t.Errorf("%s: bad issue %+v", name, is)
		}
	}
	if _, ok := got["guestbook"]; ok {
		t.Error("healthy synced app should not be an issue")
	}
	if is := got["guestbook-no-namespace"]; is.Reason != "SyncFailed" {
		t.Errorf("reason = %q", is.Reason)
	}
	if is := got["bad-path"]; is.Reason != "ComparisonError" {
		t.Errorf("reason = %q", is.Reason)
	}
	c := res.Counts.ArgoApps
	if c == nil || c.Total != 6 || c.Degraded != 1 || c.Failed != 1 || c.OutOfSync != 2 {
		t.Errorf("counts = %+v", c)
	}
}
