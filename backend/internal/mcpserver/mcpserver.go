// Package mcpserver is `k8sman-server mcp`: a stdio MCP server Claude Code
// starts, which reads the cluster through the running k8sman app. It finds
// the app through mcp.json (see Discovery) on every call, so it keeps
// working across app relaunches, and the app only accepts its token for a
// fixed set of reads that never include Secrets (mcpAllowed in the server
// package). It sees the context k8sman shows.
package mcpserver

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// Run serves MCP on stdin/stdout until the client goes away.
func Run(ctx context.Context, version, discoveryPath string) error {
	c := &client{path: discoveryPath, http: &http.Client{Timeout: 45 * time.Second}}
	s := mcp.NewServer(&mcp.Implementation{Name: "k8sman", Version: version}, &mcp.ServerOptions{
		Instructions: "Reads the Kubernetes cluster open in the k8sman desktop app (its current context), read-only. " +
			"Start with list_problems to see what's broken, then get_resource, get_events and get_logs on the objects involved. " +
			"For security, list_security_findings and get_security_finding show k8sman's Security page; " +
			"ignore_security_findings hides findings the user accepts as intended (only k8sman's own list, the cluster is unchanged): " +
			"confirm with the user and always give the reason. Secrets can't be read.",
	})
	register(s, c)
	return s.Run(ctx, &mcp.StdioTransport{})
}

func register(s *mcp.Server, c *client) {
	ro := &mcp.ToolAnnotations{ReadOnlyHint: true}

	mcp.AddTool(s, &mcp.Tool{Name: "cluster_info", Annotations: ro,
		Description: "The kube context and API server k8sman is showing, whether it's connected, and the namespaces."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ struct{}) (*mcp.CallToolResult, any, error) {
			return text(c.clusterInfo(ctx))
		})

	type nsArgs struct {
		Namespace string `json:"namespace,omitempty" jsonschema:"only this namespace (default: all)"`
	}
	mcp.AddTool(s, &mcp.Tool{Name: "list_problems", Annotations: ro,
		Description: "What's unhealthy, from k8sman's overview analysis: crash-looping, image-pull, pending or OOM-killed pods, " +
			"unavailable workloads, failed jobs, node pressure, pending PVCs, Argo CD sync failures, plus the most frequent Warning events. " +
			"Each issue names the object, the reason and when it started."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a nsArgs) (*mcp.CallToolResult, any, error) {
			return text(c.problems(ctx, a.Namespace))
		})

	mcp.AddTool(s, &mcp.Tool{Name: "list_resource_types", Annotations: ro,
		Description: "Every resource type the cluster serves, CRDs included: kind, plural.group, whether it's namespaced, and short names."},
		func(ctx context.Context, _ *mcp.CallToolRequest, _ struct{}) (*mcp.CallToolResult, any, error) {
			return text(c.resourceTypes(ctx))
		})

	type listArgs struct {
		Kind          string `json:"kind" jsonschema:"kind, plural or short name, optionally with .group (e.g. pods, deploy, Certificate.cert-manager.io)"`
		Namespace     string `json:"namespace,omitempty" jsonschema:"only this namespace (default: all)"`
		LabelSelector string `json:"labelSelector,omitempty" jsonschema:"e.g. app=web"`
		FieldSelector string `json:"fieldSelector,omitempty" jsonschema:"e.g. status.phase!=Running"`
		Limit         int    `json:"limit,omitempty" jsonschema:"most rows to return (default 200)"`
	}
	mcp.AddTool(s, &mcp.Tool{Name: "list_resources", Annotations: ro,
		Description: "List objects of one kind as a table with the same columns k8sman shows (status, readiness, restarts, age, …)."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a listArgs) (*mcp.CallToolResult, any, error) {
			return text(c.list(ctx, a.Kind, a.Namespace, a.LabelSelector, a.FieldSelector, a.Limit))
		})

	type objArgs struct {
		Kind      string `json:"kind" jsonschema:"kind, plural or short name, optionally with .group"`
		Name      string `json:"name"`
		Namespace string `json:"namespace,omitempty" jsonschema:"required for namespaced kinds"`
	}
	mcp.AddTool(s, &mcp.Tool{Name: "get_resource", Annotations: ro,
		Description: "One object as YAML (spec and status; managedFields left out)."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a objArgs) (*mcp.CallToolResult, any, error) {
			return text(c.object(ctx, a.Kind, a.Name, a.Namespace))
		})
	mcp.AddTool(s, &mcp.Tool{Name: "get_events", Annotations: ro,
		Description: "Kubernetes events about one object, newest first."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a objArgs) (*mcp.CallToolResult, any, error) {
			return text(c.events(ctx, a.Kind, a.Name, a.Namespace))
		})

	type logArgs struct {
		Namespace string `json:"namespace"`
		Pod       string `json:"pod"`
		Container string `json:"container,omitempty" jsonschema:"default: the pod's default container"`
		Previous  bool   `json:"previous,omitempty" jsonschema:"the previous (crashed) instance's logs"`
		TailLines int    `json:"tailLines,omitempty" jsonschema:"last N lines (default 200, at most 5000)"`
	}
	mcp.AddTool(s, &mcp.Tool{Name: "get_logs", Annotations: ro,
		Description: "A container's recent logs. For a crash-looping container, previous=true shows why the last instance died."},
		func(ctx context.Context, _ *mcp.CallToolRequest, a logArgs) (*mcp.CallToolResult, any, error) {
			q := url.Values{"namespace": {a.Namespace}, "pod": {a.Pod}}
			if a.Container != "" {
				q.Set("container", a.Container)
			}
			if a.Previous {
				q.Set("previous", "true")
			}
			if a.TailLines > 0 {
				q.Set("tailLines", fmt.Sprint(a.TailLines))
			}
			b, err := c.get(ctx, "/api/logs/text", q)
			if err == nil && len(b) == 0 {
				return text("(no log lines)", nil)
			}
			return text(string(b), err)
		})

	registerSecurity(s, c)
}

