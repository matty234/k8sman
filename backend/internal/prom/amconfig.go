package prom

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strings"

	"github.com/matty234/k8sman/backend/internal/httpx"
	"gopkg.in/yaml.v3"
)

// AMRoute is one node of Alertmanager's routing tree.
type AMRoute struct {
	Receiver            string   `json:"receiver,omitempty"`
	Matchers            []string `json:"matchers,omitempty"`
	GroupBy             []string `json:"groupBy,omitempty"`
	Continue            bool     `json:"continue,omitempty"`
	GroupWait           string   `json:"groupWait,omitempty"`
	GroupInterval       string   `json:"groupInterval,omitempty"`
	RepeatInterval      string   `json:"repeatInterval,omitempty"`
	MuteTimeIntervals   []string `json:"muteTimeIntervals,omitempty"`
	ActiveTimeIntervals []string `json:"activeTimeIntervals,omitempty"`
	// Source is the AlertmanagerConfig the route came from: the operator
	// names its receivers `<namespace>/<name>/<receiver>`.
	Source *RuleSource `json:"source,omitempty"`
	Routes []AMRoute   `json:"routes,omitempty"`
}

// AMIntegration is one kind of notifier in a receiver (slack, email, ...).
type AMIntegration struct {
	Type  string `json:"type"`
	Count int    `json:"count"`
}

// AMReceiver names a receiver and the kinds of notifier it uses; no
// settings (URLs, keys) are passed on.
type AMReceiver struct {
	Name         string          `json:"name"`
	Integrations []AMIntegration `json:"integrations"`
	Source       *RuleSource     `json:"source,omitempty"`
}

// AMInhibitRule mutes target alerts while a source alert fires.
type AMInhibitRule struct {
	SourceMatchers []string `json:"sourceMatchers"`
	TargetMatchers []string `json:"targetMatchers"`
	Equal          []string `json:"equal,omitempty"`
}

// AMTimeInterval is a named set of time ranges (mute/active intervals).
type AMTimeInterval struct {
	Name    string   `json:"name"`
	Ranges  int      `json:"ranges"`
	Summary []string `json:"summary,omitempty"`
}

// AMStatus is the GET /api/prom/alertmanager payload: Alertmanager's
// running config, parsed and redacted.
type AMStatus struct {
	Alertmanager  *Instance        `json:"alertmanager"`
	Version       string           `json:"version,omitempty"`
	Uptime        string           `json:"uptime,omitempty"`
	ClusterStatus string           `json:"clusterStatus,omitempty"`
	Peers         int              `json:"peers"`
	Route         *AMRoute         `json:"route,omitempty"`
	Receivers     []AMReceiver     `json:"receivers"`
	InhibitRules  []AMInhibitRule  `json:"inhibitRules"`
	TimeIntervals []AMTimeInterval `json:"timeIntervals"`
	// Config is the running config as YAML with secrets redacted.
	Config string `json:"config,omitempty"`
}

type amStatusRaw struct {
	Cluster struct {
		Status string `json:"status"`
		Peers  []any  `json:"peers"`
	} `json:"cluster"`
	Config struct {
		Original string `json:"original"`
	} `json:"config"`
	Uptime      string `json:"uptime"`
	VersionInfo struct {
		Version string `json:"version"`
	} `json:"versionInfo"`
}

func fetchAMStatus(ctx context.Context, r requester, am *Instance) (*AMStatus, error) {
	var raw amStatusRaw
	if err := getJSON(ctx, r, am, "/api/v2/status", nil, &raw); err != nil {
		return nil, err
	}
	st, err := ParseAMConfig(raw.Config.Original)
	if err != nil {
		return nil, &UpstreamError{Status: 502, Message: "parse alertmanager config: " + err.Error()}
	}
	st.Alertmanager = am
	st.Version, st.Uptime = raw.VersionInfo.Version, raw.Uptime
	st.ClusterStatus, st.Peers = raw.Cluster.Status, len(raw.Cluster.Peers)
	return st, nil
}

