package plugins

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/fsnotify/fsnotify"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/columns"
	"github.com/matty234/k8sman/backend/internal/settings"
)

// Where a plugin was loaded from.
const (
	SourceDev       = "dev"       // a folder added in the app (settings.json)
	SourceFlag      = "flag"      // --plugin-dev
	SourceInstalled = "installed" // <settings dir>/plugins/<id>
)

// maxManifest caps plugin.yaml's size.
const maxManifest = 1 << 20

// maxIcon caps icon.png's size.
const maxIcon = 64 << 10

// Plugin is one loaded plugin folder. Its manifest and compiled kinds are
// replaced as a whole on reload; the old value keeps serving whoever holds it.
type Plugin struct {
	dir    string
	source string
	m      *Manifest
	d      *decoder
	// diags are the last load attempt's errors and warnings. When the last
	// attempt failed, m is the previous good manifest (or nil).
	diags  []Diag
	failed bool
	stats  *stats
	// eager plugins (dev ones) compile every kind at load so errors show
	// on save; installed ones compile a kind on first use.
	eager bool

	mu       sync.Mutex
	kinds    map[string]*kindProgs
	kindErrs map[string][]Diag

	loadDur    time.Duration
	compileDur time.Duration
	loadedAt   time.Time
	gen        uint64
}

// ID is the plugin's id ("" when it never loaded).
func (p *Plugin) ID() string {
	if p.m == nil {
		return ""
	}
	return p.m.ID
}

// Name is the plugin's display name.
func (p *Plugin) Name() string {
	if p.m == nil {
		return filepath.Base(p.dir)
	}
	return p.m.Name
}

// kind returns kind entry key, compiled (on first use for lazy plugins),
// or nil when the plugin has none or it failed to compile.
func (p *Plugin) kind(key string) *kindProgs {
	if p.m == nil || p.m.Kinds[key] == nil {
		return nil
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if kp, ok := p.kinds[key]; ok {
		return kp
	}
	if _, failed := p.kindErrs[key]; failed {
		return nil
	}
	return p.compileLocked(key)
}

func (p *Plugin) compileLocked(key string) *kindProgs {
	start := time.Now()
	kp, diags := compileKind(p.d, key, p.m.Kinds[key])
	p.compileDur += time.Since(start)
	if len(diags) > 0 || kp == nil {
		p.kindErrs[key] = diags
		return nil
	}
	p.kinds[key] = kp
	return kp
}

// PermissionsHash identifies the plugin's permissions; consent is given to
// a hash, so a plugin that asks for more must be agreed to again.
func (p *Plugin) PermissionsHash() string {
	if p.m == nil {
		return ""
	}
	perm := p.m.Permissions
	norm := Permissions{Read: slices.Sorted(slices.Values(perm.Read)), Patch: slices.Sorted(slices.Values(perm.Patch)), Commands: slices.Sorted(slices.Values(perm.Commands)), Prometheus: perm.Prometheus}
	b, _ := json.Marshal(struct {
		ID string
		P  Permissions
	}{p.m.ID, norm})
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:8])
}

// loadPlugin reads and checks dir/plugin.yaml; eager also compiles it.
func loadPlugin(dir, source string, eager bool) *Plugin {
	start := time.Now()
	p := &Plugin{dir: dir, source: source, stats: newStats(), eager: eager, kinds: map[string]*kindProgs{}, kindErrs: map[string][]Diag{}, loadedAt: start}
	f, err := os.Open(filepath.Join(dir, ManifestFile))
	if err != nil {
		p.diags = []Diag{{Pos: Pos{File: ManifestFile, Line: 1, Col: 1}, Message: readErr(err)}}
		p.failed = true
		return p
	}
	src, err := io.ReadAll(io.LimitReader(f, maxManifest+1))
	f.Close()
	if err == nil && len(src) > maxManifest {
		err = fmt.Errorf("plugin.yaml is larger than %d bytes", maxManifest)
	}
	if err != nil {
		p.diags = []Diag{{Pos: Pos{File: ManifestFile, Line: 1, Col: 1}, Message: err.Error()}}
		p.failed = true
		return p
	}
	m, diags := parseManifest(src)
	p.diags = diags
	p.d = &decoder{file: ManifestFile, lines: strings.Split(string(src), "\n")}
	if hasErrors(diags) {
		p.failed = true
		p.loadDur = time.Since(start)
		return p
	}
	p.m = m
	p.loadDur = time.Since(start)
	if eager {
		for _, key := range m.KindOrder {
			p.compileLocked(key)
		}
		for _, key := range m.KindOrder {
			p.diags = append(p.diags, p.kindErrs[key]...)
		}
		// A kind entry that doesn't compile is off (the others work), and
		// on a reload the previous version is kept (see mergeLocked).
		p.failed = hasErrors(p.diags)
	}
	return p
}

