package prom

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// Query limits: PromQL is passed through, but bounded so a careless query
// can't pull an unbounded payload through the API server proxy.
const (
	maxQueryLen   = 8 << 10
	maxRange      = 31 * 24 * time.Hour
	maxPoints     = 1100 // per series; Prometheus itself refuses > 11000
	defaultPoints = 240
	maxSeries     = 500
)

// QueryResult is the payload of /api/prom/query and /api/prom/query_range.
type QueryResult struct {
	ResultType string          `json:"resultType"`
	Result     json.RawMessage `json:"result"`
	Warnings   []string        `json:"warnings,omitempty"`
	// Truncated is true when more than maxSeries series were returned.
	Truncated bool `json:"truncated,omitempty"`
	Series    int  `json:"series"`
	// Start/End/Step echo the effective range (query_range only), in Unix seconds.
	Start      float64 `json:"start,omitempty"`
	End        float64 `json:"end,omitempty"`
	Step       float64 `json:"step,omitempty"`
	Prometheus string  `json:"prometheus"`
}

// RangeParams is a validated query_range request.
type RangeParams struct {
	Start, End time.Time
	Step       time.Duration
}

// parseTimeParam accepts Unix seconds (with fraction), RFC3339, or a
// negative duration relative to now ("-1h").
func parseTimeParam(s string, now time.Time) (time.Time, error) {
	s = strings.TrimSpace(s)
	if f, err := strconv.ParseFloat(s, 64); err == nil {
		sec, frac := math.Modf(f)
		return time.Unix(int64(sec), int64(frac*1e9)).UTC(), nil
	}
	if t, err := time.Parse(time.RFC3339Nano, s); err == nil {
		return t, nil
	}
	if strings.HasPrefix(s, "-") {
		if d, err := ParseDuration(s[1:]); err == nil {
			return now.Add(-d), nil
		}
	}
	if s == "now" {
		return now, nil
	}
	return time.Time{}, fmt.Errorf("invalid time %q (want Unix seconds, RFC3339 or -<duration>)", s)
}

// ParseRange validates start/end/step with defaults (last hour, ~240
// points) and caps the number of points per series.
func ParseRange(q url.Values, now time.Time) (RangeParams, error) {
	p := RangeParams{End: now}
	var err error
	if v := q.Get("end"); v != "" {
		if p.End, err = parseTimeParam(v, now); err != nil {
			return p, err
		}
	}
	p.Start = p.End.Add(-time.Hour)
	if v := q.Get("start"); v != "" {
		if p.Start, err = parseTimeParam(v, now); err != nil {
			return p, err
		}
	}
	if !p.End.After(p.Start) {
		return p, fmt.Errorf("end must be after start")
	}
	span := p.End.Sub(p.Start)
	if span > maxRange {
		return p, fmt.Errorf("range is limited to %d days", int(maxRange.Hours()/24))
	}
	if v := q.Get("step"); v != "" {
		if f, ferr := strconv.ParseFloat(v, 64); ferr == nil {
			p.Step = time.Duration(f * float64(time.Second))
		} else if p.Step, err = ParseDuration(v); err != nil {
			return p, fmt.Errorf("invalid step %q", v)
		}
	} else {
		p.Step = span / defaultPoints
	}
	if p.Step < time.Second {
		p.Step = time.Second
	}
	if minStep := time.Duration(math.Ceil(float64(span) / maxPoints)); p.Step < minStep {
		p.Step = minStep.Round(time.Second)
		if p.Step < minStep {
			p.Step += time.Second
		}
	}
	return p, nil
}

func validateQuery(q string) error {
	if strings.TrimSpace(q) == "" {
		return fmt.Errorf("query is required")
	}
	if len(q) > maxQueryLen {
		return fmt.Errorf("query is longer than %d bytes", maxQueryLen)
	}
	return nil
}

func unix(t time.Time) string {
	return strconv.FormatFloat(float64(t.UnixNano())/1e9, 'f', 3, 64)
}

func runQuery(ctx context.Context, r requester, p *Instance, query string, at string) (*QueryResult, error) {
	q := url.Values{"query": {query}, "timeout": {"20s"}}
	if at != "" {
		q.Set("time", at)
	}
	data, warnings, err := promGet(ctx, r, p, "/api/v1/query", q)
	if err != nil {
		return nil, err
	}
	return shapeResult(data, warnings, p)
}

func runRangeQuery(ctx context.Context, r requester, p *Instance, query string, rp RangeParams) (*QueryResult, error) {
	q := url.Values{
		"query":   {query},
		"start":   {unix(rp.Start)},
		"end":     {unix(rp.End)},
		"step":    {strconv.FormatFloat(rp.Step.Seconds(), 'f', -1, 64)},
		"timeout": {"20s"},
	}
	data, warnings, err := promGet(ctx, r, p, "/api/v1/query_range", q)
	if err != nil {
		return nil, err
	}
	res, err := shapeResult(data, warnings, p)
	if err != nil {
		return nil, err
	}
	res.Start, res.End, res.Step = float64(rp.Start.UnixNano())/1e9, float64(rp.End.UnixNano())/1e9, rp.Step.Seconds()
	return res, nil
}

func shapeResult(data json.RawMessage, warnings []string, p *Instance) (*QueryResult, error) {
	var d struct {
		ResultType string          `json:"resultType"`
		Result     json.RawMessage `json:"result"`
	}
	if err := json.Unmarshal(data, &d); err != nil {
		return nil, &UpstreamError{Status: 502, Message: "decode query result: " + err.Error()}
	}
	res := &QueryResult{ResultType: d.ResultType, Result: d.Result, Warnings: warnings, Prometheus: p.ID}
	if d.ResultType == "matrix" || d.ResultType == "vector" {
		var series []json.RawMessage
		if err := json.Unmarshal(d.Result, &series); err == nil {
			res.Series = len(series)
			if len(series) > maxSeries {
				res.Truncated = true
				res.Series = maxSeries
				res.Result, _ = json.Marshal(series[:maxSeries])
			}
		}
	}
	if len(res.Result) == 0 {
		res.Result = json.RawMessage("[]")
	}
	return res, nil
}
