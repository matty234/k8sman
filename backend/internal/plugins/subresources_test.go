package plugins

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const subresManifest = `apiVersion: k8sman.dev/v1
id: guest
name: Guest
version: 1.0.0
minAppVersion: 0.2.22
permissions:
  read: [example.com/Widget]
  readSubresources: [example.com/Widget/filesystemlist, example.com/Widget/guestosinfo]
kinds:
  example.com/Widget:
    subresources:
      fs: {name: filesystemlist, group: subresources.example.com}
      os: {name: guestosinfo, when: object.spec.size > 5}
    panel:
      sections:
        - title: Guest
          blocks:
            - type: fields
              items:
                - label: Used
                  value: subresources.fs.items.map(f, f.mountPoint + "=" + string(f.usedBytes * 100 / f.totalBytes)).join(",")
                - label: OS
                  value: string(has(subresources.os))
`

// The subresources data source: answers become subresources.<name> (with
// whole numbers as ints), a failed call or a false when leaves the key
// absent with at most a note, and the panel renders either way; the
// manifest checks the permission and the denied list, and keeps
// subresources out of everything but panels.
func TestSubresourceData(t *testing.T) {
	h := demoHost(t, subresManifest)
	fs := map[string]any{"items": []any{map[string]any{"mountPoint": "/", "usedBytes": 25, "totalBytes": 100}}}
	render := func(lk *fixtureLookup, size int64) PanelOut {
		panels := h.Panels(Env{Context: "demo", Lookup: lk}, widgetType, widgetObj("w1", size))
		if len(panels) != 1 || len(panels[0].Errors) > 0 {
			t.Fatalf("panels = %+v", panels)
		}
		return panels[0]
	}
	p := render(&fixtureLookup{subresources: map[string]any{"default/w1/filesystemlist": fs}}, 3)
	items := p.Sections[0].Blocks[0]["items"].([]map[string]any)
	if items[0]["value"] != "/=25" || items[1]["value"] != "false" || len(p.Notes) != 0 || p.Refresh != subresourceRefresh {
		t.Fatalf("panel = %+v", p)
	}
	// No answer (no guest agent): the key is absent, a note says why, and
	// the block that reads it shows its own error while the rest renders.
	p = render(&fixtureLookup{subresources: map[string]any{}}, 3)
	if len(p.Notes) != 1 || !strings.HasPrefix(p.Notes[0], "subresources.fs: ") || p.Sections[0].Blocks[0]["type"] != "fields" {
		t.Fatalf("failed call: %+v", p)
	}

	for bad, want := range map[string]string{
		"      log: {name: log}\n":  "plugins can't call the log subresource",
		"      st: {name: stats}\n": "example.com/Widget/stats is not in permissions.readSubresources",
	} {
		src := strings.Replace(subresManifest, "    panel:\n", bad+"    panel:\n", 1)
		if !strings.Contains(diagsOf(t, src), want) {
			t.Fatalf("%q: want %q in %s", bad, want, diagsOf(t, src))
		}
	}
	col := strings.Replace(subresManifest, "    panel:\n", "    columns:\n      - {name: N, value: string(has(subresources.fs))}\n    panel:\n", 1)
	if got := diagsOf(t, col); !strings.Contains(got, "subresources isn't available in columns") {
		t.Fatalf("subresources in a column: %s", got)
	}
}

func diagsOf(t *testing.T, src string) string {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ManifestFile), []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, d := range Validate(dir) {
		out = append(out, d.Message)
	}
	return strings.Join(out, "\n")
}
