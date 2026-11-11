package metrics

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"

	apierrors "k8s.io/apimachinery/pkg/api/errors"

	"github.com/matty234/k8sman/backend/internal/kapi"
)

// API states.
const (
	StateAvailable    = "available"    // APIService registered and Available=True
	StateNotReady     = "notReady"     // registered, but Available=False (e.g. adapter starting, no data yet)
	StateNotInstalled = "notInstalled" // no APIService for the group
	StateUnknown      = "unknown"      // could not tell (e.g. no RBAC to read APIServices)
)

// APIStatus describes one metrics API group.
type APIStatus struct {
	Group string `json:"group"`
	// Version is the version k8sman uses (the newest one registered).
	Version  string   `json:"version,omitempty"`
	Versions []string `json:"versions,omitempty"`
	// APIService is the registration name, e.g. v1.metrics.k8s.io.
	APIService string `json:"apiService,omitempty"`
	State      string `json:"state"`
	Available  bool   `json:"available"`
	Reason     string `json:"reason,omitempty"`
	Message    string `json:"message,omitempty"`
	// Service is the backing in-cluster Service (namespace/name), if any.
	Service *ServiceRef `json:"service,omitempty"`
}

// ServiceRef is an APIService's backing Service.
type ServiceRef struct {
	Namespace string `json:"namespace"`
	Name      string `json:"name"`
}

// Status is the availability of the three metrics APIs.
type Status struct {
	Resource APIStatus `json:"resource"`
	Custom   APIStatus `json:"custom"`
	External APIStatus `json:"external"`
}

// Of returns the status for a group.
func (s Status) Of(group string) APIStatus {
	switch group {
	case ResourceGroup:
		return s.Resource
	case CustomGroup:
		return s.Custom
	default:
		return s.External
	}
}

// versionPreference orders versions newest-first for the groups we read
// (edit them in backend/internal/kapi).
var versionPreference = map[string][]string{
	ResourceGroup: kapi.ResourceMetrics.Versions,
	CustomGroup:   kapi.CustomMetrics.Versions,
	ExternalGroup: kapi.ExternalMetrics.Versions,
}

type apiServiceList struct {
	Items []struct {
		Metadata struct {
			Name string `json:"name"`
		} `json:"metadata"`
		Spec struct {
			Group   string `json:"group"`
			Version string `json:"version"`
			Service *struct {
				Namespace string `json:"namespace"`
				Name      string `json:"name"`
			} `json:"service"`
		} `json:"spec"`
		Status struct {
			Conditions []struct {
				Type    string `json:"type"`
				Status  string `json:"status"`
				Reason  string `json:"reason"`
				Message string `json:"message"`
			} `json:"conditions"`
		} `json:"status"`
	} `json:"items"`
}

// Status reports which metrics APIs are served. Cached for StatusTTL unless
// refresh is set.
func (s *Service) Status(ctx context.Context, refresh bool) Status {
	s.mu.Lock()
	if c := s.status; c != nil && !refresh && s.now().Sub(c.at) < s.StatusTTL {
		s.mu.Unlock()
		return c.val
	}
	s.mu.Unlock()
	st := s.fetchStatus(ctx)
	s.mu.Lock()
	s.status = &cachedStatus{at: s.now(), val: st}
	s.mu.Unlock()
	return st
}

func (s *Service) fetchStatus(ctx context.Context) Status {
	raw, err := s.get.Get(ctx, kapi.APIServices.Path("", ""), nil)
	if err != nil {
		// No RBAC for APIServices: fall back to discovery per group.
		return Status{
			Resource: s.probeGroup(ctx, ResourceGroup),
			Custom:   s.probeGroup(ctx, CustomGroup),
			External: s.probeGroup(ctx, ExternalGroup),
		}
	}
	var list apiServiceList
	if err := json.Unmarshal(raw, &list); err != nil {
		return Status{Resource: unknown(ResourceGroup, err), Custom: unknown(CustomGroup, err), External: unknown(ExternalGroup, err)}
	}
	return statusFromAPIServices(list)
}

func unknown(group string, err error) APIStatus {
	return APIStatus{Group: group, State: StateUnknown, Message: err.Error()}
}

