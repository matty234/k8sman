package server

import (
	"encoding/json"
	"fmt"
	"strconv"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"

	"github.com/matty234/k8sman/backend/internal/httpx"
)

// externalSecretsModule is the External Secrets Operator integration on
// the backend: one action, externalsecrets-refresh, which sets the
// force-sync annotation ESO documents for refreshing an ExternalSecret (or
// PushSecret) now. Everything else is read-only and lives in the UI.
//
// The bundled external-secrets plugin replaces it (plugins/bundled): the
// module is off unless settings' plugins.useModule names the plugin (see
// moduleOff).
type externalSecretsModule struct{}

func (m *externalSecretsModule) Name() string { return "external_secrets" }

func (m *externalSecretsModule) Routes(httpx.Router, Deps) {}

func (m *externalSecretsModule) ActionTargets() map[string][]string {
	return map[string][]string{
		"externalsecrets-refresh": {"external-secrets.io/externalsecrets", "external-secrets.io/pushsecrets"},
	}
}

// esForceSyncPatch is the merge patch for externalsecrets-refresh.
func esForceSyncPatch(now time.Time) map[string]any {
	return map[string]any{"metadata": map[string]any{"annotations": map[string]any{"force-sync": strconv.FormatInt(now.Unix(), 10)}}}
}

func (m *externalSecretsModule) RunAction(a ActionCall) (ActionResult, error) {
	res := ActionResult{DryRun: a.DryRun, Context: a.Clients.Context}
	if a.Action != "externalsecrets-refresh" {
		return res, httpx.BadRequest("unknown action %q", a.Action)
	}
	b, _ := json.Marshal(esForceSyncPatch(time.Now()))
	if _, err := a.Resource.Patch(a.Ctx, a.Name, types.MergePatchType, b, metav1.PatchOptions{FieldManager: fieldManager, DryRun: a.DryRunOpt}); err != nil {
		return res, err
	}
	res.Message = fmt.Sprintf("Refresh requested for %s", a.Name)
	return res, nil
}
