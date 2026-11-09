package helm

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"helm.sh/helm/v3/pkg/registry"
)

func TestOCIVersions(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v2/charts/app/tags/list" {
			w.Write([]byte(`{"name":"charts/app","tags":["1.2.0","latest","1.10.0","1.10.0-rc.1","0.9.0"]}`))
			return
		}
		w.WriteHeader(http.StatusUnauthorized)
		w.Write([]byte(`{"errors":[{"code":"UNAUTHORIZED","message":"authentication required"}]}`))
	}))
	defer srv.Close()
	rc, err := registry.NewClient(registry.ClientOptPlainHTTP())
	if err != nil {
		t.Fatal(err)
	}
	host := strings.TrimPrefix(srv.URL, "http://")
	res, err := listOCIVersions(rc, "oci://"+host+"/charts/app")
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(res.Versions, " "); got != "1.10.0 1.10.0-rc.1 1.2.0 0.9.0" || res.Latest != "1.10.0" {
		t.Fatalf("versions %q latest %q", got, res.Latest)
	}
	_, err = listOCIVersions(rc, "oci://"+host+"/private/app")
	if err == nil || !strings.Contains(err.Error(), "helm registry login "+host) {
		t.Fatalf("want login hint, got %v", err)
	}
}
