package plugins

import (
	"fmt"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

// ImportK9s converts a k9s plugins.yaml (`plugins: {name: {shortCut,
// description, scopes, command, args, background, confirm, dangerous}}`)
// into a plugin.yaml of shell actions (`plugin import-k9s`). Scopes are
// mapped to kind keys with a built-in table of Kubernetes kinds; a
// custom resource scope (plural.group) is guessed and flagged, and one
// the table doesn't know is skipped with a warning (there is no cluster
// to ask). A missing dangerous becomes true. Entries using $POD,
// $CONTAINER or $FILTER, which v1 doesn't support, are skipped.
func ImportK9s(src []byte, id string) ([]byte, []string, error) {
	var root map[string]yaml.Node
	if err := yaml.Unmarshal(src, &root); err != nil {
		return nil, nil, fmt.Errorf("plugins.yaml: %w", err)
	}
	entries := map[string]k9sPlugin{}
	node, ok := root["plugins"]
	if !ok {
		// An older file without the top-level key.
		node = yaml.Node{}
		if err := yaml.Unmarshal(src, &node); err != nil {
			return nil, nil, err
		}
	}
	if err := node.Decode(&entries); err != nil {
		return nil, nil, fmt.Errorf("plugins.yaml: %w", err)
	}
	if id == "" {
		id = "k9s-plugins"
	}
	var warns []string
	warn := func(format string, args ...any) { warns = append(warns, fmt.Sprintf(format, args...)) }

	type action struct {
		key  string
		yaml string
	}
	var acts []action
	read := map[string]bool{}
	commands := map[string]bool{}
	names := slices.Sorted(func(yield func(string) bool) {
		for n := range entries {
			if !yield(n) {
				return
			}
		}
	})
	usedIDs := map[string]bool{}
	for _, name := range names {
		e := entries[name]
		if len(e.Unknown) > 0 {
			warn("%s: ignored %s (not supported)", name, strings.Join(slices.Sorted(func(yield func(string) bool) {
				for k := range e.Unknown {
					if !yield(k) {
						return
					}
				}
			}), ", "))
		}
		if e.Command == "" {
			warn("%s: skipped (no command)", name)
			continue
		}
		all := strings.Join(append([]string{e.Command}, e.Args...), " ")
		if bad := k9sUnsupported.FindString(all); bad != "" {
			warn("%s: skipped (%s isn't supported by k8sman plugins)", name, bad)
			continue
		}
		var keys []string
		for _, s := range e.Scopes {
			key, guessed, ok := k9sScope(s)
			switch {
			case !ok:
				warn("%s: scope %q skipped (unknown kind; add it as group/Kind)", name, s)
				continue
			case guessed:
				warn("%s: scope %q mapped to %s (a guess; check it)", name, s, key)
			}
			if !slices.Contains(keys, key) {
				keys = append(keys, key)
			}
		}
		if len(keys) == 0 {
			warn("%s: skipped (no scope k8sman knows)", name)
			continue
		}
		aid := k9sID(name)
		for usedIDs[aid] {
			aid += "-x"
		}
		usedIDs[aid] = true
		commands[e.Command] = true
		var b strings.Builder
		label := e.Description
		if label == "" {
			label = name
		}
		fmt.Fprintf(&b, "      - id: %s\n        label: %s\n", aid, yamlString(label))
		if sc := k9sShortcut(e.ShortCut); sc != "" {
			fmt.Fprintf(&b, "        shortcut: %s\n", yamlString(sc))
		}
		if e.Dangerous != nil && !*e.Dangerous {
			b.WriteString("        dangerous: false\n")
		}
		if e.Confirm != nil && !*e.Confirm {
			warn("%s: confirm: false dropped (k8sman always confirms)", name)
		}
		fmt.Fprintf(&b, "        shell:\n          command: %s\n", yamlString(e.Command))
		if len(e.Args) > 0 {
			b.WriteString("          args:\n")
			for _, a := range e.Args {
				fmt.Fprintf(&b, "            - %s\n", yamlString(k9sArg(a)))
			}
		}
		if e.Background {
			b.WriteString("          background: true\n")
		}
		for _, key := range keys {
			if key != "*" {
				read[key] = true
			}
			acts = append(acts, action{key, b.String()})
		}
	}
	if len(acts) == 0 {
		return nil, warns, fmt.Errorf("nothing to import")
	}
	var out strings.Builder
	out.WriteString(SchemaComment + "\n")
	out.WriteString("# Imported from k9s plugins.yaml by `k8sman-server plugin import-k9s`.\n")
	fmt.Fprintf(&out, "apiVersion: %s\nid: %s\nname: %s\nversion: 0.1.0\ndescription: Shell actions imported from k9s.\n", APIVersion, id, yamlString(id))
	out.WriteString("permissions:\n")
	if len(read) > 0 {
		out.WriteString("  read:\n")
		for _, k := range slices.Sorted(keysOf(read)) {
			fmt.Fprintf(&out, "    - %s\n", yamlString(k))
		}
	}
	out.WriteString("  commands:\n")
	for _, c := range slices.Sorted(keysOf(commands)) {
		fmt.Fprintf(&out, "    - %s\n", yamlString(c))
	}
	out.WriteString("kinds:\n")
	sort.SliceStable(acts, func(i, j int) bool { return acts[i].key < acts[j].key })
	last := ""
	for _, a := range acts {
		if a.key != last {
			fmt.Fprintf(&out, "  %s:\n    actions:\n", yamlString(a.key))
			last = a.key
		}
		out.WriteString(a.yaml)
	}
	return []byte(out.String()), warns, nil
}

func keysOf(m map[string]bool) func(func(string) bool) {
	return func(yield func(string) bool) {
		for k := range m {
			if !yield(k) {
				return
			}
		}
	}
}

// k9sPlugin is one entry of a k9s plugins.yaml.
type k9sPlugin struct {
	ShortCut    string
	Description string
	Scopes      []string
	Command     string
	Args        []string
	Background  bool
	Confirm     *bool
	Dangerous   *bool
	Unknown     map[string]bool
}

func (k *k9sPlugin) UnmarshalYAML(n *yaml.Node) error {
	var raw map[string]yaml.Node
	if err := n.Decode(&raw); err != nil {
		return err
	}
	k.Unknown = map[string]bool{}
	for key, v := range raw {
		var err error
		switch key {
		case "shortCut":
			err = v.Decode(&k.ShortCut)
		case "description":
			err = v.Decode(&k.Description)
		case "scopes":
			err = v.Decode(&k.Scopes)
		case "command":
			err = v.Decode(&k.Command)
		case "args":
			err = v.Decode(&k.Args)
		case "background":
			err = v.Decode(&k.Background)
		case "confirm":
			err = v.Decode(&k.Confirm)
		case "dangerous":
			err = v.Decode(&k.Dangerous)
		default:
			k.Unknown[key] = true
		}
		if err != nil {
			return fmt.Errorf("%s: %w", key, err)
		}
	}
	return nil
}

var k9sUnsupported = regexp.MustCompile(`\$\{?(POD|CONTAINER|FILTER)\b`)

// k9sScopes maps k9s scopes (resource names and aliases) to kind keys.
var k9sScopes = map[string]string{}

func init() {
	for key, names := range map[string][]string{
		"*":                                     {"all"},
		"/Pod":                                  {"pods", "pod", "po"},
		"/Service":                              {"services", "service", "svc"},
		"/ConfigMap":                            {"configmaps", "configmap", "cm"},
		"/Secret":                               {"secrets", "secret", "sec"},
		"/Node":                                 {"nodes", "node", "no"},
		"/Namespace":                            {"namespaces", "namespace", "ns"},
		"/PersistentVolumeClaim":                {"persistentvolumeclaims", "persistentvolumeclaim", "pvc"},
		"/PersistentVolume":                     {"persistentvolumes", "persistentvolume", "pv"},
		"/ServiceAccount":                       {"serviceaccounts", "serviceaccount", "sa"},
		"/Event":                                {"events", "event", "ev"},
		"/Endpoints":                            {"endpoints", "ep"},
		"apps/Deployment":                       {"deployments", "deployment", "deploy", "dp"},
		"apps/StatefulSet":                      {"statefulsets", "statefulset", "sts"},
		"apps/DaemonSet":                        {"daemonsets", "daemonset", "ds"},
		"apps/ReplicaSet":                       {"replicasets", "replicaset", "rs"},
		"batch/Job":                             {"jobs", "job"},
		"batch/CronJob":                         {"cronjobs", "cronjob", "cj"},
		"networking.k8s.io/Ingress":             {"ingresses", "ingress", "ing"},
		"networking.k8s.io/NetworkPolicy":       {"networkpolicies", "networkpolicy", "netpol"},
		"autoscaling/HorizontalPodAutoscaler":   {"horizontalpodautoscalers", "hpa"},
		"rbac.authorization.k8s.io/Role":        {"roles", "role"},
		"rbac.authorization.k8s.io/RoleBinding": {"rolebindings", "rolebinding"},
		"rbac.authorization.k8s.io/ClusterRole": {"clusterroles", "clusterrole"},
		"apiextensions.k8s.io/CustomResourceDefinition": {"customresourcedefinitions", "crd", "crds"},
		"storage.k8s.io/StorageClass":                   {"storageclasses", "storageclass", "sc"},
	} {
		for _, n := range names {
			k9sScopes[n] = key
		}
	}
}

// k9sScope maps one scope. A plural.group scope (a custom resource) is
// guessed: certificates.cert-manager.io → cert-manager.io/Certificate.
func k9sScope(s string) (key string, guessed, ok bool) {
	s = strings.TrimSpace(strings.ToLower(s))
	if k, ok := k9sScopes[s]; ok {
		return k, false, true
	}
	plural, group, found := strings.Cut(s, ".")
	if !found || plural == "" || group == "" {
		return "", false, false
	}
	if k, ok := k9sScopes[plural]; ok && strings.HasPrefix(k, group+"/") {
		return k, false, true // e.g. deployments.apps
	}
	singular := plural
	switch {
	case strings.HasSuffix(plural, "ies"):
		singular = plural[:len(plural)-3] + "y"
	case strings.HasSuffix(plural, "sses"), strings.HasSuffix(plural, "xes"):
		singular = plural[:len(plural)-2]
	case strings.HasSuffix(plural, "s"):
		singular = plural[:len(plural)-1]
	}
	return group + "/" + strings.ToUpper(singular[:1]) + singular[1:], true, true
}

// k9sID makes an action id from a k9s plugin name.
func k9sID(name string) string {
	var b strings.Builder
	dash := false
	for _, r := range strings.ToLower(name) {
		if r >= 'a' && r <= 'z' || r >= '0' && r <= '9' {
			b.WriteRune(r)
			dash = false
		} else if !dash && b.Len() > 0 {
			b.WriteByte('-')
			dash = true
		}
	}
	id := strings.TrimRight(b.String(), "-")
	if len(id) > 64 {
		id = strings.TrimRight(id[:64], "-")
	}
	if id == "" {
		id = "action"
	}
	return id
}

// k9sShortcut turns k9s's "Shift-L" / "Ctrl-T" into "shift+L" / "ctrl+T".
func k9sShortcut(s string) string {
	if s == "" {
		return ""
	}
	parts := strings.Split(s, "-")
	for i := range parts[:len(parts)-1] {
		parts[i] = strings.ToLower(parts[i])
	}
	return strings.Join(parts, "+")
}

// k9sArg renames k9s variables k8sman spells differently.
func k9sArg(a string) string {
	return strings.NewReplacer("$RESOURCE_GROUP", "$GROUP", "$RESOURCE_VERSION", "$VERSION", "$RESOURCE_NAME", "$RESOURCE").Replace(a)
}

// yamlString quotes s when YAML would read it as something else.
func yamlString(s string) string {
	b, err := yaml.Marshal(s)
	if err != nil {
		return strconv.Quote(s)
	}
	return strings.TrimSuffix(string(b), "\n")
}
