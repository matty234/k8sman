package plugins

import (
	"strings"
)

// Shell actions follow k9s: command + args, with $VAR (or ${VAR})
// expanded in each argument separately. Supported: $NAME, $NAMESPACE,
// $CONTEXT, $CLUSTER, $USER, $KUBECONFIG, $GROUP, $VERSION, $RESOURCE,
// $KIND and $COL-<NAME> (a column of the object's row, upper-cased,
// spaces as _). Anything else, e.g. $K8SMAN_NAME in an `sh -c` script, is
// left as written for the shell to expand; $$ is a literal $.

// ShellVars are the variables of one object.
type ShellVars map[string]string

// ColumnVar is the variable name of table column name: COL-<NAME>.
func ColumnVar(name string) string {
	return "COL-" + strings.ToUpper(strings.ReplaceAll(strings.TrimSpace(name), " ", "_"))
}

// Expand expands the variables in one argument.
func (v ShellVars) Expand(arg string) string {
	if !strings.Contains(arg, "$") {
		return arg
	}
	var b strings.Builder
	for i := 0; i < len(arg); {
		c := arg[i]
		if c != '$' || i+1 >= len(arg) {
			b.WriteByte(c)
			i++
			continue
		}
		if arg[i+1] == '$' {
			b.WriteByte('$')
			i += 2
			continue
		}
		if arg[i+1] == '{' {
			if end := strings.IndexByte(arg[i+2:], '}'); end >= 0 {
				name := arg[i+2 : i+2+end]
				if val, ok := v[name]; ok {
					b.WriteString(val)
				} else {
					b.WriteString(arg[i : i+3+end])
				}
				i += 3 + end
				continue
			}
		}
		j := i + 1
		for j < len(arg) && isWordChar(arg[j]) {
			j++
		}
		name := arg[i+1 : j]
		// $COL-<NAME>: column names may hold dashes, so the longest known
		// name wins ($COL-NOT-AFTER-x keeps "-x").
		if name == "COL" && j < len(arg) && arg[j] == '-' {
			k := j + 1
			for k < len(arg) && (isWordChar(arg[k]) || arg[k] == '-') {
				k++
			}
			full := arg[i+1 : k]
			found := false
			for n := len(full); n > len("COL-"); n-- {
				if val, ok := v[full[:n]]; ok {
					b.WriteString(val)
					i += 1 + n
					found = true
					break
				}
			}
			if found {
				continue
			}
		}
		if val, ok := v[name]; ok && name != "" {
			b.WriteString(val)
		} else {
			b.WriteString(arg[i:j])
		}
		i = j
	}
	return b.String()
}

func isWordChar(c byte) bool {
	return c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_'
}

// Env is the variables exported to the command's environment as
// K8SMAN_<NAME> (COL-READY as K8SMAN_COL_READY).
func (v ShellVars) Env() []string {
	out := make([]string, 0, len(v))
	for k, val := range v {
		if k == "KUBECONFIG" {
			continue // set as KUBECONFIG itself
		}
		out = append(out, "K8SMAN_"+strings.ReplaceAll(k, "-", "_")+"="+val)
	}
	return out
}

// Argv is action a's command with its arguments expanded.
func (a *Action) Argv(v ShellVars) []string {
	if a.Shell == nil {
		return nil
	}
	out := []string{a.Shell.Command}
	for _, arg := range a.Shell.Args {
		out = append(out, v.Expand(arg))
	}
	return out
}

// ExtraEnv is the action's own env entries, expanded.
func (a *Action) ExtraEnv(v ShellVars) []string {
	if a.Shell == nil {
		return nil
	}
	out := make([]string, 0, len(a.Shell.Env))
	for k, val := range a.Shell.Env {
		out = append(out, k+"="+v.Expand(val))
	}
	return out
}
