package security

import "slices"

// IgnoreRule hides findings the user has decided to accept, per kube
// context. It applies to a finding whose Check equals Check:
//   - with no Kind and Name, to every such finding (in Namespace, if set,
//     otherwise everywhere);
//   - with Kind and Name, to one target object (Namespace, if set, being the
//     object's). A finding is ignored by such rules only when every one of
//     its objects is covered, so a target that joins the finding later
//     brings it back.
type IgnoreRule struct {
	Check     string `json:"check"`
	Namespace string `json:"namespace,omitempty"`
	Kind      string `json:"kind,omitempty"`
	Name      string `json:"name,omitempty"`
	Reason    string `json:"reason,omitempty"`
	At        string `json:"at,omitempty"` // RFC3339
}

// Ignoring returns the rule that ignores f, if any.
func Ignoring(rules []IgnoreRule, f Finding) (IgnoreRule, bool) {
	var objRules []IgnoreRule
	for _, r := range rules {
		if r.Check == "" || r.Check != f.Check {
			continue
		}
		if r.Kind == "" && r.Name == "" {
			if r.Namespace == "" || r.Namespace == f.Namespace {
				return r, true
			}
			continue
		}
		objRules = append(objRules, r)
	}
	if len(f.Objects) == 0 {
		return IgnoreRule{}, false
	}
	var first IgnoreRule
	for i, o := range f.Objects {
		j := slices.IndexFunc(objRules, func(r IgnoreRule) bool {
			return r.Kind == o.Kind && r.Name == o.Name && (r.Namespace == "" || r.Namespace == o.Namespace)
		})
		if j < 0 {
			return IgnoreRule{}, false
		}
		if i == 0 {
			first = objRules[j]
		}
	}
	return first, true
}

// IgnoredFinding is a finding hidden by Rule.
type IgnoredFinding struct {
	Finding
	Rule IgnoreRule `json:"rule"`
}

// ApplyIgnores moves the findings matched by rules from res.Findings to
// res.Ignored and recomputes the categories and score, so they count only
// what is left. It is applied to a finished Result, never inside a shared
// scan.
func ApplyIgnores(res *Result, rules []IgnoreRule) {
	if len(rules) == 0 {
		return
	}
	kept := res.Findings[:0:0]
	for _, f := range res.Findings {
		if r, ok := Ignoring(rules, f); ok {
			res.Ignored = append(res.Ignored, IgnoredFinding{Finding: f, Rule: r})
		} else {
			kept = append(kept, f)
		}
	}
	res.Findings = kept
	summarise(res)
}