func readErr(err error) string {
	if errors.Is(err, os.ErrNotExist) {
		return "no plugin.yaml in this folder"
	}
	return err.Error()
}

func hasErrors(diags []Diag) bool {
	return slices.ContainsFunc(diags, func(d Diag) bool { return !d.Warning })
}

// Validate loads the plugin in dir and compiles every kind (for
// `k8sman-server plugin validate`). It returns every diag.
func Validate(dir string) []Diag {
	p := loadPlugin(dir, SourceDev, true)
	return p.diags
}

// ---- host ------------------------------------------------------------------

// Options configures a Host.
type Options struct {
	// InstalledDir holds installed plugins (<settings dir>/plugins).
	InstalledDir string
	// FlagDirs are --plugin-dev folders (they turn dev mode on).
	FlagDirs []string
	Settings *settings.Store
}

// Host holds the loaded plugins and answers the server's lookups. A nil
// *Host has no plugins.
type Host struct {
	opts Options

	mu      sync.RWMutex
	plugins []*Plugin // sorted by id, then folder
	gen     uint64
	changed chan struct{}

	wmu     sync.Mutex
	watcher *fsnotify.Watcher
	watched map[string]bool
	timers  map[string]*time.Timer
}

// NewHost makes a host; call Start to load.
func NewHost(opts Options) *Host {
	return &Host{opts: opts, changed: make(chan struct{}), watched: map[string]bool{}, timers: map[string]*time.Timer{}}
}

// Start loads the plugins in the background and watches their folders.
func (h *Host) Start() {
	if h == nil {
		return
	}
	go h.Reload()
}

// DevMode reports whether plugins load at all: in Milestone 1 only in
// dev mode (Settings ▸ Plugins, or --plugin-dev).
func (h *Host) DevMode() bool {
	if h == nil {
		return false
	}
	return len(h.opts.FlagDirs) > 0 || h.settings().DevMode
}

func (h *Host) settings() settings.PluginSettings {
	if h.opts.Settings == nil {
		return settings.PluginSettings{}
	}
	if p := h.opts.Settings.Get().Plugins; p != nil {
		return *p
	}
	return settings.PluginSettings{}
}

// Changed is closed at the next change (a load, a reload, a setting).
func (h *Host) Changed() <-chan struct{} {
	if h == nil {
		return nil
	}
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.changed
}

// Generation counts changes.
func (h *Host) Generation() uint64 {
	if h == nil {
		return 0
	}
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.gen
}

// bumpLocked records a change and wakes Changed waiters.
func (h *Host) bumpLocked() {
	h.gen++
	close(h.changed)
	h.changed = make(chan struct{})
}

// Bump records a change made outside the host (a setting such as a
// plugin turned off or consent given), so tables and panels refresh.
func (h *Host) Bump() {
	if h == nil {
		return
	}
	h.mu.Lock()
	h.bumpLocked()
	h.mu.Unlock()
}

type folder struct{ dir, source string }

// folders are the plugin folders to load: a folder with a plugin.yaml is
// one plugin; otherwise each subfolder with one is.
func (h *Host) folders() []folder {
	if !h.DevMode() {
		return nil
	}
	var out []folder
	seen := map[string]bool{}
	add := func(dir, source string) {
		dir = filepath.Clean(dir)
		if abs, err := filepath.Abs(dir); err == nil {
			dir = abs
		}
		if seen[dir] {
			return
		}
		seen[dir] = true
		out = append(out, folder{dir, source})
	}
	expand := func(dir, source string, keepMissing bool) {
		if _, err := os.Stat(filepath.Join(dir, ManifestFile)); err == nil {
			add(dir, source)
			return
		}
		entries, err := os.ReadDir(dir)
		if err != nil {
			if keepMissing {
				add(dir, source) // listed with its error
			}
			return
		}
		n := 0
		for _, e := range entries {
			if e.IsDir() {
				if _, err := os.Stat(filepath.Join(dir, e.Name(), ManifestFile)); err == nil {
					add(filepath.Join(dir, e.Name()), source)
					n++
				}
			}
		}
		if n == 0 && keepMissing {
			add(dir, source)
		}
	}
	if h.opts.InstalledDir != "" {
		expand(h.opts.InstalledDir, SourceInstalled, false)
	}
	for _, d := range h.settings().DevFolders {
		expand(d, SourceDev, true)
	}
	for _, d := range h.opts.FlagDirs {
		expand(d, SourceFlag, true)
	}
	return out
}