// text turns a tool's result into MCP content; errors become tool errors
// the model can read, not protocol failures.
func text(s string, err error) (*mcp.CallToolResult, any, error) {
	if err != nil {
		return &mcp.CallToolResult{IsError: true, Content: []mcp.Content{&mcp.TextContent{Text: err.Error()}}}, nil, nil
	}
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: s}}}, nil, nil
}

// ---- client of the app's API -------------------------------------------------

type client struct {
	path string
	http *http.Client
}

func (c *client) get(ctx context.Context, path string, q url.Values) ([]byte, error) {
	return c.do(ctx, http.MethodGet, path, q, nil)
}

// post sends body as JSON.
func (c *client) post(ctx context.Context, path string, body any) ([]byte, error) {
	b, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	return c.do(ctx, http.MethodPost, path, nil, b)
}

func (c *client) do(ctx context.Context, method, path string, q url.Values, body []byte) ([]byte, error) {
	d, err := ReadDiscovery(c.path)
	if err != nil {
		return nil, err
	}
	u := "http://" + d.Addr + path
	if len(q) > 0 {
		u += "?" + q.Encode()
	}
	var rd io.Reader
	if body != nil {
		rd = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, u, rd)
	if err != nil {
		return nil, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	req.Header.Set("Authorization", "Bearer "+d.Token)
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("can't reach k8sman (is the app still open?): %w", err)
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode == http.StatusUnauthorized {
		return nil, ErrNotRunning
	}
	if resp.StatusCode/100 != 2 {
		var e struct {
			Error string `json:"error"`
		}
		if json.Unmarshal(b, &e) == nil && e.Error != "" {
			return nil, errors.New(e.Error)
		}
		return nil, fmt.Errorf("k8sman answered %s", resp.Status)
	}
	return b, nil
}

func (c *client) getJSON(ctx context.Context, path string, q url.Values, v any) error {
	b, err := c.get(ctx, path, q)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, v)
}

