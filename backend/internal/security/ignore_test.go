package security

import "testing"

func TestApplyIgnores(t *testing.T) {
	f := func(check, ns, kind, name, sev string) Finding {
		return Finding{ID: check + "/" + ns + "/" + name, Check: check, Severity: sev, Category: CatRBAC, Namespace: ns, Objects: []ObjectRef{{Kind: kind, Name: name, Namespace: ns}}}
	}
	mk := func() *Result {
		res := &Result{Ignored: []IgnoredFinding{}, Findings: []Finding{
			f("rbac.cluster-admin", "a", "RoleBinding", "x", Critical),
			f("rbac.cluster-admin", "a", "RoleBinding", "y", Critical),
			f("rbac.cluster-admin", "b", "RoleBinding", "x", Critical),
			f("rbac.wildcard", "a", "Role", "r", Medium),
			{ID: "rbac.multi", Check: "rbac.multi", Severity: High, Category: CatRBAC, Objects: []ObjectRef{{Kind: "Namespace", Name: "n1"}, {Kind: "Namespace", Name: "n2"}}},
		}}
		summarise(res)
		return res
	}
	before := mk().Score
	for _, c := range []struct {
		name    string
		rules   []IgnoreRule
		ignored int
	}{
		{"this finding", []IgnoreRule{{Check: "rbac.cluster-admin", Namespace: "a", Kind: "RoleBinding", Name: "x"}}, 1},
		{"check in namespace", []IgnoreRule{{Check: "rbac.cluster-admin", Namespace: "a"}}, 2},
		{"check everywhere", []IgnoreRule{{Check: "rbac.cluster-admin"}}, 3},
		{"one of two objects", []IgnoreRule{{Check: "rbac.multi", Kind: "Namespace", Name: "n1"}}, 0},
		{"every object", []IgnoreRule{{Check: "rbac.multi", Kind: "Namespace", Name: "n1"}, {Check: "rbac.multi", Kind: "Namespace", Name: "n2"}}, 1},
		{"no match", []IgnoreRule{{Check: "rbac.other"}}, 0},
	} {
		res := mk()
		ApplyIgnores(res, c.rules)
		if len(res.Ignored) != c.ignored || len(res.Findings)+c.ignored != 5 {
			t.Errorf("%s: %d ignored, %d left", c.name, len(res.Ignored), len(res.Findings))
			continue
		}
		if res.Categories[1].Total != len(res.Findings) {
			t.Errorf("%s: rbac total %d, want %d", c.name, res.Categories[1].Total, len(res.Findings))
		}
		if c.ignored > 0 && (res.Score <= before || res.Ignored[0].Rule != c.rules[0]) {
			t.Errorf("%s: score %d (was %d), rule %+v", c.name, res.Score, before, res.Ignored[0].Rule)
		}
	}
}
