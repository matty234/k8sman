package server

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/hubble"
	observerpb "github.com/matty234/k8sman/backend/internal/hubble/pb/observer"
	"github.com/matty234/k8sman/backend/internal/overview"
)

// hubbleModule is the Cilium Hubble integration: relay discovery and
// status, live flows over a WebSocket, grouped drops, "can A reach B" and
// the namespace traffic map, all read from Hubble Relay over gRPC through
// an in-process port-forward (see internal/hubble). Read-only: it changes
// nothing in the cluster.
type hubbleModule struct {
	d   Deps
	hub *hubble.Hub

	dropsMu    sync.Mutex
	dropsCache map[string]hubbleDropsEntry

	// The traffic maps being counted, per context and settings; each
	// stops after hubble.TrafficIdle without a request.
	mapsMu sync.Mutex
	maps   map[string]*hubble.Traffic
}

type hubbleDropsEntry struct {
	at         time.Time
	flows      []hubble.Flow
	err        error
	refreshing bool
}

const (
	hubbleID = "hubble"
	// Overview findings look at drops in this window, and only flag a
	// namespace with at least overviewMinDrops of them.
	overviewDropWindow = 5 * time.Minute
	overviewMinDrops   = 5
	overviewDropsTTL   = time.Minute
)

func (m *hubbleModule) Name() string { return hubbleID }

func (m *hubbleModule) Routes(r httpx.Router, d Deps) {
	m.d = d
	m.hub = hubble.NewHub()
	m.dropsCache = map[string]hubbleDropsEntry{}
	m.maps = map[string]*hubble.Traffic{}
	r.HandleFunc("GET /api/hubble/status", m.handleStatus)
	r.HandleFunc("GET /api/hubble/flows", m.handleFlows)
	r.HandleFunc("GET /api/hubble/drops", m.handleDrops)
	r.HandleFunc("GET /api/hubble/connectivity", m.handleConnectivity)
	r.HandleFunc("GET /api/hubble/map", m.handleMap)
}

// ValidateSettings implements Configurable.
func (m *hubbleModule) ValidateSettings(raw json.RawMessage) error {
	var s hubble.Settings
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&s); err != nil {
		return err
	}
	return s.Validate()
}

func (m *hubbleModule) settings(c *cluster.Clients) hubble.Settings {
	var s hubble.Settings
	_, _ = m.d.Settings.ModuleSettings(hubbleID, c.Context, &s)
	return s
}

func (m *hubbleModule) handleStatus(w http.ResponseWriter, r *http.Request) {
	c := m.d.Mgr.Clients()
	httpx.WriteJSON(w, http.StatusOK, m.hub.Status(r.Context(), c, m.settings(c), r.URL.Query().Get("refresh") == "true"))
}

// observer connects to the relay or writes 503 (reason HubbleUnavailable).
func (m *hubbleModule) observer(w http.ResponseWriter, r *http.Request) (observerpb.ObserverClient, bool) {
	c := m.d.Mgr.Clients()
	obs, _, err := m.hub.Observer(r.Context(), c, m.settings(c))
	if err != nil {
		httpx.WriteJSON(w, http.StatusServiceUnavailable, apiError{Error: hubble.ErrorMessage(err), Code: http.StatusServiceUnavailable, Reason: "HubbleUnavailable"})
		return nil, false
	}
	return obs, true
}

