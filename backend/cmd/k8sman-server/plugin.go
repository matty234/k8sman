package main

import (
	"fmt"
	"os"
	"strings"

	"github.com/matty234/k8sman/backend/internal/plugins"
)

// pluginCommand runs `k8sman-server plugin <subcommand>`: plugin tooling
// that works without a cluster (for CI). Only validate exists so far.
func pluginCommand(args []string) int {
	if len(args) < 1 || args[0] != "validate" || len(args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: k8sman-server plugin validate <plugin folder>...")
		return 2
	}
	bad := 0
	for _, dir := range args[1:] {
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
