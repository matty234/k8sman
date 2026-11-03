package icons

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/kubernetes/fake"
	metafake "k8s.io/client-go/metadata/fake"
)

func TestCandidateDomains(t *testing.T) {
	cases := map[string][]string{
		"argoproj.io":                {"argoproj.io"},
		"cert-manager.io":            {"cert-manager.io"},
		"acme.cert-manager.io":       {"acme.cert-manager.io", "cert-manager.io"},
		"monitoring.coreos.com":      {"monitoring.coreos.com", "coreos.com"},
		"example.k8sman.dev":         {"example.k8sman.dev", "k8sman.dev"},
		"a.b.c.d.example-corp.co.uk": {"a.b.c.d.example-corp.co.uk", "b.c.d.example-corp.co.uk", "example-corp.co.uk"},
		// github.io is a public suffix: stop at the owner's site.
		"aquasecurity.github.io":     {"aquasecurity.github.io"},
		"foo.aquasecurity.github.io": {"foo.aquasecurity.github.io", "aquasecurity.github.io"},
		"github.io":                  nil,
		"com":                        nil,
		"":                           nil,
		"mycompany.internal":         nil,
		"apps.svc.cluster.local":     nil,
		"stable.example.com":         nil,
		"widgets.test":               nil,
		"10.0.0.1":                   nil,
		"foo.unknowntld":             nil,
		"bad_label.io":               nil,
		"UPPER.Example.DEV.":         {"upper.example.dev", "example.dev"},
	}
	for in, want := range cases {
		if got := CandidateDomains(in); !reflect.DeepEqual(got, want) {
			t.Errorf("CandidateDomains(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestIsLocalCluster(t *testing.T) {
	cases := []struct {
		ctx, host string
		want      bool
	}{
		{"kind-k8sman-dev", "https://10.1.2.3:6443", true},
		{"k3d-dev", "", true},
		{"minikube", "https://192.168.49.2:8443", true},
		{"docker-desktop", "https://kubernetes.docker.internal:6443", true},
		{"prod", "https://127.0.0.1:52011", true},
		{"prod", "https://[::1]:6443", true},
		{"prod", "https://localhost:6443", true},
		{"prod-eks", "https://ABC.gr7.us-east-1.eks.amazonaws.com", false},
		{"gke_proj_zone_name", "https://34.1.2.3", false},
	}
	for _, c := range cases {
		if got := IsLocalCluster(c.ctx, c.host); got != c.want {
			t.Errorf("IsLocalCluster(%q, %q) = %v, want %v", c.ctx, c.host, got, c.want)
		}
	}
}

func TestCuratedAsset(t *testing.T) {
	cases := map[string]string{
		"argoproj.io":                    "argo",
		"acme.cert-manager.io":           "cert-manager",
		"gateway.networking.k8s.io":      "kubernetes",
		"snapshot.storage.k8s.io":        "kubernetes",
		"cluster.x-k8s.io":               "kubernetes",
		"source.toolkit.fluxcd.io":       "flux",
		"aquasecurity.github.io":         "trivy",
		"notargoproj.io":                 "",
		"monitoring.coreos.com":          "prometheus",
		"example.k8sman.dev":             "",
		"templates.gatekeeper.sh":        "opa",
		"networking.istio.io":            "istio",
		"postgresql.cnpg.io":             "cloudnativepg",
		"gateway.envoyproxy.io":          "envoy",
		"eventing.keda.sh":               "keda",
		"serving.knative.dev":            "knative",
		"kafka.strimzi.io":               "strimzi",
		"external-secrets.io":            "external-secrets",
		"generators.external-secrets.io": "external-secrets",
	}
	for in, want := range cases {
		if got := CuratedAsset(in); got != want {
			t.Errorf("CuratedAsset(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestParseIconLinks(t *testing.T) {
	page, _ := url.Parse("https://www.example.dev/docs/index.html")
	doc := `<!doctype html><html><head>
	<meta charset="utf-8">
	<link rel="stylesheet" href="/site.css">
	<link rel="icon" href="favicon-16.png" sizes="16x16" type="image/png">
	<LINK REL="Shortcut Icon" HREF="/favicon.ico">
	<link rel="icon" type="image/svg+xml" href="/logo.svg">
	<link rel="mask-icon" href="/pinned.svg" color="#000">
	<link rel="apple-touch-icon" href="https://cdn.example.dev/touch.png">
	<link rel="icon" href="/icons/icon-192.png" sizes="192x192 32x32">
	<link rel="icon" href="data:image/png;base64,AAAA">
	</head><body><link rel="icon" href="/ignored-in-body.png" sizes="512x512"></body></html>`
	got := ParseIconLinks(page, []byte(doc))
	want := []IconLink{
		{URL: "https://www.example.dev/icons/icon-192.png", Rel: "icon", Size: 192},
		{URL: "https://cdn.example.dev/touch.png", Rel: "apple-touch-icon", Size: 180},
		{URL: "https://www.example.dev/favicon.ico", Rel: "icon", Size: 32},
		{URL: "https://www.example.dev/docs/favicon-16.png", Rel: "icon", Size: 16},
		{URL: "https://www.example.dev/logo.svg", Rel: "icon", Size: 24, SVG: true},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("ParseIconLinks:\n got %+v\nwant %+v", got, want)
	}

	// <base href> changes resolution.
	got = ParseIconLinks(page, []byte(`<head><base href="https://static.example.dev/v2/"><link rel=icon href="fav.png"></head>`))
	if len(got) != 1 || got[0].URL != "https://static.example.dev/v2/fav.png" {
		t.Errorf("base href: %+v", got)
	}
	if got := ParseIconLinks(page, []byte("not html at all")); len(got) != 0 {
		t.Errorf("garbage: %+v", got)
	}

	// Static redirect pages.
	_, refresh := parsePage(page, []byte(`<html><head><meta http-equiv="Refresh" content="0; url=https://argoproj.github.io" /></head></html>`))
	if refresh == nil || refresh.String() != "https://argoproj.github.io" {
		t.Errorf("meta refresh: %v", refresh)
	}
	_, refresh = parsePage(page, []byte(`<meta http-equiv="refresh" content="5">`))
	if refresh != nil {
		t.Errorf("refresh without url: %v", refresh)
	}
}

func TestOnSharedPlatform(t *testing.T) {
	gh, _ := url.Parse("https://github.com/aquasecurity")
	pages, _ := url.Parse("https://argoproj.github.io/")
	if !onSharedPlatform("aquasecurity.github.io", gh) {
		t.Error("github.com should count as a shared platform for aquasecurity.github.io")
	}
	if onSharedPlatform("argoproj.io", pages) {
		t.Error("an org's github.io site is its own")
	}
	if onSharedPlatform("github.com", gh) {
		t.Error("github.com is its own site")
	}
}

// ---- Helm ------------------------------------------------------------------

type testRelease struct {
	name, namespace, icon string
	files                 map[string]string
}

func encodeRelease(t *testing.T, r testRelease, gz bool) []byte {
	t.Helper()
	type file struct {
		Name string `json:"name"`
		Data []byte `json:"data"`
	}
	var files []file
	for n, d := range r.files {
		files = append(files, file{n, []byte(d)})
	}
	doc := map[string]any{
		"name": r.name, "namespace": r.namespace, "version": 1,
		"info":  map[string]any{"status": "deployed"},
		"chart": map[string]any{"metadata": map[string]any{"name": r.name + "-chart", "icon": r.icon, "version": "1.0.0"}, "files": files, "templates": []any{}},
	}
	raw, err := json.Marshal(doc)
	if err != nil {
		t.Fatal(err)
	}
	if gz {
		var buf bytes.Buffer
		zw := gzip.NewWriter(&buf)
		_, _ = zw.Write(raw)
		_ = zw.Close()
		raw = buf.Bytes()
	}
	// What client-go hands back in Secret.Data["release"]: Helm's own base64.
	return []byte(base64.StdEncoding.EncodeToString(raw))
}

func releaseSecret(t *testing.T, r testRelease) *corev1.Secret {
	return &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name: "sh.helm.release.v1." + r.name + ".v1", Namespace: r.namespace,
			Labels: map[string]string{"owner": "helm", "status": "deployed", "name": r.name, "version": "1"},
		},
		Type: "helm.sh/release.v1",
		Data: map[string][]byte{"release": encodeRelease(t, r, true)},
	}
}

const crdYAML = `apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: things.%[1]s
spec:
  group: %[1]s
  names:
    kind: Thing
`

func TestDecodeRelease(t *testing.T) {
	in := testRelease{name: "trivy-operator", namespace: "trivy-system", icon: "https://example.dev/icon.png",
		files: map[string]string{
			"crds/a.yaml":    fmt.Sprintf(crdYAML, "aquasecurity.github.io"),
			"crds/b.yaml":    "# comment\n" + fmt.Sprintf(crdYAML, "aquasecurity.github.io"),
			"crds/gw.yaml":   fmt.Sprintf(crdYAML, "gateway.networking.k8s.io"),
			"README.md":      "group: not.a.crd.io",
			"crds/notes.txt": "group: no-crd-kind.io",
		}}
	for _, gz := range []bool{true, false} {
		r, err := DecodeRelease(encodeRelease(t, in, gz))
		if err != nil {
			t.Fatalf("gz=%v: %v", gz, err)
		}
		if r.Name != "trivy-operator" || r.Namespace != "trivy-system" || r.Chart.Metadata.Icon != in.icon {
			t.Errorf("gz=%v: decoded %+v", gz, r)
		}
		groups := r.CRDGroups()
		if len(groups) != 2 || !contains(groups, "aquasecurity.github.io") || !contains(groups, "gateway.networking.k8s.io") {
			t.Errorf("gz=%v: CRDGroups = %v", gz, groups)
		}
	}
	if _, err := DecodeRelease([]byte("!!not base64")); err == nil {
		t.Error("want error for bad base64")
	}
	if _, err := DecodeRelease([]byte(base64.StdEncoding.EncodeToString([]byte{0x1f, 0x8b, 1, 2}))); err == nil {
		t.Error("want error for bad gzip")
	}
}

func contains(s []string, x string) bool {
	for _, y := range s {
		if y == x {
			return true
		}
	}
	return false
}

func crdMeta(name string, labels, ann map[string]string) *metav1.PartialObjectMetadata {
	return &metav1.PartialObjectMetadata{
		TypeMeta:   metav1.TypeMeta{APIVersion: "apiextensions.k8s.io/v1", Kind: "CustomResourceDefinition"},
		ObjectMeta: metav1.ObjectMeta{Name: name, Labels: labels, Annotations: ann},
	}
}

func helmFixture(t *testing.T, kedaIcon string) (*fake.Clientset, *metafake.FakeMetadataClient) {
	typed := fake.NewClientset(
		releaseSecret(t, testRelease{name: "keda", namespace: "keda", icon: kedaIcon}),
		releaseSecret(t, testRelease{name: "eg", namespace: "envoy-gateway-system", icon: "https://example.dev/envoy.svg",
			files: map[string]string{
				"crds/generated/gateway.envoyproxy.io_backends.yaml": fmt.Sprintf(crdYAML, "gateway.envoyproxy.io"),
				"crds/gatewayapi-crds.yaml":                          fmt.Sprintf(crdYAML, "gateway.networking.k8s.io"),
			}}),
		releaseSecret(t, testRelease{name: "kube-prometheus-stack", namespace: "monitoring", icon: "https://example.dev/prom.png"}),
		releaseSecret(t, testRelease{name: "noicon", namespace: "x", icon: ""}),
		// A superseded release must be ignored by the label selector.
		&corev1.Secret{ObjectMeta: metav1.ObjectMeta{Name: "old", Namespace: "keda", Labels: map[string]string{"owner": "helm", "status": "superseded"}}},
		&rbacv1.ClusterRole{
			ObjectMeta: metav1.ObjectMeta{Name: "kps-operator", Annotations: map[string]string{annRelease: "kube-prometheus-stack", annReleaseNS: "monitoring"}},
			Rules: []rbacv1.PolicyRule{
				{APIGroups: []string{"monitoring.coreos.com"}, Resources: []string{"prometheuses", "alertmanagers"}, Verbs: []string{"*"}},
				{APIGroups: []string{"gateway.networking.k8s.io"}, Resources: []string{"httproutes"}, Verbs: []string{"update"}},
				{APIGroups: []string{"readonly.example.io"}, Resources: []string{"things"}, Verbs: []string{"get", "list"}},
			},
		},
	)
	scheme := runtime.NewScheme()
	metav1.AddMetaToScheme(scheme)
	meta := metafake.NewSimpleMetadataClient(scheme,
		crdMeta("scaledobjects.keda.sh", map[string]string{"app.kubernetes.io/managed-by": "Helm"},
			map[string]string{annRelease: "keda", annReleaseNS: "keda"}),
		crdMeta("applications.argoproj.io", map[string]string{"app.kubernetes.io/part-of": "argocd"}, nil),
	)
	return typed, meta
}

func TestBuildHelmIndex(t *testing.T) {
	typed, meta := helmFixture(t, "https://example.dev/keda.png")
	idx := buildHelmIndex(context.Background(), typed, meta)
	cases := []struct{ group, icon, release, via string }{
		{"keda.sh", "https://example.dev/keda.png", "keda/keda", "crd-annotations"},
		{"gateway.envoyproxy.io", "https://example.dev/envoy.svg", "envoy-gateway-system/eg", "chart-crds"},
		{"monitoring.coreos.com", "https://example.dev/prom.png", "monitoring/kube-prometheus-stack", "controller-clusterrole"},
		// Vendored/consumed Kubernetes groups are never attributed to a chart.
		{"gateway.networking.k8s.io", "", "", ""},
		{"readonly.example.io", "", "", ""},
		{"argoproj.io", "", "", ""},
	}
	for _, c := range cases {
		icon, rel := idx.iconFor(c.group)
		if icon != c.icon || rel != c.release || idx.via[c.group] != c.via {
			t.Errorf("%s: got (%q, %q, %q), want (%q, %q, %q)", c.group, icon, rel, idx.via[c.group], c.icon, c.release, c.via)
		}
	}
}

// ---- cache -----------------------------------------------------------------

func TestCache(t *testing.T) {
	dir := t.TempDir()
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	c := NewCache(dir)
	c.now = func() time.Time { return now }
	c.PositiveTTL, c.NegativeTTL = time.Hour, time.Minute

	if _, ok := c.Get("a", false); ok {
		t.Fatal("empty cache hit")
	}
	c.Put("a", Entry{OK: true, URL: "https://x/a.png", ContentType: "image/png", Data: []byte("png")})
	c.Put("miss", Entry{Error: "nope"})

	// A fresh instance reads the same entries from disk.
	c2 := NewCache(dir)
	c2.now = c.now
	c2.PositiveTTL, c2.NegativeTTL = c.PositiveTTL, c.NegativeTTL
	e, ok := c2.Get("a", false)
	if !ok || string(e.Data) != "png" || e.ContentType != "image/png" || e.URL != "https://x/a.png" {
		t.Fatalf("disk round trip: %+v %v", e, ok)
	}
	if e, ok := c2.Get("miss", false); !ok || e.OK || e.Error != "nope" {
		t.Fatalf("negative entry: %+v %v", e, ok)
	}

	// Negative entries expire first.
	now = now.Add(2 * time.Minute)
	if _, ok := c2.Get("miss", false); ok {
		t.Error("negative entry should have expired")
	}
	if _, ok := c2.Get("a", false); !ok {
		t.Error("positive entry expired too early")
	}
	// Expired positives are only served stale.
	now = now.Add(2 * time.Hour)
	if _, ok := c2.Get("a", false); ok {
		t.Error("positive entry should have expired")
	}
	if e, ok := c2.Get("a", true); !ok || string(e.Data) != "png" {
		t.Error("stale positive should be served when allowStale")
	}
	if _, ok := c2.Get("miss", true); ok {
		t.Error("stale negatives are never served")
	}
	// Overwriting a hit with a miss removes the image.
	c2.Put("a", Entry{Error: "gone"})
	c3 := NewCache(dir)
	c3.now = c.now
	if e, ok := c3.Get("a", false); !ok || e.OK {
		t.Errorf("overwrite: %+v %v", e, ok)
	}
}

// ---- images ----------------------------------------------------------------

func testPNG(w, h int) []byte {
	img := image.NewNRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.SetNRGBA(x, y, color.NRGBA{R: 200, G: 30, B: 30, A: 255})
		}
	}
	var buf bytes.Buffer
	_ = png.Encode(&buf, img)
	return buf.Bytes()
}

// testICO builds an .ico with the given entries (raw payloads).
func testICO(entries ...[]byte) []byte {
	var buf bytes.Buffer
	_ = binary.Write(&buf, binary.LittleEndian, []uint16{0, 1, uint16(len(entries))})
	off := 6 + 16*len(entries)
	for i, e := range entries {
		size := byte(16 << i)
		_ = binary.Write(&buf, binary.LittleEndian, []byte{size, size, 0, 0})
		_ = binary.Write(&buf, binary.LittleEndian, []uint16{1, 32})
		_ = binary.Write(&buf, binary.LittleEndian, []uint32{uint32(len(e)), uint32(off)})
		off += len(e)
	}
	for _, e := range entries {
		buf.Write(e)
	}
	return buf.Bytes()
}

// testDIB32 is a w×w 32bpp ICO bitmap entry, solid blue, plus its AND mask.
func testDIB32(w int) []byte {
	var buf bytes.Buffer
	_ = binary.Write(&buf, binary.LittleEndian, []uint32{40, uint32(w), uint32(2 * w)})
	_ = binary.Write(&buf, binary.LittleEndian, []uint16{1, 32})
	_ = binary.Write(&buf, binary.LittleEndian, []uint32{0, 0, 0, 0, 0, 0})
	for i := 0; i < w*w; i++ {
		buf.Write([]byte{255, 0, 0, 255}) // BGRA
	}
	buf.Write(make([]byte, (w+31)/32*4*w))
	return buf.Bytes()
}

func decodeSize(t *testing.T, b []byte) (int, int, color.Color) {
	t.Helper()
	img, err := png.Decode(bytes.NewReader(b))
	if err != nil {
		t.Fatal(err)
	}
	return img.Bounds().Dx(), img.Bounds().Dy(), img.At(img.Bounds().Dx()/2, img.Bounds().Dy()/2)
}

func TestNormalize(t *testing.T) {
	// Large PNGs are downscaled, keeping aspect.
	out, ct, err := Normalize(testPNG(500, 250))
	if err != nil || ct != "image/png" {
		t.Fatal(err, ct)
	}
	if w, h, c := decodeSize(t, out); w != 128 || h != 64 {
		t.Errorf("downscaled to %dx%d", w, h)
	} else if r, _, _, _ := c.RGBA(); r>>8 != 200 {
		t.Errorf("colour changed: %v", c)
	}
	// Small PNGs pass through.
	small := testPNG(64, 64)
	if out, _, _ := Normalize(small); !bytes.Equal(out, small) {
		t.Error("small png should pass through")
	}
	// ICO: the largest entry wins, PNG or BMP.
	out, _, err = Normalize(testICO(testDIB32(16), testPNG(32, 32)))
	if err != nil {
		t.Fatal(err)
	}
	if w, _, _ := decodeSize(t, out); w != 32 {
		t.Errorf("ico png entry: width %d", w)
	}
	out, _, err = Normalize(testICO(testDIB32(32)))
	if err != nil {
		t.Fatal(err)
	}
	if w, h, c := decodeSize(t, out); w != 32 || h != 32 {
		t.Errorf("ico bmp entry: %dx%d", w, h)
	} else if r, g, b, a := c.RGBA(); r != 0 || g != 0 || b>>8 != 255 || a>>8 != 255 {
		t.Errorf("ico bmp colour: %v", c)
	}
	// SVG and junk are rejected.
	if _, _, err := Normalize([]byte(`<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"></svg>`)); err != errSVG {
		t.Errorf("svg: %v", err)
	}
	if _, _, err := Normalize([]byte("<html>nope</html>")); err == nil {
		t.Error("html accepted as image")
	}
	if _, _, err := Normalize(testPNG(8, 8)); err != errTooSmall {
		t.Errorf("tiny: %v", err)
	}
}

// ---- fetching and resolution ----------------------------------------------

// testSite serves a home page with icon links, over TLS on 127.0.0.1.
func testSite(t *testing.T, hits *atomic.Int32) (*httptest.Server, *Fetcher) {
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprint(w, `<html><head>
			<link rel="icon" href="/logo.svg" type="image/svg+xml">
			<link rel="icon" href="/broken.png" sizes="256x256">
			<link rel="apple-touch-icon" href="/touch.png">
			<link rel="icon" href="/huge.png" sizes="64x64">
		</head></html>`)
	})
	mux.HandleFunc("/broken.png", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		fmt.Fprint(w, "<html>soft 404</html>")
	})
	mux.HandleFunc("/touch.png", func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		w.Header().Set("Content-Type", "image/png")
		_, _ = w.Write(testPNG(180, 180))
	})
	mux.HandleFunc("/huge.png", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "image/png")
		_, _ = w.Write(make([]byte, MaxBytes+10))
	})
	mux.HandleFunc("/chart.png", func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		w.Header().Set("Content-Type", "image/png")
		_, _ = w.Write(testPNG(40, 40))
	})
	mux.HandleFunc("/to-http", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "http://"+r.Host+"/chart.png", http.StatusFound)
	})
	ts := httptest.NewTLSServer(mux)
	t.Cleanup(ts.Close)
	c := ts.Client()
	c.CheckRedirect = checkRedirect
	c.Timeout = 5 * time.Second
	return ts, &Fetcher{Client: c}
}

