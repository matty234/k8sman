package plugins

import (
	"fmt"
	"slices"
	"strings"
)

// The settings block (docs/PLUGINS.md §4) shows a configuration object of
// any depth as `path → value` rows, which CEL can't do (it has no
// recursion). References to other objects become links: a map with a
// string `name` under a key ending in SecretRef, ConfigMapRef or
// ServiceAccountRef (any case) links to that Secret, ConfigMap or
// ServiceAccount, in the map's `namespace` or the object's. A reference
// shows the object's name and its `key`, never anything read from the
// object: Secret values are never read here (nor anywhere by plugins).

// Rows of a settings block: settingsDefaultLimit unless the block says,
// at most settingsRowLimit.
const (
	settingsDefaultLimit = 14
	settingsRowLimit     = 50
	// settingsValueMax is the longest value shown; a longer one says how
	// long it is instead.
	settingsValueMax = 80
)

// settingsRefs are the reference shapes recognised, by the end of the key
// that holds them (lower-case). Longer suffixes first.
var settingsRefs = []struct{ suffix, kind string }{
	{"serviceaccountref", "ServiceAccount"},
	{"configmapref", "ConfigMap"},
	{"secretref", "Secret"},
}

// flattenSettings is v (a map) as rows {label, value, link?}, at most
// limit of them; total is how many there are in all. Keys are sorted, so
// the rows don't depend on map order. ns is the namespace a reference
// without one is in ("" for a cluster-scoped object: then it isn't a
// link, as the object it names can't be found).
func flattenSettings(v map[string]any, ns string, limit int) (rows []map[string]any, total int) {
	add := func(row map[string]any) {
		total++
		if len(rows) < limit {
			rows = append(rows, row)
		}
	}
	var walk func(path string, v any)
	walk = func(path string, v any) {
		if v == nil || v == "" {
			return
		}
		switch x := v.(type) {
		case map[string]any:
			if row := settingsRef(path, x, ns); row != nil {
				add(row)
				return
			}
			for _, k := range slices.Sorted(func(yield func(string) bool) {
				for k := range x {
					if !yield(k) {
						return
					}
				}
			}) {
				p := k
				if path != "" {
					p = path + "." + k
				}
				walk(p, x[k])
			}
		case []any:
			if len(x) == 0 {
				return
			}
			if slices.ContainsFunc(x, func(e any) bool {
				_, m := e.(map[string]any)
				_, l := e.([]any)
				return m || l
			}) {
				add(map[string]any{"label": path, "value": fmt.Sprintf("%d entries", len(x))})
				return
			}
			parts := make([]string, len(x))
			for i, e := range x {
				parts[i] = fmt.Sprint(e)
			}
			add(map[string]any{"label": path, "value": shorten(strings.Join(parts, ", "))})
		default:
			add(map[string]any{"label": path, "value": shorten(fmt.Sprint(x))})
		}
	}
	walk("", v)
	if rows == nil {
		rows = []map[string]any{}
	}
	return rows, total
}

// settingsRef is the row for a reference at path, or nil when m isn't one.
func settingsRef(path string, m map[string]any, ns string) map[string]any {
	name, ok := m["name"].(string)
	if !ok || name == "" {
		return nil
	}
	key := strings.ToLower(path[strings.LastIndex(path, ".")+1:])
	for _, r := range settingsRefs {
		if !strings.HasSuffix(key, r.suffix) {
			continue
		}
		text := r.kind + "/" + name
		if k, ok := m["key"].(string); ok && k != "" {
			text += " · " + k
		}
		row := map[string]any{"label": path, "value": text}
		if n, ok := m["namespace"].(string); ok && n != "" {
			ns = n
		}
		if ns != "" {
			row["link"] = map[string]any{"group": "", "kind": r.kind, "namespace": ns, "name": name}
		}
		return row
	}
	return nil
}

// shorten is s, or its length when it is too long to show.
func shorten(s string) string {
	if n := len([]rune(s)); n > settingsValueMax {
		return fmt.Sprintf("(%d characters)", n)
	}
	return s
}
