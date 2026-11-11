package prom

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/httpx"
)

// shared caches discovery for the HTTP handlers and the overview.
var shared = newDiscoverer()

// Handler serves /api/prom/*.
type Handler struct {
	env      func() env
	disc     *discoverer
	readOnly bool
	now      func() time.Time
}

func envFor(c *cluster.Clients) env {
	e := env{key: c.Context, dyn: c.Dynamic, typed: c.Typed, req: restRequester{rc: c.Typed.CoreV1().RESTClient()}}
	if SettingsSource != nil {
		e.settings = SettingsSource(c.Context)
		// A changed override must not be served from the old discovery.
		if b, _ := json.Marshal(e.settings); len(b) > 2 {
			e.key += "|" + string(b)
		}
	}
	return e
}

// Register mounts the Prometheus endpoints on mux. Mutations (silences)
// are refused with 403 when readOnly.
func Register(mux httpx.Router, mgr *cluster.Manager, readOnly bool) *Handler {
	h := &Handler{env: func() env { return envFor(mgr.Clients()) }, disc: shared, readOnly: readOnly, now: time.Now}
	h.register(mux)
	return h
}

func (h *Handler) register(mux httpx.Router) {
	mux.HandleFunc("GET /api/prom/status", h.handleStatus)
	mux.HandleFunc("GET /api/prom/alerts", h.handleAlerts)
	mux.HandleFunc("GET /api/prom/silences", h.handleSilences)
	mux.HandleFunc("POST /api/prom/silences", h.handleCreateSilence)
	mux.HandleFunc("DELETE /api/prom/silences/{id}", h.handleExpireSilence)
	mux.HandleFunc("GET /api/prom/rules", h.handleRules)
	mux.HandleFunc("GET /api/prom/targets", h.handleTargets)
	mux.HandleFunc("GET /api/prom/query", h.handleQuery)
	mux.HandleFunc("GET /api/prom/query_range", h.handleQueryRange)
	mux.HandleFunc("GET /api/prom/scrape", h.handleScrape)
	mux.HandleFunc("GET /api/prom/applies", h.handleApplies)
	mux.HandleFunc("GET /api/prom/alertmanager", h.handleAMStatus)
	mux.HandleFunc("GET /api/prom/selection", h.handleSelection)
	mux.HandleFunc("GET /api/prom/selectedby", h.handleSelectedBy)
}

// ---- helpers -----------------------------------------------------------------

func writeErr(w http.ResponseWriter, err error) {
	status, reason := http.StatusBadGateway, ""
	var ue *UpstreamError
	switch {
	case errors.As(err, &ue):
		switch {
		case ue.NoInstance:
			status, reason = http.StatusNotFound, "NotFound"
		case ue.Status == 404:
			status = http.StatusNotFound
		case ue.Status == 400 || ue.Status == 422:
			status = http.StatusUnprocessableEntity
		case ue.Status == 504:
			status = http.StatusGatewayTimeout
		case ue.Status == 403:
			status = http.StatusForbidden
		}
	default:
		if c, r, ok := httpx.KubeStatus(err, status); ok {
			status, reason = c, r
		} else if errors.Is(err, httpx.ErrBadRequest) {
			status = http.StatusBadRequest
		}
	}
	httpx.WriteError(w, status, reason, err.Error())
}

func (h *Handler) refuseReadOnly(w http.ResponseWriter) bool {
	if h.readOnly {
		httpx.WriteError(w, http.StatusForbidden, "", "the server is running read-only")
		return true
	}
	return false
}

// pick resolves the instance for a request.
func (h *Handler) pick(ctx context.Context, e env, kind, id string) (*Instance, *Status, error) {
	s := h.disc.get(ctx, e, false)
	in := s.Default(kind, id)
	if in == nil && id != "" {
		return nil, s, &UpstreamError{Status: 404, Message: fmt.Sprintf("%s %q not found", kind, id), NoInstance: true}
	}
	if in == nil {
		return nil, s, &UpstreamError{Status: 404, Message: "no " + kind + " found in the cluster", NoInstance: true}
	}
	return in, s, nil
}

// ---- handlers ----------------------------------------------------------------

func (h *Handler) handleStatus(w http.ResponseWriter, r *http.Request) {
	s := h.disc.get(r.Context(), h.env(), r.URL.Query().Get("refresh") == "true")
	httpx.WriteJSON(w, 200, s)
}