// Reload (re)loads every plugin folder, e.g. after dev mode or the dev
// folders changed.
func (h *Host) Reload() {
	if h == nil {
		return
	}
	fs := h.folders()
	loaded := make([]*Plugin, 0, len(fs))
	for _, f := range fs {
		loaded = append(loaded, loadPlugin(f.dir, f.source, f.source != SourceInstalled))
	}
	h.mu.Lock()
	h.plugins = h.mergeLocked(loaded, nil)
	h.bumpLocked()
	h.mu.Unlock()
	h.watch(fs)
}

// reloadDir reloads one plugin folder (a file in it changed).
func (h *Host) reloadDir(dir string) {
	h.mu.RLock()
	var old *Plugin
	for _, p := range h.plugins {
		if p.dir == dir {
			old = p
		}
	}
	h.mu.RUnlock()
	if old == nil {
		return
	}
	np := loadPlugin(dir, old.source, old.source != SourceInstalled)
	h.mu.Lock()
	h.plugins = h.mergeLocked([]*Plugin{np}, old)
	h.bumpLocked()
	h.mu.Unlock()
	if np.failed {
		log.Printf("plugin %s: reload failed (%d problems), the previous version stays loaded", dir, len(np.diags))
	} else {
		log.Printf("plugin %s reloaded", np.ID())
	}
}

// mergeLocked builds the plugin list from loaded (all folders, or one
// replacing old). A failed reload keeps the previous good version
// running, with the new errors to show.
func (h *Host) mergeLocked(loaded []*Plugin, old *Plugin) []*Plugin {
	prev := map[string]*Plugin{}
	for _, p := range h.plugins {
		prev[p.dir] = p
	}
	var list []*Plugin
	if old != nil {
		for _, p := range h.plugins {
			if p != old {
				list = append(list, p)
			}
		}
	}
	for _, np := range loaded {
		if np.failed {
			if pp := prev[np.dir]; pp != nil && pp.m != nil {
				kept := &Plugin{dir: pp.dir, source: pp.source, m: pp.m, d: pp.d, diags: np.diags, failed: true, stats: pp.stats,
					eager: pp.eager, kinds: pp.kinds, kindErrs: pp.kindErrs, loadDur: np.loadDur, compileDur: pp.compileDur, loadedAt: pp.loadedAt, gen: pp.gen}
				np = kept
			}
		} else if pp := prev[np.dir]; pp != nil {
			np.stats = pp.stats
		}
		np.gen = h.gen + 1
		list = append(list, np)
	}
	sort.SliceStable(list, func(i, j int) bool {
		if list[i].ID() != list[j].ID() {
			return list[i].ID() < list[j].ID()
		}
		return list[i].dir < list[j].dir
	})
	// Two folders with one id: the later is refused.
	for i := 1; i < len(list); i++ {
		if id := list[i].ID(); id != "" && id == list[i-1].ID() {
			o := list[i]
			list[i] = &Plugin{dir: o.dir, source: o.source, stats: o.stats, failed: true, gen: o.gen, loadedAt: o.loadedAt,
				diags: []Diag{{Pos: Pos{File: ManifestFile, Line: 1, Col: 1}, Message: fmt.Sprintf("id %q is already used by the plugin in %s", id, list[i-1].dir)}}}
		}
	}
	return list
}

// active are the enabled plugins with a manifest.
func (h *Host) active() []*Plugin {
	if h == nil || !h.DevMode() {
		return nil
	}
	disabled := h.settings().Disabled
	h.mu.RLock()
	defer h.mu.RUnlock()
	out := make([]*Plugin, 0, len(h.plugins))
	for _, p := range h.plugins {
		if p.m != nil && !slices.Contains(disabled, p.m.ID) {
			out = append(out, p)
		}
	}
	return out
}

