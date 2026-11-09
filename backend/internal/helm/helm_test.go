package helm

import (
	"context"
	"errors"
	"io"
	"strings"
	"testing"
	"time"

	"helm.sh/helm/v3/pkg/action"
	"helm.sh/helm/v3/pkg/chart"
	"helm.sh/helm/v3/pkg/chartutil"
	kubefake "helm.sh/helm/v3/pkg/kube/fake"
	"helm.sh/helm/v3/pkg/release"
	"helm.sh/helm/v3/pkg/storage"
	"helm.sh/helm/v3/pkg/storage/driver"
	helmtime "helm.sh/helm/v3/pkg/time"
)

const deployTpl = `apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
spec:
  replicas: {{ .Values.replicas }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}
`

func testChart() *chart.Chart {
	return &chart.Chart{
		Metadata: &chart.Metadata{APIVersion: "v2", Name: "demo", Version: "1.2.3", AppVersion: "4.5", Description: "A demo", Home: "https://example.com", Icon: "https://example.com/icon.png"},
		Values:   map[string]any{"replicas": 1, "image": "nginx"},
		Templates: []*chart.File{
			{Name: "templates/deploy.yaml", Data: []byte(deployTpl)},
			{Name: "templates/NOTES.txt", Data: []byte("Hello {{ .Release.Name }}")},
		},
	}
}

func manifestFor(name string, replicas int) string {
	return strings.NewReplacer("{{ .Release.Name }}", name, "{{ .Values.replicas }}", string(rune('0'+replicas))).Replace(
		"---\n# Source: demo/templates/deploy.yaml\n" + deployTpl)
}

func mkRelease(name, ns string, version int, status release.Status, replicas int) *release.Release {
	now := helmtime.Time{Time: time.Date(2026, 11, 1, 10, version, 0, 0, time.UTC)}
	return &release.Release{
		Name:      name,
		Namespace: ns,
		Version:   version,
		Chart:     testChart(),
		Config:    map[string]any{"replicas": replicas},
		Manifest:  manifestFor(name, replicas),
		Info: &release.Info{
			Status: status, FirstDeployed: now, LastDeployed: now,
			Description: "rev " + string(rune('0'+version)), Notes: "Hello " + name,
		},
		Hooks: []*release.Hook{{
			Name: name + "-smoke", Kind: "Job", Path: "demo/templates/smoke.yaml",
			Manifest: "apiVersion: batch/v1\nkind: Job\nmetadata:\n  name: " + name + "-smoke\n",
			Events:   []release.HookEvent{release.HookPostInstall, release.HookPostUpgrade},
			LastRun:  release.HookExecution{StartedAt: now, CompletedAt: now, Phase: release.HookPhaseSucceeded},
		}},
	}
}

func testConfig(t *testing.T, ns string, rels ...*release.Release) *action.Configuration {
	t.Helper()
	mem := driver.NewMemory()
	cfg := &action.Configuration{
		Releases:     storage.Init(mem),
		KubeClient:   &kubefake.PrintingKubeClient{Out: io.Discard},
		Capabilities: chartutil.DefaultCapabilities,
		Log:          func(string, ...any) {},
	}
	for _, r := range rels {
		if err := cfg.Releases.Create(r); err != nil {
			t.Fatal(err)
		}
	}
	mem.SetNamespace(ns) // "" = all namespaces
	return cfg
}

// web: 3 revisions (latest deployed); api: failed; worker: stuck pending-upgrade.
func fixture(t *testing.T, ns string) *action.Configuration {
	return testConfig(t, ns,
		mkRelease("web", "apps", 1, release.StatusSuperseded, 1),
		mkRelease("web", "apps", 2, release.StatusSuperseded, 2),
		mkRelease("web", "apps", 3, release.StatusDeployed, 3),
		mkRelease("api", "apps", 1, release.StatusDeployed, 1),
		mkRelease("api", "apps", 2, release.StatusFailed, 2),
		mkRelease("worker", "tools", 1, release.StatusDeployed, 1),
		mkRelease("worker", "tools", 2, release.StatusPendingUpgrade, 2),
	)
}

