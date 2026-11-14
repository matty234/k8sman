package mcpserver

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"slices"
	"strings"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The Security page's findings, and ignoring them: the one change Claude
// Code can make through k8sman. Ignore rules live in k8sman's settings
// (never the cluster), are marked as Claude's, and the user can un-ignore
// them on the page.

// maxObjectRules mirrors the app: a finding naming more objects than this
// can only be ignored by check (in its namespace, or everywhere).
const maxObjectRules = 20

type secRef struct {
	Group, Kind, Name, Namespace string
}

func (o secRef) String() string { return o.Kind + " " + qualified(o.Namespace, o.Name) }

type secFinding struct {
	ID, Check, Severity, Category, Title, Detail, Remediation, Namespace string
	Objects                                                              []secRef
	Checks                                                               []string
}

type secIgnored struct {
	secFinding
	Rule secRule `json:"rule"`
}

type secRule struct {
	Check     string `json:"check"`
	Namespace string `json:"namespace,omitempty"`
	Kind      string `json:"kind,omitempty"`
	Name      string `json:"name,omitempty"`
	Reason    string `json:"reason,omitempty"`
	At        string `json:"at,omitempty"`
	By        string `json:"by,omitempty"`
}

func (r secRule) scope() string {
	switch {
	case r.Kind != "":
		return r.Kind + " " + qualified(r.Namespace, r.Name)
	case r.Namespace != "":
		return "check " + r.Check + " in " + r.Namespace
	}
	return "check " + r.Check + " everywhere"
}

type secResult struct {
	Score    int          `json:"score"`
	Findings []secFinding `json:"findings"`
	Ignored  []secIgnored `json:"ignored"`
	Pending  []string     `json:"pending"`
	Errors   map[string]string
}

var sevOrder = []string{"critical", "high", "medium", "low", "info"}

func registerSecurity(s *mcp.Server, c *client) {
	ro := &mcp.ToolAnnotations{ReadOnlyHint: true}

	type listArgs struct {
		Namespace      string `json:"namespace,omitempty" jsonschema:"only this namespace (default: all)"`
		Category       string `json:"category,omitempty" jsonschema:"network, rbac, workloads, images or practices"`
		MinSeverity    string `json:"minSeverity,omitempty" jsonschema:"critical, high, medium, low or info (default: low)"`
		IncludeIgnored bool   `json:"includeIgnored,omitempty" jsonschema:"also list the findings that are ignored, with who ignored them and why"`
		IncludeSystem  bool   `json:"includeSystem,omitempty" jsonschema:"include kube-system & co. and Kubernetes' default system: roles"`
	}
	mcp.AddTool(s, &mcp.Tool{Name: "list_security_findings", Annotations: ro,
		Description: "The findings on k8sman's Security page, most severe first: network exposure, RBAC, workload hardening (Pod Security Standards), " +
			"best practices and image CVEs. Each line starts with the finding's id (for get_security_finding and ignore_security_findings)."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a listArgs) (*mcp.CallToolResult, any, error) {
			return text(c.securityList(ctx, a.Namespace, a.Category, a.MinSeverity, a.IncludeIgnored, a.IncludeSystem))
		})

	type getArgs struct {
		ID string `json:"id" jsonschema:"the finding's id, from list_security_findings"`
	}
	mcp.AddTool(s, &mcp.Tool{Name: "get_security_finding", Annotations: ro,
		Description: "One security finding in full: what's wrong, the failing checks, every affected object, the suggested remediation, and whether it's ignored."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a getArgs) (*mcp.CallToolResult, any, error) {
			return text(c.securityGet(ctx, a.ID))
		})

	type ignoreArgs struct {
		IDs    []string `json:"ids" jsonschema:"the findings' ids, from list_security_findings"`
		Scope  string   `json:"scope,omitempty" jsonschema:"finding (default): only these findings' current objects; namespace: the finding's check in its namespace; everywhere: the check in the whole cluster"`
		Reason string   `json:"reason" jsonschema:"why the risk is accepted, shown to the user on the Security page"`
	}
	f := false
	mcp.AddTool(s, &mcp.Tool{Name: "ignore_security_findings",
		Annotations: &mcp.ToolAnnotations{DestructiveHint: &f, IdempotentHint: true},
		Description: "Ignore security findings the user accepts as intended, so they leave k8sman's list and score. This changes only k8sman's settings, " +
			"not the cluster; the Security page shows them as ignored by Claude, with the reason, and the user can un-ignore them. " +
			"Confirm with the user first, and prefer fixing over ignoring."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a ignoreArgs) (*mcp.CallToolResult, any, error) {
			return text(c.securityIgnore(ctx, a.IDs, a.Scope, a.Reason))
		})
}