func (c *client) clusterInfo(ctx context.Context) (string, error) {
	var h struct {
		Connected  bool   `json:"connected"`
		Context    string `json:"context"`
		Host       string `json:"host"`
		Kubeconfig string `json:"kubeconfig"`
		Error      string `json:"error"`
	}
	if err := c.getJSON(ctx, "/api/health", nil, &h); err != nil {
		return "", err
	}
	var b strings.Builder
	fmt.Fprintf(&b, "context: %s\nserver: %s\nconnected: %v\n", h.Context, h.Host, h.Connected)
	if h.Error != "" {
		fmt.Fprintf(&b, "error: %s\n", h.Error)
	}
	var ns struct {
		Namespaces []string `json:"namespaces"`
		Listed     bool     `json:"listed"`
	}
	if h.Connected && c.getJSON(ctx, "/api/namespaces", nil, &ns) == nil {
		if !ns.Listed {
			b.WriteString("namespaces: can't list them (forbidden)\n")
		}
		fmt.Fprintf(&b, "namespaces (%d): %s\n", len(ns.Namespaces), strings.Join(capList(ns.Namespaces, 300), ", "))
	}
	return b.String(), nil
}

func (c *client) problems(ctx context.Context, ns string) (string, error) {
	q := url.Values{"wait": {"5s"}}
	if ns != "" {
		q.Set("namespace", ns)
	}
	var o struct {
		Issues []struct {
			Severity, Category, Kind, Namespace, Name, Reason, Message, Since string
			Count                                                             int
			Owner                                                             *struct{ Kind, Name string }
		} `json:"issues"`
		TopWarnings []struct {
			Reason        string
			Count         int
			LatestMessage string `json:"latestMessage"`
			Example       struct{ Kind, Namespace, Name string }
		} `json:"topWarnings"`
		Errors  map[string]string `json:"errors"`
		Pending []string          `json:"pending"`
	}
	if err := c.getJSON(ctx, "/api/overview", q, &o); err != nil {
		return "", err
	}
	var b strings.Builder
	if len(o.Issues) == 0 {
		b.WriteString("No problems found.\n")
	}
	for i, is := range o.Issues {
		if i == 200 {
			fmt.Fprintf(&b, "… and %d more\n", len(o.Issues)-i)
			break
		}
		fmt.Fprintf(&b, "[%s] %s %s: %s", is.Severity, is.Kind, qualified(is.Namespace, is.Name), is.Reason)
		if is.Message != "" {
			fmt.Fprintf(&b, ": %s", is.Message)
		}
		var extra []string
		if is.Since != "" {
			extra = append(extra, "since "+is.Since)
		}
		if is.Count > 0 {
			extra = append(extra, fmt.Sprintf("%d restarts", is.Count))
		}
		if is.Owner != nil {
			extra = append(extra, "owner "+is.Owner.Kind+"/"+is.Owner.Name)
		}
		if len(extra) > 0 {
			fmt.Fprintf(&b, " (%s)", strings.Join(extra, ", "))
		}
		b.WriteByte('\n')
	}
	if len(o.TopWarnings) > 0 {
		b.WriteString("\nMost frequent Warning events (last hour):\n")
		for _, w := range o.TopWarnings {
			fmt.Fprintf(&b, "- %s ×%d, e.g. %s %s: %s\n", w.Reason, w.Count, w.Example.Kind, qualified(w.Example.Namespace, w.Example.Name), w.LatestMessage)
		}
	}
	for k, e := range o.Errors {
		fmt.Fprintf(&b, "\nCouldn't read %s: %s", k, e)
	}
	if len(o.Pending) > 0 {
		fmt.Fprintf(&b, "\nStill loading (ask again shortly for these): %s\n", strings.Join(o.Pending, ", "))
	}
	return b.String(), nil
}