// Alerts returns Alertmanager's alerts (amID selects the instance, "" =
// default) plus Prometheus' pending ones, grouped by alertname.
func (h *Handler) alerts(ctx context.Context, e env, amID, promID string) *AlertsResult {
	s := h.disc.get(ctx, e, false)
	res := &AlertsResult{Groups: []AlertGroup{}, Errors: map[string]string{}}
	res.Alertmanager = s.Default(KindAlertmanager, amID)
	res.Prometheus = s.Default(KindPrometheus, promID)
	if amID != "" && res.Alertmanager == nil {
		res.Errors["alertmanager"] = fmt.Sprintf("alertmanager %q not found", amID)
	}
	// Found nothing because discovery itself failed (the cluster API was
	// unreachable, a list was refused): say so, rather than letting the UI
	// conclude the stack isn't installed and offer to install it.
	if res.Alertmanager == nil && res.Prometheus == nil && len(s.Errors) > 0 {
		res.Errors["discovery"] = discoveryError(s.Errors)
	}

	var (
		wg               sync.WaitGroup
		amAlerts, pAlert []Alert
		amErr, pErr      error
	)
	amOK := res.Alertmanager != nil
	if amOK {
		wg.Add(1)
		go func() {
			defer wg.Done()
			c, cancel := context.WithTimeout(ctx, readTimeout)
			defer cancel()
			amAlerts, amErr = fetchAMAlerts(c, e.req, res.Alertmanager)
		}()
	}
	if res.Prometheus != nil {
		wg.Add(1)
		go func() {
			defer wg.Done()
			c, cancel := context.WithTimeout(ctx, readTimeout)
			defer cancel()
			// Firing alerts come from Alertmanager; only fall back to
			// Prometheus' view when there is no Alertmanager.
			pAlert, pErr = fetchPromAlerts(c, e.req, res.Prometheus, !amOK)
		}()
	}
	wg.Wait()
	if amErr != nil {
		res.Errors["alertmanager"] = amErr.Error()
		// Alertmanager unreachable: show Prometheus' firing alerts instead.
		if res.Prometheus != nil && pErr == nil {
			c, cancel := context.WithTimeout(ctx, readTimeout)
			pAlert, pErr = fetchPromAlerts(c, e.req, res.Prometheus, true)
			cancel()
		}
	}
	if pErr != nil {
		res.Errors["prometheus"] = pErr.Error()
	}
	all := append(amAlerts, pAlert...)
	res.Groups, res.Summary = GroupAlerts(all)
	if len(res.Errors) == 0 {
		res.Errors = nil
	}
	return res
}

func (h *Handler) handleAlerts(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	httpx.WriteJSON(w, 200, h.alerts(r.Context(), h.env(), q.Get("instance"), q.Get("prometheus")))
}

func (h *Handler) handleSilences(w http.ResponseWriter, r *http.Request) {
	e := h.env()
	am, _, err := h.pick(r.Context(), e, KindAlertmanager, r.URL.Query().Get("instance"))
	if err != nil {
		writeErr(w, err)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), readTimeout)
	defer cancel()
	sil, err := fetchSilences(ctx, e.req, am)
	if err != nil {
		writeErr(w, err)
		return
	}
	httpx.WriteJSON(w, 200, map[string]any{"alertmanager": am, "silences": sil})
}

func (h *Handler) handleCreateSilence(w http.ResponseWriter, r *http.Request) {
	if h.refuseReadOnly(w) {
		return
	}
	body, ok := httpx.DecodeJSON[SilenceRequest](w, r, 64<<10)
	if !ok {
		return
	}
	payload, err := body.build(h.now())
	if err != nil {
		writeErr(w, httpx.BadRequest("%v", err))
		return
	}
	e := h.env()
	am, _, err := h.pick(r.Context(), e, KindAlertmanager, r.URL.Query().Get("instance"))
	if err != nil {
		writeErr(w, err)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), readTimeout)
	defer cancel()
	id, err := createSilence(ctx, e.req, am, payload)
	if err != nil {
		writeErr(w, err)
		return
	}
	httpx.WriteJSON(w, 200, map[string]any{"silenceID": id, "alertmanager": am.ID, "startsAt": payload["startsAt"], "endsAt": payload["endsAt"]})
}

func (h *Handler) handleExpireSilence(w http.ResponseWriter, r *http.Request) {
	if h.refuseReadOnly(w) {
		return
	}
	id := r.PathValue("id")
	if !silenceIDRe.MatchString(id) {
		writeErr(w, httpx.BadRequest("invalid silence id"))
		return
	}
	e := h.env()
	am, _, err := h.pick(r.Context(), e, KindAlertmanager, r.URL.Query().Get("instance"))
	if err != nil {
		writeErr(w, err)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), readTimeout)
	defer cancel()
	if err := expireSilence(ctx, e.req, am, id); err != nil {
		writeErr(w, err)
		return
	}
	httpx.WriteJSON(w, 200, map[string]any{"expired": id, "alertmanager": am.ID})
}