func (c *client) security(ctx context.Context, ns string, includeSystem bool) (*secResult, error) {
	q := url.Values{"wait": {"10s"}}
	if ns != "" {
		q.Set("namespace", ns)
	}
	if includeSystem {
		q.Set("includeSystem", "true")
	}
	var r secResult
	return &r, c.getJSON(ctx, "/api/security", q, &r)
}

func sevIndex(s string) int {
	if i := slices.Index(sevOrder, s); i >= 0 {
		return i
	}
	return len(sevOrder)
}

func (c *client) securityList(ctx context.Context, ns, category, minSev string, withIgnored, includeSystem bool) (string, error) {
	limit := sevIndex("low")
	if minSev != "" {
		if limit = sevIndex(strings.ToLower(minSev)); limit == len(sevOrder) {
			return "", fmt.Errorf("minSeverity must be one of %s", strings.Join(sevOrder, ", "))
		}
	}
	r, err := c.security(ctx, ns, includeSystem)
	if err != nil {
		return "", err
	}
	keep := func(f secFinding) bool {
		return (category == "" || f.Category == category) && sevIndex(f.Severity) <= limit
	}
	var fs []secFinding
	for _, f := range r.Findings {
		if keep(f) {
			fs = append(fs, f)
		}
	}
	slices.SortStableFunc(fs, func(a, b secFinding) int { return sevIndex(a.Severity) - sevIndex(b.Severity) })
	var b strings.Builder
	fmt.Fprintf(&b, "Security score %d/100. %d findings", r.Score, len(fs))
	if len(r.Ignored) > 0 {
		fmt.Fprintf(&b, " (%d ignored, not counted)", len(r.Ignored))
	}
	b.WriteString(".\n")
	for i, f := range fs {
		if i == 300 {
			fmt.Fprintf(&b, "… and %d more (narrow with namespace, category or minSeverity)\n", len(fs)-i)
			break
		}
		writeFindingLine(&b, f)
	}
	if withIgnored && len(r.Ignored) > 0 {
		b.WriteString("\nIgnored:\n")
		for _, ig := range r.Ignored {
			if !keep(ig.secFinding) {
				continue
			}
			writeFindingLine(&b, ig.secFinding)
			fmt.Fprintf(&b, "    ignored (%s) by %s", ig.Rule.scope(), who(ig.Rule.By))
			if ig.Rule.Reason != "" {
				fmt.Fprintf(&b, ": %q", ig.Rule.Reason)
			}
			b.WriteByte('\n')
		}
	}
	if len(r.Pending) > 0 {
		fmt.Fprintf(&b, "\nStill loading (ask again shortly for these): %s\n", strings.Join(r.Pending, ", "))
	}
	for k, e := range r.Errors {
		fmt.Fprintf(&b, "\nCouldn't read %s: %s", k, e)
	}
	return b.String(), nil
}

func who(by string) string {
	if by == "claude" {
		return "Claude"
	}
	return "the user"
}

func writeFindingLine(b *strings.Builder, f secFinding) {
	fmt.Fprintf(b, "%s\t[%s] %s: %s", f.ID, f.Severity, f.Category, f.Title)
	if f.Namespace != "" {
		fmt.Fprintf(b, " (namespace %s)", f.Namespace)
	}
	if n := len(f.Objects); n > 0 {
		var objs []string
		for _, o := range capList(f.Objects, 3) {
			objs = append(objs, o.String())
		}
		if n > 3 {
			objs = append(objs, fmt.Sprintf("+%d more", n-3))
		}
		fmt.Fprintf(b, " — %s", strings.Join(objs, ", "))
	}
	b.WriteByte('\n')
}

// find looks id up among the findings and the ignored ones. The id's
// namespace isn't known, so it scans everything, system included.
func (c *client) find(ctx context.Context, id string) (secFinding, *secRule, error) {
	r, err := c.security(ctx, "", true)
	if err != nil {
		return secFinding{}, nil, err
	}
	for _, f := range r.Findings {
		if f.ID == id {
			return f, nil, nil
		}
	}
	for _, ig := range r.Ignored {
		if ig.ID == id {
			return ig.secFinding, &ig.Rule, nil
		}
	}
	if len(r.Pending) > 0 {
		return secFinding{}, nil, fmt.Errorf("no finding %q yet (%s still loading; try again shortly)", id, strings.Join(r.Pending, ", "))
	}
	return secFinding{}, nil, fmt.Errorf("no finding %q (see list_security_findings)", id)
}