// handleFlows streams flows as batched frames (hubble.Frame). Bad
// parameters are a 400 before the upgrade; a relay that can't be reached
// is reported in an error frame.
func (m *hubbleModule) handleFlows(w http.ResponseWriter, r *http.Request) {
	q, err := hubble.ParseQuery(r.URL.Query())
	if err != nil {
		writeErr(w, httpx.BadRequest("%v", err))
		return
	}
	if r.URL.Query().Get("follow") == "" {
		q.Follow = true
	}
	if q.Follow && q.Last == 0 && q.Since == 0 {
		// Some history before the live tail. By time, not count: with a
		// count the relay gathers and sorts every node's buffer first
		// (seconds on a busy cluster), and a cluster-wide minute is too
		// much to sort anyway.
		q.Since = 5 * time.Second
		if q.Narrow() {
			q.Since = 5 * time.Minute
		}
	}
	c := m.d.Mgr.Clients()
	ws, ctx, cancel, err := upgrade(w, r)
	if err != nil {
		return
	}
	defer cancel()
	defer ws.close()
	obs, _, err := m.hub.Observer(ctx, c, m.settings(c))
	if err != nil {
		_ = ws.send(hubble.Frame{Error: hubble.ErrorMessage(err), End: true})
		return
	}
	err = hubble.Stream(ctx, obs, q.Request(time.Now()), func(f hubble.Frame) error { return ws.send(f) })
	if err != nil && ctx.Err() == nil {
		_ = ws.send(hubble.Frame{Error: hubble.ErrorMessage(err), End: true})
	}
}

// handleDrops groups recent drops: ?namespace (comma-separated), since
// (default 15m), last (default 1000).
func (m *hubbleModule) handleDrops(w http.ResponseWriter, r *http.Request) {
	v := r.URL.Query()
	if v.Get("since") == "" {
		v.Set("since", "15m")
	}
	if v.Get("last") == "" {
		v.Set("last", "1000")
	}
	v.Set("verdict", "DROPPED")
	v.Del("follow")
	q, err := hubble.ParseQuery(v)
	if err != nil {
		writeErr(w, httpx.BadRequest("%v", err))
		return
	}
	obs, ok := m.observer(w, r)
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	res, err := hubble.Collect(ctx, obs, q.Request(time.Now()), int(q.Last))
	if err != nil {
		writeHubbleErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, hubble.Drops{
		Groups: hubble.GroupDrops(res.Flows), Flows: len(res.Flows), Truncated: uint64(len(res.Flows)) >= q.Last,
		Lost: res.Lost, Since: q.Since.String(), Oldest: timePtr(res.Oldest()), Partial: res.Partial,
	})
}

func timePtr(t time.Time) *time.Time {
	if t.IsZero() {
		return nil
	}
	return &t
}

// handleConnectivity answers "can A reach B": ?from, to (endpoint specs,
// see hubble.ParseQuery), since (default 15m).
func (m *hubbleModule) handleConnectivity(w http.ResponseWriter, r *http.Request) {
	v := r.URL.Query()
	from, to := v.Get("from"), v.Get("to")
	if from == "" || to == "" {
		writeErr(w, httpx.BadRequest("from and to are required"))
		return
	}
	if v.Get("since") == "" {
		v.Set("since", "15m")
	}
	v.Set("last", "1000")
	v.Del("follow")
	fwd, err := hubble.ParseQuery(v)
	if err != nil {
		writeErr(w, httpx.BadRequest("%v", err))
		return
	}
	rev := fwd
	rev.From, rev.To = fwd.To, fwd.From
	if strings.HasPrefix(rev.From, "svc:") {
		// Replies come from the pods behind the service, not the service:
		// count them by the service's namespace instead.
		ns, _, _ := strings.Cut(strings.TrimPrefix(rev.From, "svc:"), "/")
		rev.From = "ns:" + ns
	}
	obs, ok := m.observer(w, r)
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	now := time.Now()
	var wg sync.WaitGroup
	var back hubble.Collected
	var backErr error
	wg.Add(1)
	go func() {
		defer wg.Done()
		back, backErr = hubble.Collect(ctx, obs, rev.Request(now), 1000)
	}()
	there, err := hubble.Collect(ctx, obs, fwd.Request(now), 1000)
	wg.Wait()
	if err == nil {
		err = backErr
	}
	if err != nil {
		writeHubbleErr(w, err)
		return
	}
	res := hubble.Summarise(from, to, fwd.Since, there.Flows, back.Flows)
	res.Lost = there.Lost
	oldest := there.Oldest()
	if o := back.Oldest(); oldest.IsZero() || (!o.IsZero() && o.Before(oldest)) {
		oldest = o
	}
	res.Oldest = timePtr(oldest)
	httpx.WriteJSON(w, http.StatusOK, res)
}