func TestFetchFavicon(t *testing.T) {
	var hits atomic.Int32
	ts, f := testSite(t, &hits)
	host := strings.TrimPrefix(ts.URL, "https://")
	data, ct, u, err := f.FetchFavicon(context.Background(), host)
	if err != nil {
		t.Fatal(err)
	}
	if u != ts.URL+"/touch.png" || ct != "image/png" {
		t.Errorf("picked %s (%s)", u, ct)
	}
	if w, _, _ := decodeSize(t, data); w != 128 {
		t.Errorf("touch icon not downscaled: %d", w)
	}
	// https only, including redirects.
	if _, _, err := f.FetchImage(context.Background(), "http://"+host+"/chart.png"); err == nil {
		t.Error("http URL fetched")
	}
	if _, _, err := f.FetchImage(context.Background(), ts.URL+"/to-http"); err == nil {
		t.Error("followed a redirect to http")
	}
}

func TestPublicIP(t *testing.T) {
	for _, s := range []string{"127.0.0.1", "10.1.2.3", "192.168.0.1", "172.16.0.1", "169.254.169.254", "::1", "fd00::1", "100.64.1.1", "0.0.0.0"} {
		if publicIP(net.ParseIP(s)) {
			t.Errorf("%s treated as public", s)
		}
	}
	for _, s := range []string{"1.1.1.1", "140.82.112.3", "2606:4700::1111"} {
		if !publicIP(net.ParseIP(s)) {
			t.Errorf("%s treated as private", s)
		}
	}
	// The real fetcher refuses to dial private addresses.
	if _, _, _, err := NewFetcher().Get(context.Background(), "https://127.0.0.1:1/", "text/html", false); err == nil || !strings.Contains(err.Error(), "non-public") {
		t.Errorf("dialled loopback: %v", err)
	}
}

