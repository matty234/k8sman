package hubble

import (
	"sort"
	"time"
)

// DropGroup is the drops between one source and destination for one
// reason.
type DropGroup struct {
	Source      Endpoint  `json:"source"`
	Destination Endpoint  `json:"destination"`
	Reason      string    `json:"reason"`
	Protocol    string    `json:"protocol,omitempty"`
	Port        uint32    `json:"port,omitempty"`
	Count       int       `json:"count"`
	First       time.Time `json:"first"`
	Last        time.Time `json:"last"`
	// DeniedBy are the policies Hubble says denied it, when it knows.
	DeniedBy []PolicyRef `json:"deniedBy,omitempty"`
}

// Drops is the GET /api/hubble/drops payload.
type Drops struct {
	Groups []DropGroup `json:"groups"`
	// Flows is how many dropped flows were read (at most the request's
	// last); Truncated is true when that limit was hit.
	Flows     int    `json:"flows"`
	Truncated bool   `json:"truncated,omitempty"`
	Lost      uint64 `json:"lost,omitempty"`
	Since     string `json:"since"`
	// Oldest is the oldest drop read: the relay keeps a fixed number of
	// flows per node, so on a busy cluster this is seconds ago, not Since.
	Oldest *time.Time `json:"oldest,omitempty"`
	// Partial is true when the relay was too slow to send everything.
	Partial bool `json:"partial,omitempty"`
}

// GroupDrops groups dropped flows by source, destination, reason and
// destination port, most frequent first. The endpoints keep only what
// identifies them (no ports or IPs of pods).
func GroupDrops(flows []Flow) []DropGroup {
	type key struct {
		src, dst, reason, proto string
		port                    uint32
	}
	idx := map[key]*DropGroup{}
	var order []*DropGroup
	for _, f := range flows {
		if f.Verdict != "DROPPED" {
			continue
		}
		proto := ""
		if f.L4 != nil {
			proto = f.L4.Protocol
		}
		k := key{f.Source.Label(), f.Dest.Label(), f.DropReason, proto, f.Dest.Port}
		g := idx[k]
		if g == nil {
			g = &DropGroup{Source: ident(f.Source), Destination: ident(f.Dest), Reason: f.DropReason, Protocol: proto, Port: f.Dest.Port, First: f.Time, Last: f.Time}
			idx[k] = g
			order = append(order, g)
		}
		g.Count++
		if f.Time.Before(g.First) {
			g.First = f.Time
		}
		if f.Time.After(g.Last) {
			g.Last = f.Time
		}
		if f.Policies != nil && len(g.DeniedBy) == 0 {
			g.DeniedBy = f.Policies.DeniedBy
		}
	}
	out := make([]DropGroup, 0, len(order))
	for _, g := range order {
		out = append(out, *g)
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Count != out[j].Count {
			return out[i].Count > out[j].Count
		}
		return out[i].Last.After(out[j].Last)
	})
	return out
}

func ident(e Endpoint) Endpoint {
	e.Port = 0
	if e.Pod != "" {
		e.IP = ""
	}
	return e
}

// Connectivity is the GET /api/hubble/connectivity payload: what Hubble saw
// of traffic from one endpoint to another.
type Connectivity struct {
	From  string `json:"from"`
	To    string `json:"to"`
	Since string `json:"since"`
	// Verdicts counts flows by verdict (FORWARDED, DROPPED, …).
	Verdicts map[string]int `json:"verdicts"`
	// Drops groups the dropped flows by reason (and port).
	Drops []DropGroup `json:"drops"`
	// AllowedBy are the policies Hubble said allowed the forwarded flows.
	AllowedBy []PolicyRef `json:"allowedBy,omitempty"`
	// Recent are the latest flows, newest last (at most 50).
	Recent []Flow `json:"recent"`
	// Reverse counts flows the other way (replies, or B calling A), so "no
	// flows" can be told apart from "only replies seen".
	Reverse map[string]int `json:"reverse"`
	Lost    uint64         `json:"lost,omitempty"`
	// Oldest is the oldest flow seen either way (see Drops.Oldest).
	Oldest *time.Time `json:"oldest,omitempty"`
	// Verdict is a one-word answer: allowed, dropped, mixed or unknown (no
	// flows seen).
	Verdict string `json:"verdict"`
}

// Summarise builds a Connectivity from the flows each way.
func Summarise(from, to string, since time.Duration, fwd, rev []Flow) Connectivity {
	c := Connectivity{From: from, To: to, Since: since.String(), Verdicts: map[string]int{}, Reverse: map[string]int{}, Drops: GroupDrops(fwd), Recent: []Flow{}}
	seen := map[PolicyRef]bool{}
	for _, f := range fwd {
		c.Verdicts[f.Verdict]++
		if f.Policies != nil {
			for _, p := range f.Policies.AllowedBy {
				if !seen[p] {
					seen[p] = true
					c.AllowedBy = append(c.AllowedBy, p)
				}
			}
		}
	}
	for _, f := range rev {
		c.Reverse[f.Verdict]++
	}
	sort.SliceStable(fwd, func(i, j int) bool { return fwd[i].Time.Before(fwd[j].Time) })
	if n := len(fwd); n > 50 {
		fwd = fwd[n-50:]
	}
	c.Recent = append(c.Recent, fwd...)
	ok, dropped := c.Verdicts["FORWARDED"], c.Verdicts["DROPPED"]+c.Verdicts["ERROR"]
	switch {
	case ok > 0 && dropped > 0:
		c.Verdict = "mixed"
	case dropped > 0:
		c.Verdict = "dropped"
	case ok > 0:
		c.Verdict = "allowed"
	default:
		c.Verdict = "unknown"
	}
	return c
}
