package server

import (
	"encoding/json"
	"errors"
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
