package prom

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"time"
)

// Matcher is an Alertmanager label matcher.
type Matcher struct {
	Name    string `json:"name"`
	Value   string `json:"value"`
	IsRegex bool   `json:"isRegex"`
	// IsEqual is false for != / !~ matchers. Defaults to true.
	IsEqual *bool `json:"isEqual,omitempty"`
}

// Silence is an Alertmanager silence.
type Silence struct {
	ID        string    `json:"id"`
	State     string    `json:"state"` // active | pending | expired
	Matchers  []Matcher `json:"matchers"`
	StartsAt  string    `json:"startsAt"`
	EndsAt    string    `json:"endsAt"`
	UpdatedAt string    `json:"updatedAt,omitempty"`
	CreatedBy string    `json:"createdBy"`
	Comment   string    `json:"comment"`
}

type amSilence struct {
	ID     string `json:"id"`
	Status struct {
		State string `json:"state"`
	} `json:"status"`
	Matchers  []Matcher `json:"matchers"`
	StartsAt  string    `json:"startsAt"`
	EndsAt    string    `json:"endsAt"`
	UpdatedAt string    `json:"updatedAt"`
	CreatedBy string    `json:"createdBy"`
	Comment   string    `json:"comment"`
}

var silenceStateOrder = map[string]int{"active": 0, "pending": 1, "expired": 2}

func fetchSilences(ctx context.Context, r requester, am *Instance) ([]Silence, error) {
	var raw []amSilence
	if err := getJSON(ctx, r, am, "/api/v2/silences", nil, &raw); err != nil {
		return nil, err
	}
	out := make([]Silence, 0, len(raw))
	for _, s := range raw {
		out = append(out, Silence{
			ID: s.ID, State: s.Status.State, Matchers: s.Matchers, StartsAt: s.StartsAt, EndsAt: s.EndsAt,
			UpdatedAt: s.UpdatedAt, CreatedBy: s.CreatedBy, Comment: s.Comment,
		})
	}
	sortSilences(out)
	return out, nil
}

// sortSilences: active first (soonest to expire first), then pending, then
// expired (most recently ended first).
func sortSilences(l []Silence) {
	sort.SliceStable(l, func(i, j int) bool {
		x, y := l[i], l[j]
		if silenceStateOrder[x.State] != silenceStateOrder[y.State] {
			return silenceStateOrder[x.State] < silenceStateOrder[y.State]
		}
		if x.State == "expired" {
			return parseTime(x.EndsAt).After(parseTime(y.EndsAt))
		}
		return parseTime(x.EndsAt).Before(parseTime(y.EndsAt))
	})
}

// SilenceRequest is the POST /api/prom/silences body.
type SilenceRequest struct {
	Matchers []Matcher `json:"matchers"`
	// Duration is a Go duration ("1h", "4h", "24h") or a day count ("1d").
	Duration string `json:"duration"`
	// StartsAt defaults to now.
	StartsAt string `json:"startsAt,omitempty"`
	// EndsAt overrides Duration when set.
	EndsAt  string `json:"endsAt,omitempty"`
	Comment string `json:"comment"`
	// CreatedBy defaults to "k8sman".
	CreatedBy string `json:"createdBy,omitempty"`
}

const maxSilence = 90 * 24 * time.Hour

// ParseDuration accepts Go durations plus a "d" (day) and "w" (week) suffix.
func ParseDuration(s string) (time.Duration, error) {
	s = strings.TrimSpace(s)
	if n, ok := strings.CutSuffix(s, "d"); ok {
		var d float64
		if _, err := fmt.Sscanf(n, "%g", &d); err == nil {
			return time.Duration(d * float64(24*time.Hour)), nil
		}
	}
	if n, ok := strings.CutSuffix(s, "w"); ok {
		var d float64
		if _, err := fmt.Sscanf(n, "%g", &d); err == nil {
			return time.Duration(d * float64(7*24*time.Hour)), nil
		}
	}
	return time.ParseDuration(s)
}

// build validates the request and returns the Alertmanager payload.
func (req SilenceRequest) build(now time.Time) (map[string]any, error) {
	if len(req.Matchers) == 0 {
		return nil, fmt.Errorf("at least one matcher is required")
	}
	hasPositive := false
	for i, m := range req.Matchers {
		if strings.TrimSpace(m.Name) == "" {
			return nil, fmt.Errorf("matcher %d has no label name", i+1)
		}
		if m.IsRegex {
			if _, err := regexp.Compile("^(?:" + m.Value + ")$"); err != nil {
				return nil, fmt.Errorf("matcher %s: invalid regex: %v", m.Name, err)
			}
		}
		eq := m.IsEqual == nil || *m.IsEqual
		if eq && m.Value != "" && !(m.IsRegex && (m.Value == ".*" || m.Value == ".+")) {
			hasPositive = true
		}
		t := true
		if m.IsEqual == nil {
			req.Matchers[i].IsEqual = &t
		}
	}
	if !hasPositive {
		return nil, fmt.Errorf("at least one matcher must match a specific value (refusing to silence everything)")
	}
	if strings.TrimSpace(req.Comment) == "" {
		return nil, fmt.Errorf("a comment is required")
	}
	start := now
	if req.StartsAt != "" {
		t, err := time.Parse(time.RFC3339, req.StartsAt)
		if err != nil {
			return nil, fmt.Errorf("startsAt: %v", err)
		}
		start = t
	}
	var end time.Time
	switch {
	case req.EndsAt != "":
		t, err := time.Parse(time.RFC3339, req.EndsAt)
		if err != nil {
			return nil, fmt.Errorf("endsAt: %v", err)
		}
		end = t
	case req.Duration != "":
		d, err := ParseDuration(req.Duration)
		if err != nil {
			return nil, fmt.Errorf("duration: %v", err)
		}
		end = start.Add(d)
	default:
		return nil, fmt.Errorf("duration or endsAt is required")
	}
	if !end.After(start) || !end.After(now) {
		return nil, fmt.Errorf("the silence must end in the future")
	}
	if end.Sub(start) > maxSilence {
		return nil, fmt.Errorf("silences are limited to %d days", int(maxSilence.Hours()/24))
	}
	by := req.CreatedBy
	if by == "" {
		by = "k8sman"
	}
	return map[string]any{
		"matchers":  req.Matchers,
		"startsAt":  start.UTC().Format(time.RFC3339),
		"endsAt":    end.UTC().Format(time.RFC3339),
		"createdBy": by,
		"comment":   strings.TrimSpace(req.Comment),
	}, nil
}

func createSilence(ctx context.Context, r requester, am *Instance, payload map[string]any) (string, error) {
	body, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}
	raw, err := r.do(ctx, "POST", am, "/api/v2/silences", nil, body)
	if err != nil {
		return "", err
	}
	var res struct {
		SilenceID string `json:"silenceID"`
	}
	if err := json.Unmarshal(raw, &res); err != nil {
		return "", &UpstreamError{Status: 502, Message: "decode silence response: " + err.Error()}
	}
	return res.SilenceID, nil
}

var silenceIDRe = regexp.MustCompile(`^[A-Za-z0-9-]{1,64}$`)

func expireSilence(ctx context.Context, r requester, am *Instance, id string) error {
	_, err := r.do(ctx, "DELETE", am, "/api/v2/silence/"+id, nil, nil)
	return err
}