// Get returns the active plugin id.
func (h *Host) Get(id string) *Plugin {
	for _, p := range h.active() {
		if p.ID() == id {
			return p
		}
	}
	return nil
}

// KindKey is a resource type's kind key: group/Kind.
func KindKey(rt cluster.ResourceType) string { return rt.Group + "/" + rt.Kind }

type entry struct {
	p  *Plugin
	kp *kindProgs
}

// entries are the compiled kind entries of the active plugins for rt.
func (h *Host) entries(rt cluster.ResourceType) []entry {
	key := KindKey(rt)
	var out []entry
	for _, p := range h.active() {
		k := p.m.Kinds[key]
		if k == nil || (k.Version != "" && k.Version != rt.Version) {
			continue
		}
		if kp := p.kind(key); kp != nil {
			out = append(out, entry{p, kp})
		}
	}
	return out
}

// Columns is defaults with the plugins' columns for rt: one with the
// name of a default column replaces it in place, others go before Age;
// hideColumns drop defaults by name (never Name).
func (h *Host) Columns(contextName string, rt cluster.ResourceType, defaults []columns.Column) []columns.Column {
	es := h.entries(rt)
	if len(es) == 0 {
		return defaults
	}
	out := slices.Clone(defaults)
	for _, e := range es {
		for _, name := range e.kp.kind.HideColumns {
			out = slices.DeleteFunc(out, func(c columns.Column) bool { return c.Name == name && c.Name != "Name" && c.Plugin == "" })
		}
		for _, cp := range e.kp.columns {
			c := h.column(e, cp, contextName)
			if i := slices.IndexFunc(out, func(x columns.Column) bool { return x.Name == c.Name }); i >= 0 {
				out[i] = c
				continue
			}
			at := slices.IndexFunc(out, func(x columns.Column) bool { return x.Name == "Age" && x.Type == "age" })
			if at < 0 {
				at = len(out)
			}
			out = slices.Insert(out, at, c)
		}
	}
	return out
}

func (h *Host) column(e entry, cp colProg, contextName string) columns.Column {
	return columns.Column{
		Name: cp.col.Name, Type: orDefault(cp.col.Type, "string"), Description: cp.col.Description,
		Plugin: e.p.ID(), Rev: e.p.gen,
		Program: &ColumnProgram{plugin: e.p, kp: e.kp, prog: cp.prog, context: contextName},
	}
}

// Resolve attaches programs to plugin columns of a saved column set (a
// user's override or a saved view). A column whose plugin isn't loaded
// keeps a nil Program, and its cells show that error.
func (h *Host) Resolve(contextName string, rt cluster.ResourceType, cols []columns.Column) []columns.Column {
	if !slices.ContainsFunc(cols, func(c columns.Column) bool { return c.Plugin != "" }) {
		return cols
	}
	es := h.entries(rt)
	out := slices.Clone(cols)
	for i, c := range out {
		if c.Plugin == "" {
			continue
		}
		for _, e := range es {
			if e.p.ID() != c.Plugin {
				continue
			}
			for _, cp := range e.kp.columns {
				if cp.col.Name == c.Name {
					nc := h.column(e, cp, contextName)
					nc.Type = c.Type
					out[i] = nc
				}
			}
		}
	}
	return out
}

// Panels renders the active plugins' sections for obj, in plugin id order.
// A kind entry that failed to compile shows its errors instead.
func (h *Host) Panels(env Env, rt cluster.ResourceType, obj map[string]any) []PanelOut {
	var out []PanelOut
	for _, p := range h.active() {
		if po, ok := p.panel(env, rt, obj); ok {
			out = append(out, po)
		}
	}
	return out
}

// panel renders p's sections for obj (ok false when p has none for its
// kind). A kind entry that failed to compile shows its errors instead.
func (p *Plugin) panel(env Env, rt cluster.ResourceType, obj map[string]any) (PanelOut, bool) {
	key := KindKey(rt)
	k := p.m.Kinds[key]
	if k == nil || (k.Version != "" && k.Version != rt.Version) {
		return PanelOut{}, false
	}
	kp := p.kind(key)
	if kp == nil {
		p.mu.Lock()
		errs := p.kindErrs[key]
		p.mu.Unlock()
		return PanelOut{Plugin: p.ID(), Name: p.Name(), Sections: []SectionOut{}, Errors: errs}, true
	}
	if len(kp.sections) == 0 {
		return PanelOut{}, false
	}
	return renderPanel(p, kp, obj, env), true
}

