package server

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
)

// An export's links: volumes with their formats in the UI's order (gzip
// first, dir left out), the default format's URL with the CA, service and
// token Secret; the download sends the token only as the export header and
// lands in the file via .part, and a refused download leaves no file.
func TestVMExportLinkAndDownload(t *testing.T) {
	obj := map[string]any{
		"metadata": map[string]any{"name": "vm1-export-abc"},
		"status": map[string]any{
			"phase": "Ready", "tokenSecretRef": "export-token-vm1-export-abc",
			"links": map[string]any{"internal": map[string]any{
				"cert": "PEM",
				"volumes": []any{
					map[string]any{"name": "rootdisk", "formats": []any{
						map[string]any{"format": "raw", "url": "https://virt-export-vm1-export-abc.ns.svc/volumes/rootdisk/disk.img"},
						map[string]any{"format": "dir", "url": "https://virt-export-vm1-export-abc.ns.svc/volumes/rootdisk/dir"},
						map[string]any{"format": "gzip", "url": "https://virt-export-vm1-export-abc.ns.svc/volumes/rootdisk/disk.img.gz"},
					}},
					map[string]any{"name": "data", "formats": []any{map[string]any{"format": "raw", "url": "https://x/data.img"}}},
				},
			}},
		},
	}
	vols := exportVolumes(obj)
	if len(vols) != 2 || vols[0].Name != "rootdisk" || len(vols[0].Formats) != 2 || vols[0].Formats[0] != "gzip" || vols[0].Formats[1] != "raw" {
		t.Fatalf("volumes = %+v", vols)
	}
	link, err := exportLink(obj, "rootdisk", "")
	if err != nil || link.URL != "https://virt-export-vm1-export-abc.ns.svc/volumes/rootdisk/disk.img.gz" ||
		link.Service != "virt-export-vm1-export-abc" || link.TokenSecret != "export-token-vm1-export-abc" || link.CA != "PEM" {
		t.Fatalf("link = %+v, %v", link, err)
	}
	if _, err := exportLink(obj, "", ""); err == nil {
		t.Fatal("two volumes and none named: want an error")
	}
	if _, err := exportLink(obj, "data", "gzip"); err == nil {
		t.Fatal("a format the volume doesn't offer: want an error")
	}

	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get(vmExportTokenHeader) != "s3cret" || r.URL.RawQuery != "" {
			http.Error(w, "bad token", http.StatusUnauthorized)
			return
		}
		w.Write([]byte("disk bytes"))
	}))
	defer srv.Close()
	dir := t.TempDir()
	path := filepath.Join(dir, "disk.img.gz")
	var n atomic.Int64
	var total int64
	if err := downloadTo(context.Background(), srv.Client(), srv.URL, "s3cret", path, &n, func(v int64) { total = v }); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(path); string(b) != "disk bytes" || n.Load() != 10 || total != 10 {
		t.Fatalf("file %q, %d of %d bytes", b, n.Load(), total)
	}
	bad := filepath.Join(dir, "bad.img")
	if err := downloadTo(context.Background(), srv.Client(), srv.URL, "wrong", bad, &n, func(int64) {}); err == nil {
		t.Fatal("refused download: want an error")
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 1 {
		t.Fatalf("files left: %v", entries)
	}
}
