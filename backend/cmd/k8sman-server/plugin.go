package main

import (
	"fmt"
	"os"
	"slices"
	"strings"

	"github.com/matty234/k8sman/backend/internal/plugins"
)

const pluginUsage = `usage: k8sman-server plugin <command> …

  validate <folder>...          load and compile; exit 1 on errors
  test [--update] <folder>...   render every fixture and compare with fixtures/__snapshots__
  render <folder> <fixture.yaml>  print what a fixture renders to
  new <id> [<parent folder>]    start a plugin (with one fixture and its snapshot)
  import-k9s [--id <id>] <plugins.yaml>  convert k9s plugins to shell actions (to stdout)
  schema                        print plugin.yaml's JSON Schema
  keygen <private-key-file>     new ed25519 index key; prints the public key
  pack <folder> -o <out-dir>    validate, then write <id>-<version>.tar.gz
  index <plugins-root> -o <out-dir> [--base-url URL] [--revoked FILE] [--previous index.json]
                                pack every plugin and write index.json (signed with $K8SMAN_PLUGIN_INDEX_KEY)
  verify-index <dir> --key <base64 public key>  check index.json.sig and the packages
`

// pluginCommand runs `k8sman-server plugin <subcommand>`: plugin tooling
// that works without a cluster (for CI).
func pluginCommand(args []string) int {
	if len(args) < 1 {
		fmt.Fprint(os.Stderr, pluginUsage)
		return 2
	}
	rest := args[1:]
	switch args[0] {
	case "validate":
		if len(rest) == 0 {
			break
		}
		return pluginValidate(rest)
	case "test":
		update := slices.Contains(rest, "--update")
		rest = slices.DeleteFunc(rest, func(a string) bool { return a == "--update" })
		if len(rest) == 0 {
			break
		}
		return pluginTest(rest, update)
	case "render":
		if len(rest) != 2 {
			break
		}
		out, err := plugins.RenderFixture(rest[0], rest[1])
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		os.Stdout.Write(out)
		return 0
	case "new":
		if len(rest) < 1 || len(rest) > 2 {
			break
		}
		parent := "."
		if len(rest) == 2 {
			parent = rest[1]
		}
		dir, err := plugins.Scaffold(parent, rest[0])
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		fmt.Printf("Created %s. Load it in Settings ▸ Integrations ▸ Plugins, or run k8sman-server plugin test %s\n", dir, dir)
		return 0
	case "import-k9s":
		id := ""
		if len(rest) >= 2 && rest[0] == "--id" {
			id, rest = rest[1], rest[2:]
		}
		if len(rest) != 1 {
			break
		}
		src, err := os.ReadFile(rest[0])
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		out, warns, err := plugins.ImportK9s(src, id)
		for _, w := range warns {
			fmt.Fprintln(os.Stderr, "warning:", w)
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		os.Stdout.Write(out)
		return 0
	case "schema":
		os.Stdout.Write(plugins.JSONSchema())
		return 0
	case "keygen":
		if rc := pluginKeygen(rest); rc != 2 {
			return rc
		}
	case "pack":
		if rc := pluginPack(rest); rc != 2 {
			return rc
		}
	case "index":
		if rc := pluginIndex(rest); rc != 2 {
			return rc
		}
	case "verify-index":
		if rc := pluginVerifyIndex(rest); rc != 2 {
			return rc
		}
	}
	fmt.Fprint(os.Stderr, pluginUsage)
	return 2
}

func pluginValidate(dirs []string) int {
	bad := 0
	for _, dir := range dirs {
		errs, warns := 0, 0
		for _, d := range plugins.Validate(dir) {
			kind := "error"
			if d.Warning {
				kind = "warning"
				warns++
			} else {
				errs++
			}
			fmt.Printf("%s/%s: %s: %s\n", strings.TrimSuffix(dir, "/"), d.Pos, kind, d.Message)
			if d.Snippet != "" {
				fmt.Printf("    %s\n    %s^\n", d.Snippet, strings.Repeat(" ", max(0, d.Col-1)))
			}
		}
		if errs > 0 {
			bad++
		}
		fmt.Printf("%s: %d errors, %d warnings\n", dir, errs, warns)
	}
	if bad > 0 {
		return 1
	}
	return 0
}

func pluginTest(dirs []string, update bool) int {
	failed := 0
	for _, dir := range dirs {
		results, err := plugins.RunFixtures(dir, update)
		if err != nil {
			fmt.Printf("%s: %v\n", dir, err)
			failed++
			continue
		}
		n := map[string]int{}
		for _, r := range results {
			n[r.Status]++
			switch r.Status {
			case "fail":
				failed++
				fmt.Printf("FAIL %s\n", r.Fixture)
				if r.Err != nil {
					fmt.Printf("    %v\n", r.Err)
				}
				if r.Diff != "" {
					fmt.Print(indent(r.Diff, "    "))
				}
			case "missing":
				failed++
				fmt.Printf("MISSING %s: no snapshot yet; run with --update\n", r.Fixture)
			case "updated":
				fmt.Printf("UPDATED %s\n", r.Fixture)
			default:
				fmt.Printf("ok   %s\n", r.Fixture)
			}
		}
		fmt.Printf("%s: %d passed, %d failed, %d missing, %d updated\n", dir, n["pass"], n["fail"], n["missing"], n["updated"])
	}
	if failed > 0 {
		return 1
	}
	return 0
}

func indent(s, pre string) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	for i, l := range lines {
		lines[i] = pre + l
	}
	return strings.Join(lines, "\n") + "\n"
}
