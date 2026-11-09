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