func (h *Handler) handleRules(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	e := h.env()
	p, _, err := h.pick(r.Context(), e, KindPrometheus, q.Get("instance"))
	if err != nil {
		writeErr(w, err)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), readTimeout)
	defer cancel()
	var (
		groups []RuleGroup
		refs   []promRuleRef
		gErr   error
		wg     sync.WaitGroup
	)
	wg.Add(2)
	go func() { defer wg.Done(); groups, gErr = fetchRules(ctx, e.req, p) }()
	// Listing PrometheusRules may be forbidden or the CRD absent; mapping
	// then falls back to group names (or nothing).
	go func() { defer wg.Done(); refs, _ = listPrometheusRules(ctx, e.dyn, "") }()
	wg.Wait()
	if gErr != nil {
		writeErr(w, gErr)
		return
	}
	MapRuleSources(groups, refs)
	res := &RulesResult{Prometheus: p, Groups: FilterRuleGroups(groups, q.Get("namespace"), q.Get("name"))}
	if res.Groups == nil {
		res.Groups = []RuleGroup{}
	}
	countRules(res)
	httpx.WriteJSON(w, 200, res)
}

func (h *Handler) handleTargets(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	e := h.env()
	p, _, err := h.pick(r.Context(), e, KindPrometheus, q.Get("instance"))
	if err != nil {
		writeErr(w, err)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), readTimeout)
	defer cancel()
	raw, err := cachedTargets(ctx, e, p)
	if err != nil {
		writeErr(w, err)
		return
	}
	res := GroupTargets(raw, TargetFilter{Kind: q.Get("kind"), Namespace: q.Get("namespace"), Name: q.Get("name")})
	res.Prometheus = p
	httpx.WriteJSON(w, 200, res)
}

func (h *Handler) handleQuery(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	query := q.Get("query")
	if err := validateQuery(query); err != nil {
		writeErr(w, httpx.BadRequest("%v", err))
		return
	}
	at := ""
	if v := q.Get("time"); v != "" {
		t, err := parseTimeParam(v, h.now())
		if err != nil {
			writeErr(w, httpx.BadRequest("%v", err))
			return
		}
		at = unix(t)
	}
	e := h.env()
	p, _, err := h.pick(r.Context(), e, KindPrometheus, q.Get("instance"))
	if err != nil {
		writeErr(w, err)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), queryTimeout)
	defer cancel()
	res, err := runQuery(ctx, e.req, p, query, at)
	if err != nil {
		writeErr(w, err)
		return
	}
	httpx.WriteJSON(w, 200, res)
}

func (h *Handler) handleQueryRange(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	query := q.Get("query")
	if err := validateQuery(query); err != nil {
		writeErr(w, httpx.BadRequest("%v", err))
		return
	}
	rp, err := ParseRange(q, h.now())
	if err != nil {
		writeErr(w, httpx.BadRequest("%v", err))
		return
	}
	e := h.env()
	p, _, err := h.pick(r.Context(), e, KindPrometheus, q.Get("instance"))
	if err != nil {
		writeErr(w, err)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), queryTimeout)
	defer cancel()
	res, err := runRangeQuery(ctx, e.req, p, query, rp)
	if err != nil {
		writeErr(w, err)
		return
	}
	httpx.WriteJSON(w, 200, res)
}

// ActiveAlerts returns the firing (not silenced or inhibited) alerts of the
// default Alertmanager for the overview. It returns nil, nil when no
// Alertmanager is installed, and gives up quickly so the overview isn't
// held up by a slow or broken instance.
func ActiveAlerts(ctx context.Context, c *cluster.Clients) ([]Alert, error) {
	e := envFor(c)
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	s := shared.get(ctx, e, false)
	am := s.Default(KindAlertmanager, "")
	if am == nil {
		return nil, nil
	}
	alerts, err := fetchAMAlerts(ctx, e.req, am)
	if err != nil {
		return nil, fmt.Errorf("alertmanager %s: %w", am.ID, err)
	}
	out := alerts[:0]
	for _, a := range alerts {
		if a.State == StateFiring {
			out = append(out, a)
		}
	}
	return out, nil
}

// discoveryError joins discovery's errors into one line, in a stable order.
func discoveryError(errs map[string]string) string {
	keys := make([]string, 0, len(errs))
	for k := range errs {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, len(keys))
	for i, k := range keys {
		parts[i] = k + ": " + errs[k]
	}
	return strings.Join(parts, "; ")
}