type resourceType struct {
	Group      string   `json:"group"`
	Version    string   `json:"version"`
	Resource   string   `json:"resource"`
	Kind       string   `json:"kind"`
	Namespaced bool     `json:"namespaced"`
	ShortNames []string `json:"shortNames"`
	Custom     bool     `json:"custom"`
}

func (c *client) types(ctx context.Context) ([]resourceType, error) {
	var ts []resourceType
	return ts, c.getJSON(ctx, "/api/resources", nil, &ts)
}

func (c *client) resourceTypes(ctx context.Context) (string, error) {
	ts, err := c.types(ctx)
	if err != nil {
		return "", err
	}
	var b strings.Builder
	for _, t := range ts {
		scope := "cluster"
		if t.Namespaced {
			scope = "namespaced"
		}
		fmt.Fprintf(&b, "%s\t%s\t%s", t.Kind, plural(t), scope)
		if len(t.ShortNames) > 0 {
			fmt.Fprintf(&b, "\t%s", strings.Join(t.ShortNames, ","))
		}
		b.WriteByte('\n')
	}
	return b.String(), nil
}

// resolve finds the type the model means by s: a plural, kind or short
// name, optionally followed by .group. Core and built-in types win a tie.
func (c *client) resolve(ctx context.Context, s string) (resourceType, error) {
	ts, err := c.types(ctx)
	if err != nil {
		return resourceType{}, err
	}
	want := strings.ToLower(strings.TrimSpace(s))
	var hits []resourceType
	for _, t := range ts {
		names := append([]string{t.Resource, strings.ToLower(t.Kind)}, t.ShortNames...)
		for _, n := range names {
			if want == n || (t.Group != "" && want == n+"."+t.Group) {
				hits = append(hits, t)
				break
			}
		}
	}
	if len(hits) > 1 {
		if i := slices.IndexFunc(hits, func(t resourceType) bool { return t.Group == "" }); i >= 0 {
			hits = hits[i : i+1]
		} else if builtin := slices.DeleteFunc(slices.Clone(hits), func(t resourceType) bool { return t.Custom }); len(builtin) == 1 {
			hits = builtin
		}
	}
	switch len(hits) {
	case 0:
		return resourceType{}, fmt.Errorf("no resource type %q on this cluster (see list_resource_types)", s)
	case 1:
		if hits[0].Group == "" && hits[0].Resource == "secrets" {
			return resourceType{}, errors.New("k8sman doesn't let Claude Code read Secrets")
		}
		return hits[0], nil
	}
	var opts []string
	for _, t := range hits {
		opts = append(opts, plural(t))
	}
	return resourceType{}, fmt.Errorf("%q is ambiguous: use one of %s", s, strings.Join(opts, ", "))
}

func (t resourceType) query() url.Values {
	return url.Values{"group": {t.Group}, "version": {t.Version}, "resource": {t.Resource}}
}

func (c *client) list(ctx context.Context, kind, ns, labels, fields string, limit int) (string, error) {
	t, err := c.resolve(ctx, kind)
	if err != nil {
		return "", err
	}
	q := t.query()
	for k, v := range map[string]string{"namespace": ns, "labelSelector": labels, "fieldSelector": fields} {
		if v != "" {
			q.Set(k, v)
		}
	}
	var tbl struct {
		Columns []struct{ Name string } `json:"columns"`
		Rows    []struct {
			Name, Namespace string
			Cells           []any
		} `json:"rows"`
		PartialErrors []struct{ Namespace, Error string } `json:"partialErrors"`
	}
	if err := c.getJSON(ctx, "/api/table", q, &tbl); err != nil {
		return "", err
	}
	if limit <= 0 {
		limit = 200
	}
	var b strings.Builder
	fmt.Fprintf(&b, "%d %s\n", len(tbl.Rows), plural(t))
	if len(tbl.Rows) == 0 {
		return b.String(), nil
	}
	// Most kinds' columns already include Name and Namespace; add them
	// in front only when they don't.
	var head []string
	for _, col := range tbl.Columns {
		head = append(head, strings.ToUpper(col.Name))
	}
	addNS := t.Namespaced && !slices.Contains(head, "NAMESPACE")
	addName := !slices.Contains(head, "NAME")
	if addName {
		head = append([]string{"NAME"}, head...)
	}
	if addNS {
		head = append([]string{"NAMESPACE"}, head...)
	}
	b.WriteString(strings.Join(head, "\t") + "\n")
	for i, r := range tbl.Rows {
		if i == limit {
			fmt.Fprintf(&b, "… and %d more (narrow with namespace or a selector)\n", len(tbl.Rows)-i)
			break
		}
		var row []string
		if addNS {
			row = append(row, r.Namespace)
		}
		if addName {
			row = append(row, r.Name)
		}
		for _, cell := range r.Cells {
			row = append(row, cellText(cell))
		}
		b.WriteString(strings.Join(row, "\t") + "\n")
	}
	for _, e := range tbl.PartialErrors {
		fmt.Fprintf(&b, "couldn't read namespace %s: %s\n", e.Namespace, e.Error)
	}
	return b.String(), nil
}