// handleMap returns the traffic between namespaces, and between them and
// the world, over ?window (default 5m, at most 15m). The first request
// starts following the relay for the context; the map keeps counting
// while it is asked for (the app polls it every few seconds while it is
// on screen) and stops a minute after the last request.
func (m *hubbleModule) handleMap(w http.ResponseWriter, r *http.Request) {
	window := 5 * time.Minute
	if v := r.URL.Query().Get("window"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil || d <= 0 || d > hubble.MaxTrafficWindow {
			writeErr(w, httpx.BadRequest("bad window %q (want a duration up to %s)", v, hubble.MaxTrafficWindow))
			return
		}
		window = d
	}
	if _, ok := m.observer(w, r); !ok {
		return
	}
	c := m.d.Mgr.Clients()
	httpx.WriteJSON(w, http.StatusOK, m.traffic(c, m.settings(c)).Snapshot(window))
}

// traffic returns the context's running map, starting one.
func (m *hubbleModule) traffic(c *cluster.Clients, s hubble.Settings) *hubble.Traffic {
	key := fmt.Sprintf("%p|%+v", c, s)
	m.mapsMu.Lock()
	defer m.mapsMu.Unlock()
	if t := m.maps[key]; t != nil {
		return t
	}
	t := hubble.NewTraffic()
	t.Start(func(ctx context.Context) (observerpb.ObserverClient, error) {
		obs, _, err := m.hub.Observer(ctx, c, s)
		return obs, err
	})
	m.maps[key] = t
	go func() {
		tick := time.NewTicker(hubble.TrafficIdle / 4)
		defer tick.Stop()
		for range tick.C {
			if t.Idle() {
				m.mapsMu.Lock()
				if m.maps[key] == t {
					delete(m.maps, key)
				}
				m.mapsMu.Unlock()
				t.Stop()
				return
			}
		}
	}()
	return t
}

func writeHubbleErr(w http.ResponseWriter, err error) {
	httpx.WriteJSON(w, http.StatusBadGateway, apiError{Error: "Hubble Relay: " + hubble.ErrorMessage(err), Code: http.StatusBadGateway, Reason: "HubbleError"})
}

// OverviewInputs adds "Hubble Relay unreachable" and namespaces with
// recent drops. It never waits on the relay: it reports the last status
// and drops it has (refreshed in the background when stale: status 30s,
// drops 1 min), so the first poll after starting shows nothing, and
// overview polls never open a following stream.
func (m *hubbleModule) OverviewInputs(l *OverviewLists) {
	l.Go("hubble", func() (func(*overview.Input), error) {
		s := m.settings(l.Clients)
		st := m.hub.Peek(l.Clients, s)
		var fs []overview.Finding
		switch {
		case st == nil || st.State == hubble.StateNotInstalled || st.State == hubble.StateNoRelay:
			return nil, nil
		case st.State == hubble.StateUnreachable:
			if l.Namespace == "" || l.Namespace == st.Relay.Namespace {
				fs = append(fs, overview.Finding{
					Issue: overview.Issue{
						Severity: overview.Warning, Category: "hubbleRelayUnreachable", Kind: "Service",
						Namespace: st.Relay.Namespace, Name: st.Relay.Service, Reason: "Unreachable",
						Message: "Hubble Relay doesn't answer: " + st.Message,
					},
					Label: "Hubble Relay unreachable", Section: hubbleID,
				})
			}
			return func(in *overview.Input) { in.Findings = append(in.Findings, fs...) }, nil
		}
		e := m.recentDrops(l.Clients, s, l.Namespace)
		if e.err != nil {
			return nil, fmt.Errorf("hubble drops: %s", hubble.ErrorMessage(e.err))
		}
		fs = dropFindings(e.flows, l.Namespace, e.at)
		return func(in *overview.Input) { in.Findings = append(in.Findings, fs...) }, nil
	})
}