// entriesFor are p's compiled kind entries that apply to rt: its kind's
// and "*".
func (p *Plugin) entriesFor(rt cluster.ResourceType) []*kindProgs {
	var out []*kindProgs
	for _, key := range []string{KindKey(rt), "*"} {
		k := p.m.Kinds[key]
		if k == nil || (k.Version != "" && k.Version != rt.Version) {
			continue
		}
		if kp := p.kind(key); kp != nil {
			out = append(out, kp)
		}
	}
	return out
}

// Actions are the actions offered for obj (its kind's and "*"): shell ones
// with their argv expanded by vars, patch ones with their inputs.
func (h *Host) Actions(env Env, rt cluster.ResourceType, obj map[string]any, vars func() ShellVars) []ActionOut {
	var memo ShellVars
	get := func() ShellVars {
		if memo == nil {
			memo = vars()
		}
		return memo
	}
	var out []ActionOut
	consent := h.settings().Consent
	for _, p := range h.active() {
		out = append(out, p.actions(env, rt, obj, get, consent[p.ID()] == p.PermissionsHash())...)
	}
	return out
}

func (p *Plugin) actions(env Env, rt cluster.ResourceType, obj map[string]any, vars func() ShellVars, consented bool) []ActionOut {
	var out []ActionOut
	for _, kp := range p.entriesFor(rt) {
		acts, r, _ := offered(p, kp, obj, env)
		for _, ap := range acts {
			out = append(out, actionOut(p, ap, r, vars, consented))
		}
	}
	return out
}

// ErrNoAction means the action isn't offered for the object.
var ErrNoAction = errors.New("the plugin action isn't available for this object")

// ErrNoConsent means the user hasn't agreed to the plugin's permissions.
var ErrNoConsent = errors.New("the plugin's permissions haven't been agreed to")

// action finds action actionID of plugin pluginID offered for obj
// (`when`), checking consent.
func (h *Host) action(env Env, rt cluster.ResourceType, obj map[string]any, pluginID, actionID string) (*Plugin, actProg, *renderer, error) {
	p := h.Get(pluginID)
	if p == nil {
		return nil, actProg{}, nil, fmt.Errorf("plugin %q isn't loaded", pluginID)
	}
	if h.settings().Consent[p.ID()] != p.PermissionsHash() {
		return nil, actProg{}, nil, ErrNoConsent
	}
	for _, kp := range p.entriesFor(rt) {
		acts, r, _ := offered(p, kp, obj, env)
		for _, ap := range acts {
			if ap.a.ID == actionID {
				return p, ap, r, nil
			}
		}
	}
	return nil, actProg{}, nil, ErrNoAction
}

// ShellAction finds shell action actionID of plugin pluginID for obj,
// checking that it is offered (`when`) and consented to.
func (h *Host) ShellAction(env Env, rt cluster.ResourceType, obj map[string]any, pluginID, actionID string) (*Action, error) {
	_, ap, _, err := h.action(env, rt, obj, pluginID, actionID)
	if err != nil {
		return nil, err
	}
	if ap.a.Shell == nil {
		return nil, ErrNoAction
	}
	return ap.a, nil
}

// PatchAction builds patch action actionID of plugin pluginID for obj
// from the user's inputs: it checks that the action is offered and
// consented to, that the plugin may patch the kind (never Secrets), and
// the inputs (an *InputError names a bad one).
func (h *Host) PatchAction(env Env, rt cluster.ResourceType, obj map[string]any, pluginID, actionID string, inputs map[string]any) (*PatchOut, error) {
	p, ap, r, err := h.action(env, rt, obj, pluginID, actionID)
	if err != nil {
		return nil, err
	}
	key := KindKey(rt)
	if ap.a.Patch == nil || key == secretKind || !slices.Contains(p.m.Permissions.Patch, key) {
		return nil, ErrNoAction
	}
	start := time.Now()
	out, err := patchBody(ap, r, inputs)
	p.stats.record(statAction, time.Since(start), err)
	return out, err
}

// PatchTargets are the patch actions of the active plugins, as action
// names (plugin.<id>.<action>) and the kind keys they apply to.
func (h *Host) PatchTargets() map[string][]string {
	out := map[string][]string{}
	for _, p := range h.active() {
		for _, key := range p.m.KindOrder {
			for _, a := range p.m.Kinds[key].Actions {
				if a.Patch != nil && key != secretKind && slices.Contains(p.m.Permissions.Patch, key) {
					out[ActionName(p.ID(), a.ID)] = append(out[ActionName(p.ID(), a.ID)], key)
				}
			}
		}
	}
	return out
}