func TestResolverOrder(t *testing.T) {
	var hits atomic.Int32
	ts, f := testSite(t, &hits)
	typed, meta := helmFixture(t, ts.URL+"/chart.png")
	remote := true
	r := NewResolver(t.TempDir(), func() bool { return remote })
	r.Fetcher = f
	cl := Cluster{Key: "test", Typed: typed, Metadata: meta}
	ctx := context.Background()

	// 1. Helm chart icon.
	res := r.Resolve(ctx, cl, "keda.sh")
	if res.Source != SourceHelm || res.Release != "keda/keda" || len(res.Data) == 0 {
		t.Errorf("keda.sh: %+v", res)
	}
	// Helm icon that's an SVG (unrenderable) falls through to the bundled icon.
	if res := r.Resolve(ctx, cl, "gateway.envoyproxy.io"); res.Source != SourceBundled || res.Asset != "envoy" {
		t.Errorf("gateway.envoyproxy.io: %+v", res)
	}
	// 2. Bundled.
	if res := r.Resolve(ctx, cl, "argoproj.io"); res.Source != SourceBundled || res.Asset != "argo" {
		t.Errorf("argoproj.io: %+v", res)
	}
	if res := r.Resolve(ctx, cl, "gateway.networking.k8s.io"); res.Source != SourceBundled || res.Asset != "kubernetes" {
		t.Errorf("gateway.networking.k8s.io: %+v", res)
	}
	// 4. Nothing (reserved domain, no fetch).
	before := hits.Load()
	if res := r.Resolve(ctx, cl, "widgets.example.com"); res.Source != SourceNone {
		t.Errorf("widgets.example.com: %+v", res)
	}
	if hits.Load() != before {
		t.Error("fetched for a reserved domain")
	}

	// The cache answers repeat lookups without refetching, and still
	// serves them with remote fetching disabled.
	remote = false
	r2 := NewResolver(r.Cache.dir, func() bool { return remote })
	r2.Fetcher = f
	before = hits.Load()
	if res := r2.Resolve(ctx, cl, "keda.sh"); res.Source != SourceHelm {
		t.Errorf("cached keda.sh with remote off: %+v", res)
	}
	if hits.Load() != before {
		t.Error("refetched a cached icon")
	}
	// Remote off: an uncached chart icon is not fetched.
	r3 := NewResolver(t.TempDir(), func() bool { return false })
	r3.Fetcher = f
	if res := r3.Resolve(ctx, cl, "keda.sh"); res.Source != SourceBundled {
		t.Errorf("remote off: %+v", res)
	}
	if hits.Load() != before {
		t.Error("fetched with remote icons disabled")
	}
}