func (c *client) securityGet(ctx context.Context, id string) (string, error) {
	f, rule, err := c.find(ctx, strings.TrimSpace(id))
	if err != nil {
		return "", err
	}
	var b strings.Builder
	fmt.Fprintf(&b, "[%s] %s\nid: %s\ncheck: %s\ncategory: %s\n", f.Severity, f.Title, f.ID, f.Check, f.Category)
	if f.Namespace != "" {
		fmt.Fprintf(&b, "namespace: %s\n", f.Namespace)
	}
	if rule != nil {
		fmt.Fprintf(&b, "IGNORED (%s) by %s", rule.scope(), who(rule.By))
		if rule.Reason != "" {
			fmt.Fprintf(&b, ": %q", rule.Reason)
		}
		b.WriteByte('\n')
	}
	if f.Detail != "" {
		fmt.Fprintf(&b, "\n%s\n", f.Detail)
	}
	if len(f.Checks) > 0 {
		b.WriteString("\nFailing checks:\n")
		for _, ch := range f.Checks {
			fmt.Fprintf(&b, "- %s\n", ch)
		}
	}
	if len(f.Objects) > 0 {
		fmt.Fprintf(&b, "\nAffected (%d):\n", len(f.Objects))
		for _, o := range capList(f.Objects, 100) {
			fmt.Fprintf(&b, "- %s\n", o)
		}
	}
	if f.Remediation != "" {
		fmt.Fprintf(&b, "\nSuggested remediation: %s\n", f.Remediation)
	}
	return b.String(), nil
}

// ignoreRules are the rules that ignore f at scope, like the app's Ignore
// dialog makes.
func ignoreRules(f secFinding, scope, reason string) ([]secRule, error) {
	switch scope {
	case "", "finding":
		if len(f.Objects) == 0 || len(f.Objects) > maxObjectRules {
			return nil, fmt.Errorf("%s names %d objects, so it can only be ignored with scope namespace or everywhere", f.ID, len(f.Objects))
		}
		var rs []secRule
		for _, o := range f.Objects {
			rs = append(rs, secRule{Check: f.Check, Namespace: o.Namespace, Kind: o.Kind, Name: o.Name, Reason: reason})
		}
		return rs, nil
	case "namespace":
		if f.Namespace == "" {
			return nil, fmt.Errorf("%s isn't in a namespace: use scope finding or everywhere", f.ID)
		}
		return []secRule{{Check: f.Check, Namespace: f.Namespace, Reason: reason}}, nil
	case "everywhere":
		return []secRule{{Check: f.Check, Reason: reason}}, nil
	}
	return nil, errors.New("scope must be finding, namespace or everywhere")
}

func (c *client) securityIgnore(ctx context.Context, ids []string, scope, reason string) (string, error) {
	reason = strings.TrimSpace(reason)
	if reason == "" {
		return "", errors.New("give the reason the risk is accepted; the user sees it on the Security page")
	}
	if len(ids) == 0 {
		return "", errors.New("give at least one finding id")
	}
	r, err := c.security(ctx, "", true)
	if err != nil {
		return "", err
	}
	var rules []secRule
	var done []string
	for _, id := range ids {
		id = strings.TrimSpace(id)
		i := slices.IndexFunc(r.Findings, func(f secFinding) bool { return f.ID == id })
		if i < 0 {
			if slices.ContainsFunc(r.Ignored, func(f secIgnored) bool { return f.ID == id }) {
				done = append(done, id+" was already ignored")
				continue
			}
			return "", fmt.Errorf("no finding %q (see list_security_findings); nothing was ignored", id)
		}
		rs, err := ignoreRules(r.Findings[i], scope, reason)
		if err != nil {
			return "", fmt.Errorf("%w; nothing was ignored", err)
		}
		rules = append(rules, rs...)
		done = append(done, id+": "+r.Findings[i].Title)
	}
	if len(rules) > 0 {
		if _, err := c.post(ctx, "/api/security/ignores", map[string]any{"rules": rules}); err != nil {
			return "", err
		}
	}
	return "Ignored in k8sman (the user can un-ignore them on the Security page):\n- " + strings.Join(done, "\n- ") + "\n", nil
}