// recentDrops returns the last drops read for the context and namespace
// (the last overviewDropWindow, at most 1000), starting a background
// refresh when they are older than overviewDropsTTL.
func (m *hubbleModule) recentDrops(c *cluster.Clients, s hubble.Settings, ns string) hubbleDropsEntry {
	key := fmt.Sprintf("%p|%s", c, ns)
	m.dropsMu.Lock()
	defer m.dropsMu.Unlock()
	e := m.dropsCache[key]
	if !e.refreshing && time.Since(e.at) >= overviewDropsTTL {
		m.dropsCache[key] = hubbleDropsEntry{at: e.at, flows: e.flows, err: e.err, refreshing: true}
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			next := hubbleDropsEntry{}
			obs, _, err := m.hub.Observer(ctx, c, s)
			if err == nil {
				q := hubble.Query{Verdicts: []string{"DROPPED"}, Since: overviewDropWindow, Last: 1000}
				if ns != "" {
					q.Namespaces = []string{ns}
				}
				var res hubble.Collected
				res, err = hubble.Collect(ctx, obs, q.Request(time.Now()), 1000)
				next.flows = res.Flows
			}
			next.at, next.err = time.Now(), err
			m.dropsMu.Lock()
			m.dropsCache[key] = next
			m.dropsMu.Unlock()
		}()
	}
	return e
}

// dropFindings flags namespaces with at least overviewMinDrops drops. A
// drop counts for the destination pod's namespace, else the source's. The
// message gives the span the drops really cover (the relay's buffer may
// hold less than overviewDropWindow).
func dropFindings(flows []hubble.Flow, only string, now time.Time) []overview.Finding {
	span := overviewDropWindow
	if c := (hubble.Collected{Flows: flows}); len(flows) > 0 && now.Sub(c.Oldest()) < span {
		span = now.Sub(c.Oldest()).Round(time.Second)
	}
	type agg struct {
		n       int
		reasons map[string]int
		last    time.Time
	}
	byNS := map[string]*agg{}
	for _, f := range flows {
		ns := f.Dest.Namespace
		if ns == "" || (only != "" && ns != only) {
			ns = f.Source.Namespace
		}
		if ns == "" || (only != "" && ns != only) {
			continue
		}
		a := byNS[ns]
		if a == nil {
			a = &agg{reasons: map[string]int{}}
			byNS[ns] = a
		}
		a.n++
		a.reasons[orUnknownReason(f.DropReason)]++
		if f.Time.After(a.last) {
			a.last = f.Time
		}
	}
	var out []overview.Finding
	for ns, a := range byNS {
		if a.n < overviewMinDrops {
			continue
		}
		reasons := make([]string, 0, len(a.reasons))
		for r := range a.reasons {
			reasons = append(reasons, r)
		}
		sort.Slice(reasons, func(i, j int) bool { return a.reasons[reasons[i]] > a.reasons[reasons[j]] })
		if len(reasons) > 3 {
			reasons = reasons[:3]
		}
		out = append(out, overview.Finding{
			Issue: overview.Issue{
				Severity: overview.Warning, Category: "hubbleDrops", Kind: "Namespace", Name: ns,
				Reason:  "DroppedFlows",
				Message: fmt.Sprintf("%d dropped flows in the last %s (%s)", a.n, shortSpan(span), strings.Join(reasons, ", ")),
				Count:   a.n,
			},
			Label: "Namespaces dropping flows", Section: hubbleID, Since: a.last,
		})
	}
	return out
}

func shortSpan(d time.Duration) string {
	if d >= time.Minute && d%time.Minute == 0 {
		return fmt.Sprintf("%d min", int(d.Minutes()))
	}
	return strings.TrimSuffix(d.String(), "0s")
}

func orUnknownReason(r string) string {
	if r == "" {
		return "unknown reason"
	}
	return r
}
