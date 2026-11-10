package plugins

import "slices"

// Icons is the fixed list of Material icon names plugins may use (for
// sections, actions and kinds). Flutter tree-shakes its icon font, so the
// app can't look up arbitrary names at runtime: frontend/lib/plugins/
// plugin_icons.dart maps the same names. Keep the two lists in step.
var Icons = []string{
	"account_tree", "analytics", "apps", "backup", "badge", "bolt", "build",
	"category", "check_circle", "checklist", "cloud", "code", "dashboard",
	"data_object", "delete", "description", "dns", "edit", "error", "event",
	"extension", "folder", "group", "history", "hub", "info", "insights",
	"inventory", "key", "label", "lan", "language", "layers", "link", "lock",
	"memory", "notifications", "open_in_new", "person", "play_arrow", "policy",
	"public", "receipt", "refresh", "restart_alt", "rocket_launch", "router",
	"schedule", "security", "settings", "shield", "speed", "stop", "storage",
	"sync", "task_alt", "terminal", "timer", "tune", "upload", "verified",
	"vpn_key", "warning",
}

// IconAllowed reports whether name is in Icons.
func IconAllowed(name string) bool { return slices.Contains(Icons, name) }
