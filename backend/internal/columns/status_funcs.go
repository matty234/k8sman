package columns

import "github.com/itchyny/gojq"

// Status helpers for column queries: each reads the object it is given and
// returns one status word, so a built-in Status column is `podstatus` rather
// than a page of jq. Users can call them in their own columns too. The
// frontend colours the words via severityOf.
var statusFunctions = []gojq.CompilerOption{
	statusFunc("podstatus", podStatus),
	statusFunc("deploymentstatus", deploymentStatus),
	statusFunc("statefulsetstatus", statefulSetStatus),
	statusFunc("daemonsetstatus", daemonSetStatus),
	statusFunc("jobstatus", jobStatus),
}

func statusFunc(name string, f func(map[string]any) any) gojq.CompilerOption {
	return gojq.WithFunction(name, 0, 0, func(v any, _ []any) any {
		obj, _ := v.(map[string]any)
		return f(obj)
	})
}

// podStatus is what kubectl's STATUS column says: Terminating, a failing
// init container ("Init:CrashLoopBackOff"), a waiting or terminated
// container's reason, else the phase.
func podStatus(o map[string]any) any {
	if dig(o, "metadata", "deletionTimestamp") != nil {
		return "Terminating"
	}
	for _, c := range list(dig(o, "status", "initContainerStatuses")) {
		waiting := dig(c, "state", "waiting")
		if num(dig(c, "state", "terminated", "exitCode")) != 0 || waiting != nil {
			return "Init:" + firstString(dig(waiting, "reason"), dig(c, "state", "terminated", "reason"), "Error")
		}
	}
	for _, c := range list(dig(o, "status", "containerStatuses")) {
		if r, ok := dig(c, "state", "waiting", "reason").(string); ok {
			return r
		}
		if r, ok := dig(c, "state", "terminated", "reason").(string); ok {
			return r
		}
	}
	return dig(o, "status", "phase")
}

// deploymentStatus: Paused, Scaled down, Stalled (progress deadline
// exceeded), Progressing (a rollout under way), Unavailable (none
// available), Degraded (some short) or Available.
func deploymentStatus(o map[string]any) any {
	want := numOr(dig(o, "spec", "replicas"), 1)
	avail := num(dig(o, "status", "availableReplicas"))
	replicas := num(dig(o, "status", "replicas"))
	switch {
	case dig(o, "spec", "paused") == true:
		return "Paused"
	case want == 0:
		if replicas > 0 {
			return "Progressing"
		}
		return "Scaled down"
	case hasCondition(o, func(c map[string]any) bool {
		return c["type"] == "Progressing" && c["reason"] == "ProgressDeadlineExceeded"
	}):
		return "Stalled"
	case stale(o) || num(dig(o, "status", "updatedReplicas")) < want || replicas > want:
		return "Progressing"
	case avail == 0:
		return "Unavailable"
	case avail < want || num(dig(o, "status", "readyReplicas")) < want:
		return "Degraded"
	}
	return "Available"
}

func statefulSetStatus(o map[string]any) any {
	want := numOr(dig(o, "spec", "replicas"), 1)
	ready := num(dig(o, "status", "readyReplicas"))
	replicas := num(dig(o, "status", "replicas"))
	update := dig(o, "status", "updateRevision")
	switch {
	case want == 0:
		if replicas > 0 {
			return "Progressing"
		}
		return "Scaled down"
	case stale(o) || (update != nil && dig(o, "status", "currentRevision") != update) || replicas != want:
		return "Progressing"
	case ready == 0:
		return "Unavailable"
	case ready < want:
		return "Degraded"
	}
	return "Available"
}

func daemonSetStatus(o map[string]any) any {
	want := num(dig(o, "status", "desiredNumberScheduled"))
	avail := num(dig(o, "status", "numberAvailable"))
	switch {
	case want == 0:
		return "Scaled down"
	case stale(o) || num(dig(o, "status", "updatedNumberScheduled")) < want:
		return "Progressing"
	case avail == 0:
		return "Unavailable"
	case avail < want:
		return "Degraded"
	}
	return "Available"
}

// jobStatus: the last true condition (Complete, Failed, Suspended, …), else
// Running while pods are active, else Pending.
func jobStatus(o map[string]any) any {
	var last any
	for _, c := range list(dig(o, "status", "conditions")) {
		if m, _ := c.(map[string]any); m != nil && m["status"] == "True" && m["type"] != nil {
			last = m["type"]
		}
	}
	if last != nil {
		return last
	}
	if num(dig(o, "status", "active")) > 0 {
		return "Running"
	}
	return "Pending"
}

// stale: the controller hasn't caught up with the latest spec yet.
func stale(o map[string]any) bool {
	return num(dig(o, "status", "observedGeneration")) < num(dig(o, "metadata", "generation"))
}

func hasCondition(o map[string]any, match func(map[string]any) bool) bool {
	for _, c := range list(dig(o, "status", "conditions")) {
		if m, _ := c.(map[string]any); m != nil && match(m) {
			return true
		}
	}
	return false
}

func dig(v any, path ...string) any {
	for _, k := range path {
		m, ok := v.(map[string]any)
		if !ok {
			return nil
		}
		v = m[k]
	}
	return v
}

func list(v any) []any {
	l, _ := v.([]any)
	return l
}

// num reads a JSON number (int, int64 or float64 in decoded objects); 0
// when absent.
func num(v any) float64 { return numOr(v, 0) }

func numOr(v any, def float64) float64 {
	switch n := v.(type) {
	case int:
		return float64(n)
	case int64:
		return float64(n)
	case float64:
		return n
	}
	return def
}

func firstString(vs ...any) string {
	for _, v := range vs {
		if s, ok := v.(string); ok {
			return s
		}
	}
	return ""
}