func TestList(t *testing.T) {
	res, err := List(fixture(t, ""))
	if err != nil {
		t.Fatal(err)
	}
	if res.Total != 3 || res.Failed != 1 || res.Pending != 1 {
		t.Fatalf("counts: %+v", res)
	}
	got := []string{}
	for _, r := range res.Releases {
		got = append(got, r.Namespace+"/"+r.Name+":"+r.Status)
	}
	want := "apps/api:failed apps/web:deployed tools/worker:pending-upgrade"
	if strings.Join(got, " ") != want {
		t.Fatalf("got %v, want %s", got, want)
	}
	if w := res.Releases[1]; w.Revision != 3 || w.Chart != "demo" || w.ChartVersion != "1.2.3" || w.AppVersion != "4.5" || w.Updated == "" {
		t.Fatalf("summary: %+v", w)
	}
}

func TestGetDetails(t *testing.T) {
	d, err := Get(fixture(t, "apps"), "web", 0, nil)
	if err != nil {
		t.Fatal(err)
	}
	if d.Revision != 3 || d.LatestRevision != 3 || d.Status != "deployed" || d.Notes != "Hello web" || d.Stuck != nil {
		t.Fatalf("detail: %+v", d.ReleaseSummary)
	}
	if d.Values != "replicas: 3\n" {
		t.Fatalf("values: %q", d.Values)
	}
	if !strings.Contains(d.ComputedValues, "image: nginx") || !strings.Contains(d.ComputedValues, "replicas: 3") {
		t.Fatalf("computed: %q", d.ComputedValues)
	}
	if d.ChartInfo.Name != "demo" || d.ChartInfo.Icon == "" || d.ChartInfo.Home == "" {
		t.Fatalf("chart: %+v", d.ChartInfo)
	}
	if len(d.Resources) != 2 || d.Resources[0] != (Resource{Group: "apps", Version: "v1", Kind: "Deployment", Name: "web", Namespace: "apps"}) || d.Resources[1].Kind != "Service" {
		t.Fatalf("resources: %+v", d.Resources)
	}
	if len(d.Hooks) != 1 || d.Hooks[0].Phase != "Succeeded" || d.Hooks[0].Group != "batch" || len(d.Hooks[0].Events) != 2 {
		t.Fatalf("hooks: %+v", d.Hooks)
	}
	if d.UpgradeBlocked != "" {
		t.Fatalf("unexpected upgradeBlocked: %s", d.UpgradeBlocked)
	}

	old, err := Get(fixture(t, "apps"), "web", 1, nil)
	if err != nil || old.Revision != 1 || old.LatestRevision != 3 {
		t.Fatalf("revision 1: %+v %v", old, err)
	}
	if _, err := Get(fixture(t, "apps"), "web", 9, nil); !errors.Is(err, ErrNotFound) {
		t.Fatalf("want ErrNotFound, got %v", err)
	}
}

func TestStuckDetection(t *testing.T) {
	d, err := Get(fixture(t, "tools"), "worker", 0, nil)
	if err != nil {
		t.Fatal(err)
	}
	if d.Stuck == nil || d.Stuck.Status != "pending-upgrade" || d.Stuck.RollbackTo != 1 {
		t.Fatalf("stuck: %+v", d.Stuck)
	}
	_, err = Upgrade(context.Background(), fixture(t, "tools"), UpgradeRequest{Namespace: "tools", Name: "worker", Values: "replicas: 1", DryRun: true})
	var se *StuckError
	if !errors.As(err, &se) || se.RollbackTo != 1 || !strings.Contains(err.Error(), "Roll back to revision 1") {
		t.Fatalf("want StuckError, got %v", err)
	}
	// A stuck first install has nothing to roll back to.
	cfg := testConfig(t, "tools", mkRelease("fresh", "tools", 1, release.StatusPendingInstall, 1))
	d, _ = Get(cfg, "fresh", 0, nil)
	if d.Stuck == nil || d.Stuck.RollbackTo != 0 || !strings.Contains(d.Stuck.Remedy, "uninstall") {
		t.Fatalf("pending-install: %+v", d.Stuck)
	}
}

func TestDiff(t *testing.T) {
	d, err := Diff(fixture(t, "apps"), "web", 1, 0)
	if err != nil {
		t.Fatal(err)
	}
	if d.From.Revision != 1 || d.To.Revision != 3 || d.From.Values != "replicas: 1\n" || d.To.Values != "replicas: 3\n" {
		t.Fatalf("diff: %+v", d)
	}
	if !strings.Contains(d.From.Manifest, "replicas: 1") || !strings.Contains(d.To.Manifest, "replicas: 3") {
		t.Fatal("manifests not returned")
	}
	if d, err := Diff(fixture(t, "apps"), "web", 0, 2); err != nil || d.From.Revision != 1 {
		t.Fatalf("default from: %+v %v", d, err)
	}
}

