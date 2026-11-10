package prom

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/url"
	"strconv"

	"github.com/matty234/k8sman/backend/internal/cluster"
)

// Sample is one series of an instant vector.
type Sample struct {
	Metric map[string]string
	Value  float64
}

// ErrNoPrometheus is returned by QueryVector when the cluster has no
// reachable Prometheus.
var ErrNoPrometheus = &UpstreamError{Status: 404, Message: "no reachable Prometheus found in the cluster", NoInstance: true}

// QueryVector runs an instant query against the default Prometheus of the
// active context and returns every series (no series cap: callers keep
// their queries bounded). It is for backend features built on Prometheus
// data, e.g. GPU metrics.
func QueryVector(ctx context.Context, c *cluster.Clients, query string) ([]Sample, *Instance, error) {
	return QueryVectorAt(ctx, c, "", query)
}

// QueryVectorAt is QueryVector against Prometheus instance ("" = the
// default; else its "<namespace>/<name>" or name).
func QueryVectorAt(ctx context.Context, c *cluster.Clients, instance, query string) ([]Sample, *Instance, error) {
	if err := validateQuery(query); err != nil {
		return nil, nil, &UpstreamError{Status: 400, Message: err.Error()}
	}
	e := envFor(c)
	s := shared.get(ctx, e, false)
	p := s.Default(KindPrometheus, instance)
	if p == nil || !p.Reachable {
		return nil, nil, ErrNoPrometheus
	}
	q := url.Values{"query": {query}, "timeout": {"15s"}}
	data, _, err := promGet(ctx, e.req, p, "/api/v1/query", q)
	if err != nil {
		return nil, p, err
	}
	out, err := decodeVector(data)
	return out, p, err
}

func decodeVector(data json.RawMessage) ([]Sample, error) {
	var d struct {
		ResultType string `json:"resultType"`
		Result     []struct {
			Metric map[string]string `json:"metric"`
			Value  [2]any            `json:"value"`
		} `json:"result"`
	}
	if err := json.Unmarshal(data, &d); err != nil {
		return nil, &UpstreamError{Status: 502, Message: "decode query result: " + err.Error()}
	}
	if d.ResultType != "vector" {
		return nil, &UpstreamError{Status: 422, Message: fmt.Sprintf("expected a vector result, got %q", d.ResultType)}
	}
	out := make([]Sample, 0, len(d.Result))
	for _, r := range d.Result {
		s, ok := r.Value[1].(string)
		if !ok {
			continue
		}
		v, err := strconv.ParseFloat(s, 64)
		if err != nil || math.IsNaN(v) || math.IsInf(v, 0) {
			continue
		}
		out = append(out, Sample{Metric: r.Metric, Value: v})
	}
	return out, nil
}
