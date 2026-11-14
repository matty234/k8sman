package plugins

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"time"
)

// The subresources data source (since 0.2.22): a kind's subresources are
// GETs of the inspected object's subresources (KubeVirt's guestosinfo,
// filesystemlist), made by the host with the user's credentials when a
// panel that reads them renders. Like related objects and metrics, plugin
// code never makes the call: a Lookup that also implements
// SubresourceReader does.

// SubresourceReader GETs subresource sub of object ns/name of kind kindKey,
// served by group/version, and returns its JSON. ns is "" for a
// cluster-scoped object.
type SubresourceReader interface {
	GetSubresource(ctx context.Context, kindKey, group, version, ns, name, sub string) ([]byte, error)
}

// subresourceTimeout bounds one render's subresource calls (a guest agent
// call can hang until the API server gives up): past it the rest are
// absent, with a note.
const subresourceTimeout = 4 * time.Second

// subresourceRefresh is how often (seconds) a panel that reads
// subresources renders again while it is open.
const subresourceRefresh = 15

// subresourceMaxBytes caps the JSON one call may answer.
const subresourceMaxBytes = 1 << 20

// resolveSubresources fills r.act.subresources with the subresources need
// names. A call that fails (no guest agent, forbidden, timeout) leaves its
// key absent and adds a note: the panel renders with what there is.
func (r *renderer) resolveSubresources(p *Plugin, kp *kindProgs, need refSet, env Env, ns *notes) {
	out := map[string]any{}
	r.act.subresources = out
	if need.empty() {
		return
	}
	reader, _ := env.Lookup.(SubresourceReader)
	ctx, cancel := context.WithTimeout(context.Background(), subresourceTimeout)
	defer cancel()
	group, version := splitAPIVersion(r.act.object)
	name, _ := nestedString(r.act.object, "metadata", "name")
	for _, sp := range kp.subres {
		if !need.has(sp.name) {
			continue
		}
		if ok, err := r.cond(sp.when); err != nil || !ok {
			if err != nil {
				ns.add("subresources.%s: %v", sp.name, err)
			}
			continue
		}
		if reader == nil {
			ns.add("Subresources aren't available here.")
			continue
		}
		// The loader checked these; check again where the call is made.
		if subresourceDenied(kp.key, sp.sr.Name) != "" || p == nil || p.m == nil ||
			!slices.Contains(p.m.Permissions.ReadSubresources, kp.key+"/"+sp.sr.Name) {
			ns.add("subresources.%s: not allowed", sp.name)
			continue
		}
		if ctx.Err() != nil {
			ns.add("subresources.%s: skipped: the subresource calls took longer than %s", sp.name, subresourceTimeout)
			continue
		}
		b, err := reader.GetSubresource(ctx, kp.key, orDefault(sp.sr.Group, group), orDefault(sp.sr.Version, version), r.act.namespace, name, sp.sr.Name)
		if err == nil {
			var v any
			if v, err = decodeJSON(b); err == nil {
				out[sp.name] = v
				continue
			}
		}
		ns.add("subresources.%s: %s", sp.name, shortError(err))
	}
}

// splitAPIVersion is obj's API group and version.
func splitAPIVersion(obj map[string]any) (group, version string) {
	apiVersion, _ := obj["apiVersion"].(string)
	group, version, found := strings.Cut(apiVersion, "/")
	if !found {
		return "", apiVersion
	}
	return group, version
}

// decodeJSON decodes a subresource's answer with the number types the
// API server's objects have (int64 when whole, else float64).
func decodeJSON(b []byte) (any, error) {
	if len(b) > subresourceMaxBytes {
		return nil, fmt.Errorf("the answer is larger than %d bytes", subresourceMaxBytes)
	}
	d := json.NewDecoder(bytes.NewReader(b))
	d.UseNumber()
	var v any
	if err := d.Decode(&v); err != nil {
		return nil, fmt.Errorf("the answer isn't JSON: %v", err)
	}
	return normaliseNumbers(v), nil
}

// shortError keeps a note to one line of reasonable length.
func shortError(err error) string {
	s := strings.Join(strings.Fields(err.Error()), " ")
	if len(s) > 200 {
		s = s[:200] + "…"
	}
	return s
}

// GetSubresource implements SubresourceReader for fixtures: test.yaml's
// subresources answer by "<namespace>/<name>/<subresource>",
// "<name>/<subresource>" or "<subresource>", the most specific first. No
// answer is a failed call (as without a guest agent).
func (f *fixtureLookup) GetSubresource(_ context.Context, _, _, _, ns, name, sub string) ([]byte, error) {
	for _, k := range []string{ns + "/" + name + "/" + sub, name + "/" + sub, sub} {
		if v, ok := f.subresources[k]; ok {
			return json.Marshal(v)
		}
	}
	return nil, fmt.Errorf("no answer for %s in fixtures/test.yaml", sub)
}