// ActionName is a plugin action's name on POST /api/actions/{action}.
func ActionName(pluginID, actionID string) string { return "plugin." + pluginID + "." + actionID }

// SplitActionName is ActionName's inverse (ok false for other names).
func SplitActionName(name string) (pluginID, actionID string, ok bool) {
	rest, found := strings.CutPrefix(name, "plugin.")
	if !found {
		return "", "", false
	}
	pluginID, actionID, ok = strings.Cut(rest, ".")
	return pluginID, actionID, ok && pluginID != "" && actionID != ""
}

// Icon returns plugin id's icon.png (at most 64 KB).
func (h *Host) Icon(id string) ([]byte, error) {
	p := h.Get(id)
	if p == nil {
		return nil, os.ErrNotExist
	}
	f, err := os.Open(filepath.Join(p.dir, "icon.png"))
	if err != nil {
		return nil, err
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, maxIcon+1))
	if err != nil {
		return nil, err
	}
	if len(b) > maxIcon {
		return nil, fmt.Errorf("icon.png is larger than 64 KB")
	}
	return b, nil
}

// ---- listing ---------------------------------------------------------------

// Info describes a plugin for GET /api/plugins.
type Info struct {
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	Version     string   `json:"version,omitempty"`
	Description string   `json:"description,omitempty"`
	Authors     []string `json:"authors,omitempty"`
	Homepage    string   `json:"homepage,omitempty"`
	Dir         string   `json:"dir"`
	Source      string   `json:"source"`
	// Status: "ok", "warning" (loaded, with warnings), "error" (the last
	// load failed; Loaded says whether a previous version still runs).
	Status          string              `json:"status"`
	Loaded          bool                `json:"loaded"`
	Disabled        bool                `json:"disabled,omitempty"`
	Diags           []Diag              `json:"diags"`
	Permissions     Permissions         `json:"permissions"`
	PermissionsHash string              `json:"permissionsHash,omitempty"`
	Consented       bool                `json:"consented"`
	Kinds           []KindInfo          `json:"kinds"`
	Nav             *Nav                `json:"nav,omitempty"`
	KindIcons       map[string]string   `json:"kindIcons,omitempty"`
	HasIcon         bool                `json:"hasIcon,omitempty"`
	LoadMillis      float64             `json:"loadMs"`
	CompileMillis   float64             `json:"compileMs"`
	LoadedAt        time.Time           `json:"loadedAt"`
	Stats           map[string]StatsOut `json:"stats"`
}

// KindInfo is one kind entry of a plugin.
type KindInfo struct {
	Key string `json:"key"`
	// Served: the current cluster serves the kind (the entry is active).
	Served   bool `json:"served"`
	Compiled bool `json:"compiled"`
	Columns  int  `json:"columns"`
	Sections int  `json:"sections"`
	Actions  int  `json:"actions"`
	Alerts   int  `json:"alerts"`
	Related  int  `json:"related"`
	Metrics  int  `json:"metrics"`
	Errors   int  `json:"errors"`
}