// ParseAMConfig reads Alertmanager's config YAML into the routing tree,
// receivers (notifier kinds only), inhibit rules and time intervals, and
// a redacted copy of the YAML.
func ParseAMConfig(src string) (*AMStatus, error) {
	st := &AMStatus{Receivers: []AMReceiver{}, InhibitRules: []AMInhibitRule{}, TimeIntervals: []AMTimeInterval{}}
	var doc map[string]any
	if err := yaml.Unmarshal([]byte(src), &doc); err != nil {
		return nil, err
	}
	if doc == nil {
		return st, nil
	}
	if r, ok := doc["route"].(map[string]any); ok {
		route := parseRoute(r, 0)
		st.Route = &route
	}
	for _, x := range asList(doc["receivers"]) {
		m, _ := x.(map[string]any)
		rc := AMReceiver{Name: str(m["name"]), Integrations: []AMIntegration{}, Source: amcfgSource(str(m["name"]))}
		var keys []string
		for k := range m {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			if !strings.HasSuffix(k, "_configs") {
				continue
			}
			if n := len(asList(m[k])); n > 0 {
				rc.Integrations = append(rc.Integrations, AMIntegration{Type: strings.TrimSuffix(k, "_configs"), Count: n})
			}
		}
		st.Receivers = append(st.Receivers, rc)
	}
	for _, x := range asList(doc["inhibit_rules"]) {
		m, _ := x.(map[string]any)
		st.InhibitRules = append(st.InhibitRules, AMInhibitRule{
			SourceMatchers: matchersOf(m, "source_matchers", "source_match", "source_match_re"),
			TargetMatchers: matchersOf(m, "target_matchers", "target_match", "target_match_re"),
			Equal:          strList(m["equal"]),
		})
	}
	for _, key := range []string{"time_intervals", "mute_time_intervals"} {
		for _, x := range asList(doc[key]) {
			m, _ := x.(map[string]any)
			ti := AMTimeInterval{Name: str(m["name"])}
			for _, r := range asList(m["time_intervals"]) {
				ti.Ranges++
				if rm, ok := r.(map[string]any); ok {
					ti.Summary = append(ti.Summary, summariseInterval(rm))
				}
			}
			st.TimeIntervals = append(st.TimeIntervals, ti)
		}
	}
	red := Redact(doc)
	if b, err := yaml.Marshal(red); err == nil {
		st.Config = string(b)
		if len(st.Config) > 256<<10 {
			st.Config = st.Config[:256<<10] + "\n# … truncated\n"
		}
	}
	return st, nil
}

func parseRoute(m map[string]any, depth int) AMRoute {
	r := AMRoute{
		Receiver:            str(m["receiver"]),
		Matchers:            matchersOf(m, "matchers", "match", "match_re"),
		GroupBy:             strList(m["group_by"]),
		GroupWait:           str(m["group_wait"]),
		GroupInterval:       str(m["group_interval"]),
		RepeatInterval:      str(m["repeat_interval"]),
		MuteTimeIntervals:   strList(m["mute_time_intervals"]),
		ActiveTimeIntervals: strList(m["active_time_intervals"]),
		Source:              amcfgSource(str(m["receiver"])),
	}
	r.Continue, _ = m["continue"].(bool)
	if depth > 20 {
		return r
	}
	for _, x := range asList(m["routes"]) {
		if cm, ok := x.(map[string]any); ok {
			r.Routes = append(r.Routes, parseRoute(cm, depth+1))
		}
	}
	return r
}

// amcfgSource: the operator prefixes receivers from an AlertmanagerConfig
// with `<namespace>/<name>/`.
func amcfgSource(receiver string) *RuleSource {
	parts := strings.Split(receiver, "/")
	if len(parts) == 3 && parts[0] != "" && parts[1] != "" {
		return &RuleSource{Namespace: parts[0], Name: parts[1]}
	}
	return nil
}

// matchersOf reads a list of matcher strings plus the legacy match /
// match_re maps as `name="value"` / `name=~"value"`.
func matchersOf(m map[string]any, list, eq, re string) []string {
	out := strList(m[list])
	add := func(key, op string) {
		mm, _ := m[key].(map[string]any)
		var keys []string
		for k := range mm {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			out = append(out, fmt.Sprintf("%s%s%q", k, op, str(mm[k])))
		}
	}
	add(eq, "=")
	add(re, "=~")
	return out
}

func summariseInterval(m map[string]any) string {
	var parts []string
	for _, k := range []string{"weekdays", "days_of_month", "months", "years"} {
		if l := strList(m[k]); len(l) > 0 {
			parts = append(parts, strings.Join(l, ","))
		}
	}
	for _, t := range asList(m["times"]) {
		if tm, ok := t.(map[string]any); ok {
			parts = append(parts, str(tm["start_time"])+"–"+str(tm["end_time"]))
		}
	}
	if loc := str(m["location"]); loc != "" {
		parts = append(parts, loc)
	}
	if len(parts) == 0 {
		return "always"
	}
	return strings.Join(parts, " ")
}