func TestRollback(t *testing.T) {
	cfg := fixture(t, "apps")
	res, err := Rollback(cfg, RollbackRequest{Namespace: "apps", Name: "web", Revision: 1})
	if err != nil {
		t.Fatal(err)
	}
	if res.Release == nil || res.Release.Revision != 4 || res.Release.Status != "deployed" {
		t.Fatalf("result: %+v", res.Release)
	}
	last, _ := cfg.Releases.Last("web")
	if last.Manifest != manifestFor("web", 1) || last.Info.Description != "Rollback to 1" {
		t.Fatalf("rolled back release: %q %q", last.Manifest, last.Info.Description)
	}
	prev, _ := cfg.Releases.Get("web", 3)
	if prev.Info.Status != release.StatusSuperseded {
		t.Fatalf("rev 3 should be superseded, is %s", prev.Info.Status)
	}

	// The remedy for a stuck release.
	cfg = fixture(t, "tools")
	if _, err := Rollback(cfg, RollbackRequest{Namespace: "tools", Name: "worker", Revision: 1}); err != nil {
		t.Fatal(err)
	}
	if d, _ := Get(cfg, "worker", 0, nil); d.Stuck != nil || d.Status != "deployed" {
		t.Fatalf("still stuck: %+v", d.Stuck)
	}

	// Dry run changes nothing.
	cfg = fixture(t, "apps")
	res, err = Rollback(cfg, RollbackRequest{Namespace: "apps", Name: "web", Revision: 1, DryRun: true})
	if err != nil || !res.DryRun {
		t.Fatal(err)
	}
	if h, _ := History(cfg, "web"); len(h) != 3 {
		t.Fatalf("dry run created a revision: %d", len(h))
	}
	if _, err := Rollback(cfg, RollbackRequest{Namespace: "apps", Name: "web", Revision: 7}); !errors.Is(err, ErrNotFound) {
		t.Fatalf("want ErrNotFound, got %v", err)
	}
}

func TestUninstall(t *testing.T) {
	cfg := fixture(t, "apps")
	if _, err := Uninstall(cfg, UninstallRequest{Namespace: "apps", Name: "web", DryRun: true}); err != nil {
		t.Fatal(err)
	}
	if h, _ := History(cfg, "web"); len(h) != 3 {
		t.Fatal("dry run removed history")
	}
	if _, err := Uninstall(cfg, UninstallRequest{Namespace: "apps", Name: "web", KeepHistory: true}); err != nil {
		t.Fatal(err)
	}
	if last, _ := cfg.Releases.Last("web"); last.Info.Status != release.StatusUninstalled {
		t.Fatalf("keepHistory: %s", last.Info.Status)
	}
	if _, err := Uninstall(cfg, UninstallRequest{Namespace: "apps", Name: "api"}); err != nil {
		t.Fatal(err)
	}
	if _, err := History(cfg, "api"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("api should be gone: %v", err)
	}
	if _, err := Uninstall(cfg, UninstallRequest{Namespace: "apps", Name: "nope"}); !errors.Is(err, ErrNotFound) {
		t.Fatalf("want ErrNotFound, got %v", err)
	}
}

func TestUpgrade(t *testing.T) {
	cfg := fixture(t, "apps")
	res, err := Upgrade(context.Background(), cfg, UpgradeRequest{Namespace: "apps", Name: "web", Values: "replicas: 5\n", DryRun: true})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(res.Manifest, "replicas: 5") || !strings.Contains(res.CurrentManifest, "replicas: 3") || res.Notes != "Hello web" {
		t.Fatalf("dry run: manifest=%q current=%q notes=%q", res.Manifest, res.CurrentManifest, res.Notes)
	}
	if h, _ := History(cfg, "web"); len(h) != 3 {
		t.Fatal("dry run created a revision")
	}
	res, err = Upgrade(context.Background(), cfg, UpgradeRequest{Namespace: "apps", Name: "web", Values: "replicas: 5\n"})
	if err != nil {
		t.Fatal(err)
	}
	if res.Release.Revision != 4 || res.Release.Status != "deployed" {
		t.Fatalf("upgrade: %+v", res.Release)
	}
	if d, _ := Get(cfg, "web", 0, nil); d.Values != "replicas: 5\n" {
		t.Fatalf("values after upgrade: %q", d.Values)
	}
	if _, err := Upgrade(context.Background(), cfg, UpgradeRequest{Namespace: "apps", Name: "web", Values: "replicas: [", DryRun: true}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("want ErrInvalid for bad YAML, got %v", err)
	}
}
