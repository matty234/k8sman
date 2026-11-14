package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/matty234/k8sman/backend/internal/mcpserver"
)

// mcpCommand runs `k8sman-server mcp`: the stdio MCP server Claude Code
// starts (claude mcp add k8sman -- <this binary> mcp). It reads the cluster
// through the running app, which has to have Claude Code access turned on.
func mcpCommand(args []string) int {
	fs := flag.NewFlagSet("mcp", flag.ContinueOnError)
	settingsPath := fs.String("settings", "", "the app's settings file, to find mcp.json beside it (default ~/.config/k8sman/settings.json)")
	discovery := fs.String("discovery", "", "the mcp.json to read (overrides --settings)")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	path := mcpserver.DiscoveryPath(*settingsPath)
	if *discovery != "" {
		path = *discovery
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := mcpserver.Run(ctx, os.Getenv("K8SMAN_APP_VERSION"), path); err != nil && ctx.Err() == nil {
		fmt.Fprintln(os.Stderr, "k8sman mcp:", err)
		return 1
	}
	return 0
}