func asList(v any) []any {
	l, _ := v.([]any)
	return l
}

func str(v any) string {
	if v == nil {
		return ""
	}
	if s, ok := v.(string); ok {
		return s
	}
	return fmt.Sprint(v)
}

func strList(v any) []string {
	var out []string
	for _, x := range asList(v) {
		out = append(out, str(x))
	}
	return out
}

// ---- redaction --------------------------------------------------------------

const redacted = "<redacted>"

// secretKeyRe matches config keys whose values are credentials.
var secretKeyRe = regexp.MustCompile(`(?i)(password|passwd|secret|token|_key|^key$|apikey|credentials|authorization|bearer|private|webhook_url|api_url|cookie)`)

// headerKeyRe: maps of HTTP headers, whose values are often credentials.
var headerKeyRe = regexp.MustCompile(`(?i)^(headers|http_headers)$`)

// Redact returns a copy of a decoded YAML/JSON tree with credentials
// replaced: values under secret-looking keys (passwords, tokens, API and
// routing keys, *_secret, authorization), every HTTP header value, and the
// path, query and user info of any URL (webhook URLs carry tokens). File
// paths (`*_file`) are kept: they name a file, not its content.
func Redact(v any) any { return redact(v, "") }

func redact(v any, key string) any {
	switch x := v.(type) {
	case map[string]any:
		out := make(map[string]any, len(x))
		for k, val := range x {
			switch {
			case headerKeyRe.MatchString(k):
				out[k] = redactAll(val)
			case isSecretKey(k):
				out[k] = redactLeaf(val)
			default:
				out[k] = redact(val, k)
			}
		}
		return out
	case []any:
		out := make([]any, len(x))
		for i, val := range x {
			out[i] = redact(val, key)
		}
		return out
	case string:
		return redactString(x)
	}
	return v
}

func isSecretKey(k string) bool {
	if strings.HasSuffix(strings.ToLower(k), "_file") {
		return false
	}
	return secretKeyRe.MatchString(k)
}

// redactLeaf replaces scalars (and every scalar below a map or list).
func redactLeaf(v any) any {
	switch x := v.(type) {
	case map[string]any, []any:
		return redactAll(x)
	case nil:
		return nil
	case string:
		if x == "" || x == "<secret>" {
			return x
		}
	}
	return redacted
}

func redactAll(v any) any {
	switch x := v.(type) {
	case map[string]any:
		out := make(map[string]any, len(x))
		for k, val := range x {
			out[k] = redactAll(val)
		}
		return out
	case []any:
		out := make([]any, len(x))
		for i, val := range x {
			out[i] = redactAll(val)
		}
		return out
	case nil:
		return nil
	}
	return redacted
}

var authValueRe = regexp.MustCompile(`(?i)^\s*(bearer|basic|token)\s+\S`)

// redactString strips credentials from a free-standing string: auth header
// values, and the user info, path and query of URLs.
func redactString(s string) string {
	if authValueRe.MatchString(s) {
		return redacted
	}
	if !strings.Contains(s, "://") {
		return s
	}
	u, err := url.Parse(strings.TrimSpace(s))
	if err != nil || u.Scheme == "" || u.Host == "" {
		return s
	}
	out := u.Scheme + "://" + u.Host
	if (u.Path != "" && u.Path != "/") || u.RawQuery != "" || u.Fragment != "" || u.User != nil {
		out += "/" + redacted
	}
	return out
}

func (h *Handler) handleAMStatus(w http.ResponseWriter, r *http.Request) {
	e := h.env()
	am, _, err := h.pick(r.Context(), e, KindAlertmanager, r.URL.Query().Get("instance"))
	if err != nil {
		writeErr(w, err)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), readTimeout)
	defer cancel()
	st, err := cachedResult(ctx, &amCfgCache, cacheKey(e, am, "status"), func(ctx context.Context) (*AMStatus, error) {
		return fetchAMStatus(ctx, e.req, am)
	})
	if err != nil {
		writeErr(w, err)
		return
	}
	httpx.WriteJSON(w, 200, st)
}
