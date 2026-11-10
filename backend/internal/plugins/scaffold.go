package plugins

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Scaffold writes a new plugin folder dir/<id> (`plugin new`): a
// plugin.yaml for an example kind with a column, a panel section, an
// alert and a patch action, a README, and one fixture with its snapshot.
// It refuses to overwrite an existing folder.
func Scaffold(parent, id string) (string, error) {
	if !idRe.MatchString(id) {
		return "", fmt.Errorf("%q is not a plugin id: lower-case letters, digits and dashes, e.g. my-plugin", id)
	}
	dir := filepath.Join(parent, id)
	if _, err := os.Stat(dir); err == nil {
		return "", fmt.Errorf("%s already exists", dir)
	}
	files := map[string]string{
		ManifestFile: strings.ReplaceAll(scaffoldManifest, "{{id}}", id),
		"README.md":  strings.ReplaceAll(scaffoldReadme, "{{id}}", id),
		filepath.Join(FixtureDir, FixtureConfigFile): scaffoldTestYAML,
		filepath.Join(FixtureDir, "widget.yaml"):     scaffoldFixture,
	}
	for name, body := range files {
		path := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return "", err
		}
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			return "", err
		}
	}
	if _, err := RunFixtures(dir, true); err != nil {
		return dir, err
	}
	return dir, nil
}

const scaffoldManifest = SchemaComment + `
apiVersion: k8sman.dev/v1
id: {{id}}
name: {{id}}
version: 0.1.0
description: Columns, a panel, an alert and an action for example.com Widgets.
authors: [you]

permissions:
  read: [example.com/Widget, /ConfigMap]
  patch: [example.com/Widget]

kinds:
  example.com/Widget:
    variables:
      ready: conditionTrue(object, "Ready")
    related:
      config:                       # one object, by name
        kind: /ConfigMap
        name: object.spec.configRef
    columns:
      - name: Ready
        type: status
        value: 'variables.ready ? "Ready" : "Not ready"'
      - name: Size
        type: number
        value: object.spec.?size.orValue(1)
    panel:
      sections:
        - title: Widget
          icon: extension
          blocks:
            - type: message
              severity: warning
              when: '!variables.ready'
              text: condition(object, "Ready").?message.orValue("Not ready")
            - type: fields
              items:
                - label: Size
                  type: number
                  value: object.spec.?size.orValue(1)
                - label: Config
                  value: object.spec.configRef
                  link: ref("", "ConfigMap", object.spec.configRef)
                - label: Config keys
                  value: related.?config.?data.orValue({}).map(k, k).sort().join(", ")
    actions:
      - id: resize
        label: Resize…
        icon: tune
        dangerous: false
        inputs:
          - name: size
            label: Size
            type: int
            default: object.spec.?size.orValue(1)
            validate: input.size >= 1 && input.size <= 10
            validateMessage: Enter a size from 1 to 10.
        patch:
          type: merge
          body: '{"spec": {"size": input.size}}'
    alerts:
      - id: not-ready
        label: Widgets not ready
        severity: warning
        when: '!variables.ready'
        message: condition(object, "Ready").?message.orValue("Not ready")
`

const scaffoldReadme = `# {{id}}

A [k8sman plugin](https://github.com/matty234/k8sman/blob/main/docs/PLUGINS.md).

- Load it: Settings ▸ Integrations ▸ Plugins ▸ Developer mode ▸ Load plugin folder…
- Check it: ` + "`k8sman-server plugin validate .`" + `
- Test it against the fixtures: ` + "`k8sman-server plugin test .`" + ` (` + "`--update`" + ` rewrites the snapshots)
`

const scaffoldTestYAML = `# Settings for the fixtures: the time they see, the context name, and
# whether the context is read-only. metrics answers PromQL queries.
now: 2026-01-01T00:00:00Z
context: demo
readOnly: false
`

const scaffoldFixture = `# The first document is the object; the others are what related lookups see.
apiVersion: example.com/v1
kind: Widget
metadata:
  name: demo
  namespace: default
  uid: 00000000-0000-0000-0000-000000000001
  creationTimestamp: "2025-12-01T00:00:00Z"
spec:
  size: 3
  configRef: demo-config
status:
  conditions:
    - type: Ready
      status: "False"
      reason: Waiting
      message: Waiting for the config
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: demo-config
  namespace: default
data:
  color: blue
  shape: round
`