func statusFromAPIServices(list apiServiceList) Status {
	by := map[string]APIStatus{}
	for _, g := range []string{ResourceGroup, CustomGroup, ExternalGroup} {
		by[g] = APIStatus{Group: g, State: StateNotInstalled}
	}
	type reg struct {
		version string
		st      APIStatus
	}
	regs := map[string][]reg{}
	for _, it := range list.Items {
		g := it.Spec.Group
		if _, ok := by[g]; !ok {
			continue
		}
		st := APIStatus{Group: g, Version: it.Spec.Version, APIService: it.Metadata.Name, State: StateNotReady}
		if it.Spec.Service != nil {
			st.Service = &ServiceRef{Namespace: it.Spec.Service.Namespace, Name: it.Spec.Service.Name}
		}
		for _, c := range it.Status.Conditions {
			if c.Type == "Available" {
				st.Available = c.Status == "True"
				st.Reason, st.Message = c.Reason, c.Message
			}
		}
		if st.Available {
			st.State = StateAvailable
		}
		regs[g] = append(regs[g], reg{it.Spec.Version, st})
	}
	for g, rs := range regs {
		rank := func(v string) int {
			for i, p := range versionPreference[g] {
				if p == v {
					return i
				}
			}
			return 100
		}
		// Prefer a known version that is available, then any known version.
		sort.SliceStable(rs, func(i, j int) bool {
			if rs[i].st.Available != rs[j].st.Available {
				return rs[i].st.Available
			}
			return rank(rs[i].version) < rank(rs[j].version)
		})
		best := rs[0].st
		for _, r := range rs {
			best.Versions = append(best.Versions, r.version)
		}
		sort.Strings(best.Versions)
		by[g] = best
	}
	return Status{Resource: by[ResourceGroup], Custom: by[CustomGroup], External: by[ExternalGroup]}
}

// probeGroup checks a group via discovery when APIServices can't be read.
func (s *Service) probeGroup(ctx context.Context, group string) APIStatus {
	for _, v := range versionPreference[group] {
		_, err := s.get.Get(ctx, "/apis/"+group+"/"+v, nil)
		switch {
		case err == nil:
			return APIStatus{Group: group, Version: v, Versions: []string{v}, State: StateAvailable, Available: true}
		case apierrors.IsNotFound(err):
			continue
		case apierrors.IsServiceUnavailable(err):
			return APIStatus{Group: group, Version: v, Versions: []string{v}, State: StateNotReady, Message: err.Error()}
		default:
			return APIStatus{Group: group, State: StateUnknown, Message: err.Error()}
		}
	}
	return APIStatus{Group: group, State: StateNotInstalled}
}

// UnavailableError explains why a metrics API can't serve a request.
type UnavailableError struct {
	Status APIStatus
	Err    error
}

func (e *UnavailableError) Error() string {
	switch e.Status.State {
	case StateNotInstalled:
		return fmt.Sprintf("%s is not installed (no APIService registered)", e.Status.Group)
	case StateNotReady:
		msg := e.Status.Message
		if msg == "" && e.Err != nil {
			msg = e.Err.Error()
		}
		return fmt.Sprintf("%s is installed but not ready yet: %s", e.Status.Group, msg)
	}
	if e.Err != nil {
		return e.Err.Error()
	}
	return e.Status.Group + " is unavailable"
}

func (e *UnavailableError) Unwrap() error { return e.Err }

// explain wraps a fetch error with the group's status when the API isn't
// usable, so callers can tell "not installed" from "not ready yet".
func (s *Service) explain(ctx context.Context, group string, err error) error {
	if err == nil {
		return nil
	}
	if apierrors.IsNotFound(err) || apierrors.IsServiceUnavailable(err) || isNoData(err) {
		st := s.Status(ctx, true).Of(group)
		if st.State == StateAvailable {
			// Registered and Available, but this request found nothing (e.g.
			// a metric name that doesn't exist): report the original error.
			if isNoData(err) {
				st.State, st.Message = StateNotReady, err.Error()
				return &UnavailableError{Status: st, Err: err}
			}
			return err
		}
		return &UnavailableError{Status: st, Err: err}
	}
	return err
}
