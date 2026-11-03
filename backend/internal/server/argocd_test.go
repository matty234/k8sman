package server

import (
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"
)

func argoApp(t *testing.T, s string) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal([]byte(s), &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func asJSON(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}

const manualApp = `{
  "metadata": {"name": "web", "resourceVersion": "42"},
  "spec": {
    "source": {"repoURL": "https://example.com/repo", "path": "web", "targetRevision": "main"},
    "syncPolicy": {"syncOptions": ["CreateNamespace=true"], "retry": {"limit": 2}}
  },
  "status": {"operationState": {"phase": "Succeeded"}}
}`

func TestArgoRefreshPatch(t *testing.T) {
	if got := asJSON(argoRefreshPatch(false)); got != `{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"normal"}}}` {
		t.Errorf("normal: %s", got)
	}
	if got := asJSON(argoRefreshPatch(true)); got != `{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}` {
		t.Errorf("hard: %s", got)
	}
}

func TestArgoSyncPatchManual(t *testing.T) {
	p, err := argoSyncPatch(argoApp(t, manualApp), argoActionRequest{Prune: true})
	if err != nil {
		t.Fatal(err)
	}
	want := argoApp(t, `{
	  "metadata": {"resourceVersion": "42"},
	  "operation": {
	    "initiatedBy": {"username": "k8sman"},
	    "retry": {"limit": 2},
	    "sync": {
	      "prune": true,
	      "revision": "main",
	      "source": {"repoURL": "https://example.com/repo", "path": "web", "targetRevision": "main"},
	      "syncOptions": ["CreateNamespace=true"]
	    }
	  },
	  "status": {"operationState": null}
	}`)
	if got := argoApp(t, asJSON(p)); !reflect.DeepEqual(got, want) {
		t.Errorf("patch:\n got %s\nwant %s", asJSON(got), asJSON(want))
	}
}

func TestArgoSyncPatchOptions(t *testing.T) {
	p, err := argoSyncPatch(argoApp(t, manualApp), argoActionRequest{SyncDryRun: true, TargetRevision: "abc123", SyncOptions: []string{"ServerSideApply=true"}})
	if err != nil {
		t.Fatal(err)
	}
	sync := p["operation"].(map[string]any)["sync"].(map[string]any)
	if sync["dryRun"] != true || sync["revision"] != "abc123" || sync["prune"] != false {
		t.Errorf("sync: %s", asJSON(sync))
	}
	if asJSON(sync["syncOptions"]) != `["ServerSideApply=true"]` {
		t.Errorf("syncOptions should override the app's: %s", asJSON(sync["syncOptions"]))
	}
}

func TestArgoSyncPatchDefaultsHEAD(t *testing.T) {
	app := argoApp(t, `{"metadata":{"resourceVersion":"1"},"spec":{"source":{"repoURL":"r","path":"p"}}}`)
	p, err := argoSyncPatch(app, argoActionRequest{})
	if err != nil {
		t.Fatal(err)
	}
	sync := p["operation"].(map[string]any)["sync"].(map[string]any)
	if sync["revision"] != "HEAD" {
		t.Errorf("revision = %v", sync["revision"])
	}
	if _, ok := sync["syncOptions"]; ok {
		t.Error("no syncOptions expected")
	}
	if _, ok := p["operation"].(map[string]any)["retry"]; ok {
		t.Error("no retry expected")
	}
}

func TestArgoSyncPatchMultiSource(t *testing.T) {
	app := argoApp(t, `{"metadata":{"resourceVersion":"1"},"spec":{"sources":[{"repoURL":"a","path":"x"},{"repoURL":"b","ref":"values"}]}}`)
	p, err := argoSyncPatch(app, argoActionRequest{})
	if err != nil {
		t.Fatal(err)
	}
	sync := p["operation"].(map[string]any)["sync"].(map[string]any)
	if _, ok := sync["revision"]; ok {
		t.Error("multi-source sync must not set revision")
	}
	if len(sync["sources"].([]any)) != 2 {
		t.Errorf("sources: %s", asJSON(sync["sources"]))
	}
	if _, err := argoSyncPatch(app, argoActionRequest{TargetRevision: "v1"}); err == nil {
		t.Error("expected an error for a revision on a multi-source app")
	}
}

func TestArgoSyncPatchAutomatedRevision(t *testing.T) {
	app := argoApp(t, `{"metadata":{"resourceVersion":"1"},"spec":{"source":{"repoURL":"r","targetRevision":"main"},"syncPolicy":{"automated":{"prune":true}}}}`)
	if _, err := argoSyncPatch(app, argoActionRequest{TargetRevision: "other"}); err == nil || !strings.Contains(err.Error(), "auto-sync") {
		t.Errorf("expected auto-sync refusal, got %v", err)
	}
	// Same revision, and dry runs, are fine.
	if _, err := argoSyncPatch(app, argoActionRequest{TargetRevision: "main"}); err != nil {
		t.Error(err)
	}
	if _, err := argoSyncPatch(app, argoActionRequest{TargetRevision: "other", SyncDryRun: true}); err != nil {
		t.Error(err)
	}
	// automated.enabled=false (Argo CD 3.x) is manual.
	app = argoApp(t, `{"metadata":{"resourceVersion":"1"},"spec":{"source":{"repoURL":"r","targetRevision":"main"},"syncPolicy":{"automated":{"enabled":false}}}}`)
	if _, err := argoSyncPatch(app, argoActionRequest{TargetRevision: "other"}); err != nil {
		t.Error(err)
	}
}

func TestArgoSyncPatchRefusesRunning(t *testing.T) {
	running := argoApp(t, `{"metadata":{"resourceVersion":"1"},"spec":{"source":{"repoURL":"r"}},"operation":{"sync":{}},"status":{"operationState":{"phase":"Running"}}}`)
	if _, err := argoSyncPatch(running, argoActionRequest{}); !errors.Is(err, errArgoBusy) {
		t.Errorf("expected busy, got %v", err)
	}
	pending := argoApp(t, `{"metadata":{"resourceVersion":"1"},"spec":{"source":{"repoURL":"r"}},"operation":{"sync":{}}}`)
	if _, err := argoSyncPatch(pending, argoActionRequest{}); !errors.Is(err, errArgoBusy) {
		t.Errorf("expected busy for a pending operation, got %v", err)
	}
	if _, err := argoSyncPatch(running, argoActionRequest{Force: true}); err != nil {
		t.Errorf("force should override: %v", err)
	}
	deleting := argoApp(t, `{"metadata":{"resourceVersion":"1","deletionTimestamp":"2024-01-01T00:00:00Z"},"spec":{"source":{"repoURL":"r"}}}`)
	if _, err := argoSyncPatch(deleting, argoActionRequest{}); err == nil {
		t.Error("expected refusal for a deleting app")
	}
}

func TestArgoTerminatePatch(t *testing.T) {
	running := argoApp(t, `{"metadata":{"resourceVersion":"7"},"operation":{"sync":{}},"status":{"operationState":{"phase":"Running"}}}`)
	p, err := argoTerminatePatch(running)
	if err != nil {
		t.Fatal(err)
	}
	if got := asJSON(p); got != `{"metadata":{"resourceVersion":"7"},"status":{"operationState":{"phase":"Terminating"}}}` {
		t.Errorf("patch: %s", got)
	}
	if _, err := argoTerminatePatch(argoApp(t, manualApp)); err == nil {
		t.Error("expected an error with no running operation")
	}
}

func TestArgoActionRequestDecode(t *testing.T) {
	var req ActionRequest
	if err := json.Unmarshal([]byte(`{"hard":true,"prune":true,"syncDryRun":true,"targetRevision":"v2","syncOptions":["A=b"],"force":true,"dryRun":true}`), &req); err != nil {
		t.Fatal(err)
	}
	a := req.argoActionRequest
	if !a.Hard || !a.Prune || !a.SyncDryRun || a.TargetRevision != "v2" || len(a.SyncOptions) != 1 || !a.Force || !req.DryRun {
		t.Errorf("decoded %+v", req)
	}
}