func (c *client) object(ctx context.Context, kind, name, ns string) (string, error) {
	t, err := c.resolve(ctx, kind)
	if err != nil {
		return "", err
	}
	q := t.query()
	q.Set("name", name)
	q.Set("format", "yaml")
	if t.Namespaced {
		if ns == "" {
			return "", fmt.Errorf("%s are namespaced: give a namespace", plural(t))
		}
		q.Set("namespace", ns)
	}
	b, err := c.get(ctx, "/api/object", q)
	return string(b), err
}

func (c *client) events(ctx context.Context, kind, name, ns string) (string, error) {
	t, err := c.resolve(ctx, kind)
	if err != nil {
		return "", err
	}
	q := url.Values{"kind": {t.Kind}, "name": {name}}
	if ns != "" {
		q.Set("namespace", ns)
	}
	var ev struct {
		Items []struct {
			Type, Reason, Message string
			Count                 int32
			LastTimestamp         string `json:"lastTimestamp"`
			EventTime             string `json:"eventTime"`
		} `json:"items"`
	}
	if err := c.getJSON(ctx, "/api/events", q, &ev); err != nil {
		return "", err
	}
	if len(ev.Items) == 0 {
		return "No events (Kubernetes keeps them for about an hour).", nil
	}
	var b strings.Builder
	for _, e := range capList(ev.Items, 100) {
		at := e.LastTimestamp
		if at == "" {
			at = e.EventTime
		}
		fmt.Fprintf(&b, "%s\t%s\t%s", at, e.Type, e.Reason)
		if e.Count > 1 {
			fmt.Fprintf(&b, " ×%d", e.Count)
		}
		fmt.Fprintf(&b, "\t%s\n", e.Message)
	}
	return b.String(), nil
}

// ---- helpers -------------------------------------------------------------------

func plural(t resourceType) string {
	if t.Group == "" {
		return t.Resource
	}
	return t.Resource + "." + t.Group
}

func qualified(ns, name string) string {
	if ns == "" {
		return name
	}
	return ns + "/" + name
}

func cellText(v any) string {
	switch v := v.(type) {
	case nil:
		return ""
	case string:
		return strings.ReplaceAll(v, "\t", " ")
	case float64:
		return strconv.FormatFloat(v, 'f', -1, 64)
	case bool:
		return strconv.FormatBool(v)
	case map[string]any:
		// "usage" cells: {raw, base, percent, unit}.
		if raw, ok := v["raw"].(float64); ok {
			if pct, ok := v["percent"].(float64); ok {
				return fmt.Sprintf("%s (%.0f%%)", strconv.FormatFloat(raw, 'f', -1, 64), pct)
			}
			return strconv.FormatFloat(raw, 'f', -1, 64)
		}
	}
	b, _ := json.Marshal(v)
	return string(b)
}

func capList[T any](xs []T, n int) []T {
	if len(xs) > n {
		return xs[:n]
	}
	return xs
}
