package columns

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/itchyny/gojq"
	"k8s.io/apimachinery/pkg/api/resource"
)

// General helpers for column queries, beside the status helpers:
//
//	condition("Ready")   the object's first condition of that type, or null
//	duration(start; end) elapsed time between two timestamps ("4m05s"), up to
//	                     now while end is null; "" without a start
//	selector             a label selector (or a plain map such as a Service's)
//	                     as "app=web,tier in (a,b)"
//	nodestatus           a node's kubectl status: Ready/NotReady/Unknown, plus
//	                     ",SchedulingDisabled" when cordoned
//	noderoles            a node's roles from its node-role.kubernetes.io labels
//	tobytes              a Kubernetes quantity ("16Gi", "1500Mi") as a number
//	                     of bytes, for the bytes cell type
var helperFunctions = []gojq.CompilerOption{
	gojq.WithFunction("condition", 1, 1, func(v any, args []any) any {
		for _, c := range list(dig(v, "status", "conditions")) {
			if m, _ := c.(map[string]any); m != nil && m["type"] == args[0] {
				return m
			}
		}
		return nil
	}),
	gojq.WithFunction("duration", 2, 2, func(_ any, args []any) any {
		start, ok := parseTime(args[0])
		if !ok {
			return ""
		}
		end, ok := parseTime(args[1])
		if !ok {
			end = time.Now()
		}
		return shortDuration(end.Sub(start))
	}),
	gojq.WithFunction("selector", 0, 0, func(v any, _ []any) any { return selectorString(v) }),
	gojq.WithFunction("nodestatus", 0, 0, func(v any, _ []any) any { return nodeStatus(v) }),
	gojq.WithFunction("noderoles", 0, 0, func(v any, _ []any) any {
		var roles []string
		labels, _ := dig(v, "metadata", "labels").(map[string]any)
		for k := range labels {
			if r, ok := strings.CutPrefix(k, "node-role.kubernetes.io/"); ok {
				roles = append(roles, r)
			}
		}
		sort.Strings(roles)
		return strings.Join(roles, ",")
	}),
	gojq.WithFunction("tobytes", 0, 0, func(v any, _ []any) any {
		s, ok := v.(string)
		if !ok {
			return nil
		}
		q, err := resource.ParseQuantity(s)
		if err != nil {
			return fmt.Errorf("tobytes: %v", err)
		}
		return int(q.Value())
	}),
}

func parseTime(v any) (time.Time, bool) {
	s, ok := v.(string)
	if !ok || s == "" {
		return time.Time{}, false
	}
	t, err := time.Parse(time.RFC3339, s)
	return t, err == nil
}

// shortDuration: "45s", "4m05s", "3h07m", "2d5h".
func shortDuration(d time.Duration) string {
	s := int(d.Seconds())
	if s < 0 {
		s = 0
	}
	switch {
	case s < 60:
		return fmt.Sprintf("%ds", s)
	case s < 3600:
		return fmt.Sprintf("%dm%02ds", s/60, s%60)
	case s < 86400:
		return fmt.Sprintf("%dh%02dm", s/3600, s%3600/60)
	}
	return fmt.Sprintf("%dd%dh", s/86400, s%86400/3600)
}

// selectorString spells a LabelSelector ({matchLabels, matchExpressions})
// or a plain map selector the way kubectl does, keys sorted.
func selectorString(v any) string {
	m, _ := v.(map[string]any)
	if m == nil {
		return ""
	}
	_, hasLabels := m["matchLabels"]
	_, hasExprs := m["matchExpressions"]
	labels := m
	if hasLabels || hasExprs {
		labels, _ = m["matchLabels"].(map[string]any)
	}
	var parts []string
	for k, val := range labels {
		parts = append(parts, fmt.Sprintf("%s=%v", k, val))
	}
	sort.Strings(parts)
	if hasExprs {
		for _, e := range list(m["matchExpressions"]) {
			key, _ := dig(e, "key").(string)
			var vals []string
			for _, x := range list(dig(e, "values")) {
				vals = append(vals, fmt.Sprint(x))
			}
			switch op, _ := dig(e, "operator").(string); op {
			case "In":
				parts = append(parts, fmt.Sprintf("%s in (%s)", key, strings.Join(vals, ",")))
			case "NotIn":
				parts = append(parts, fmt.Sprintf("%s notin (%s)", key, strings.Join(vals, ",")))
			case "Exists":
				parts = append(parts, key)
			case "DoesNotExist":
				parts = append(parts, "!"+key)
			}
		}
	}
	return strings.Join(parts, ",")
}

func nodeStatus(v any) string {
	s := "Unknown"
	for _, c := range list(dig(v, "status", "conditions")) {
		if m, _ := c.(map[string]any); m != nil && m["type"] == "Ready" {
			s = "NotReady"
			if m["status"] == "True" {
				s = "Ready"
			}
			break
		}
	}
	if u, _ := dig(v, "spec", "unschedulable").(bool); u {
		s += ",SchedulingDisabled"
	}
	return s
}