// List describes every plugin folder. served tells whether the current
// cluster serves a kind key (nil = unknown).
func (h *Host) List(served func(key string) bool) []Info {
	if h == nil || !h.DevMode() {
		return []Info{}
	}
	disabled := h.settings().Disabled
	consent := h.settings().Consent
	h.mu.RLock()
	plugins := slices.Clone(h.plugins)
	h.mu.RUnlock()
	out := make([]Info, 0, len(plugins))
	for _, p := range plugins {
		in := Info{ID: p.ID(), Name: p.Name(), Dir: p.dir, Source: p.source, Loaded: p.m != nil, Diags: p.diags, Kinds: []KindInfo{},
			LoadMillis: ms(p.loadDur), LoadedAt: p.loadedAt, Stats: p.stats.snapshot()}
		if in.Diags == nil {
			in.Diags = []Diag{}
		}
		switch {
		case p.failed:
			in.Status = "error"
		case len(p.diags) > 0:
			in.Status = "warning"
		default:
			in.Status = "ok"
		}
		if m := p.m; m != nil {
			in.Version, in.Description, in.Authors, in.Homepage = m.Version, m.Description, m.Authors, m.Homepage
			in.Permissions, in.PermissionsHash = m.Permissions, p.PermissionsHash()
			in.Consented = consent[m.ID] == in.PermissionsHash
			in.Disabled = slices.Contains(disabled, m.ID)
			in.Nav = m.Nav
			_, err := os.Stat(filepath.Join(p.dir, "icon.png"))
			in.HasIcon = err == nil
			p.mu.Lock()
			for _, key := range m.KindOrder {
				k := m.Kinds[key]
				ki := KindInfo{Key: key, Served: key == "*" || (served != nil && served(key)), Columns: len(k.Columns), Actions: len(k.Actions),
					Alerts: len(k.Alerts), Related: len(k.Related), Metrics: len(k.Metrics)}
				if k.Panel != nil {
					ki.Sections = len(k.Panel.Sections)
				}
				_, ki.Compiled = p.kinds[key]
				ki.Errors = len(p.kindErrs[key])
				in.Kinds = append(in.Kinds, ki)
				if k.Icon != "" {
					if in.KindIcons == nil {
						in.KindIcons = map[string]string{}
					}
					in.KindIcons[key] = k.Icon
				}
			}
			in.CompileMillis = ms(p.compileDur)
			p.mu.Unlock()
		}
		out = append(out, in)
	}
	return out
}

func ms(d time.Duration) float64 { return float64(d.Microseconds()) / 1000 }

// ---- hot reload ------------------------------------------------------------

// debounce is how long a folder must be quiet before it is reloaded.
const debounce = 150 * time.Millisecond

// watch makes the watcher follow fs (plugin folders) and the installed
// folder (for plugins added or removed there).
func (h *Host) watch(fs []folder) {
	h.wmu.Lock()
	defer h.wmu.Unlock()
	want := map[string]bool{}
	for _, f := range fs {
		want[f.dir] = true
	}
	if h.DevMode() {
		for _, d := range append(slices.Clone(h.settings().DevFolders), h.opts.FlagDirs...) {
			if abs, err := filepath.Abs(d); err == nil {
				want[abs] = true // a folder of plugins: see new ones
			}
		}
		if h.opts.InstalledDir != "" {
			want[h.opts.InstalledDir] = true
		}
	}
	if h.watcher == nil {
		if len(want) == 0 {
			return
		}
		w, err := fsnotify.NewWatcher()
		if err != nil {
			log.Printf("plugins: can't watch folders: %v", err)
			return
		}
		h.watcher = w
		go h.watchLoop(w)
	}
	for d := range h.watched {
		if !want[d] {
			_ = h.watcher.Remove(d)
			delete(h.watched, d)
		}
	}
	for d := range want {
		if !h.watched[d] {
			if err := h.watcher.Add(d); err == nil {
				h.watched[d] = true
			}
		}
	}
}

func (h *Host) watchLoop(w *fsnotify.Watcher) {
	for {
		select {
		case ev, ok := <-w.Events:
			if !ok {
				return
			}
			h.onEvent(ev)
		case err, ok := <-w.Errors:
			if !ok {
				return
			}
			log.Printf("plugins: watch: %v", err)
		}
	}
}

func (h *Host) onEvent(ev fsnotify.Event) {
	if ev.Op == fsnotify.Chmod {
		return
	}
	dir := filepath.Dir(ev.Name)
	h.mu.RLock()
	isPlugin := false
	for _, p := range h.plugins {
		if p.dir == dir {
			isPlugin = true
		}
	}
	h.mu.RUnlock()
	key, run := dir, func() { h.reloadDir(dir) }
	if !isPlugin {
		// Something changed in a folder of plugins: look again.
		key, run = "", h.Reload
	}
	h.wmu.Lock()
	defer h.wmu.Unlock()
	if t := h.timers[key]; t != nil {
		t.Stop()
	}
	h.timers[key] = time.AfterFunc(debounce, run)
}

// Opts returns the host's options.
func (h *Host) Opts() Options {
	if h == nil {
		return Options{}
	}
	return h.opts
}

// Close stops watching.
func (h *Host) Close() {
	if h == nil {
		return
	}
	h.wmu.Lock()
	defer h.wmu.Unlock()
	if h.watcher != nil {
		_ = h.watcher.Close()
		h.watcher = nil
	}
}
