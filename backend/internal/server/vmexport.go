package server

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/portforward"
)

// KubeVirt disk export, natively (what `virtctl vmexport download` does):
//
//  1. create a VirtualMachineExport of a VM or PVC (or adopt an existing
//     export), with a ttlDuration as a safety net;
//  2. wait for it to be Ready, reporting its phase and conditions (a VM
//     export waits for the VM to stop);
//  3. read the token from the Secret named in status.tokenSecretRef, with
//     the user's credentials; it is only ever sent to the export server,
//     never logged nor returned to the UI;
//  4. download status.links.internal.volumes[].formats[].url through an
//     in-process port-forward to the export server's pod (portforward.
//     DialPod: nothing listens on this machine), over TLS trusting
//     status.links.internal.cert, with header x-kubevirt-export-token;
//  5. stream the body straight into the file the user chose (the backend
//     runs on the user's machine: it only listens on loopback, see
//     checkAccess), via <file>.part, with progress;
//  6. delete the export it created, and close the port-forward, when the
//     download ends, fails or is cancelled (or the UI stops asking about
//     the job for vmExportIdle).

var vmExportGVR = schema.GroupVersionResource{Group: "export.kubevirt.io", Version: "v1beta1", Resource: "virtualmachineexports"}

const (
	// vmExportTTL is the export's own expiry, should k8sman die before it
	// deletes it. Long enough for a large disk over a port-forward.
	vmExportTTL = "6h"
	// vmExportIdle cancels a job the UI has stopped asking about.
	vmExportIdle = 60 * time.Second
	// vmExportTokenHeader carries the export token.
	vmExportTokenHeader = "x-kubevirt-export-token"
)

// vmExportFormatOrder is the formats the UI offers, the default first:
// gzip-compressed raw, then raw, then archives (dir is a listing, not one
// file, so it isn't offered).
var vmExportFormatOrder = []string{"gzip", "raw", "tar.gz"}

// VMExportVolume is one exported volume and the formats it is offered in.
type VMExportVolume struct {
	Name    string   `json:"name"`
	Formats []string `json:"formats"`
}

// VMExportCondition is one of the export's conditions.
type VMExportCondition struct {
	Type    string `json:"type"`
	Status  string `json:"status"`
	Reason  string `json:"reason,omitempty"`
	Message string `json:"message,omitempty"`
}

// VMExportStatus is a job as the UI sees it.
type VMExportStatus struct {
	ID        string `json:"id"`
	Namespace string `json:"namespace"`
	// Export is the VirtualMachineExport's name; Created is whether this
	// job created it (and so deletes it).
	Export  string `json:"export"`
	Created bool   `json:"created"`
	// State: waiting (for the export), ready (pick a volume and format),
	// downloading, done, failed or cancelled.
	State      string              `json:"state"`
	Phase      string              `json:"phase,omitempty"`
	Conditions []VMExportCondition `json:"conditions"`
	Volumes    []VMExportVolume    `json:"volumes"`
	Error      string              `json:"error,omitempty"`
	// Path is the file being written; Bytes so far of Total (-1 unknown).
	Path  string `json:"path,omitempty"`
	Bytes int64  `json:"bytes"`
	Total int64  `json:"total"`
}

type vmExportJob struct {
	c      *cluster.Clients
	res    dynamic.ResourceInterface
	ctx    context.Context
	cancel context.CancelFunc
	seen   atomic.Int64 // unix nanos of the UI's last request
	bytes  atomic.Int64

	mu  sync.Mutex
	st  VMExportStatus
	obj map[string]any // the export as last read
	// dl is closed when a started download has ended.
	dl chan struct{}
	// done is closed once the job has cleaned up.
	done chan struct{}
}

var vmExports = struct {
	mu   sync.Mutex
	jobs map[string]*vmExportJob
}{jobs: map[string]*vmExportJob{}}

func (s *Server) vmExportRoutes() {
	s.mux.HandleFunc("POST /api/vm-exports", s.handleVMExportStart)
	s.mux.HandleFunc("GET /api/vm-exports/{id}", handleVMExportGet)
	s.mux.HandleFunc("POST /api/vm-exports/{id}/download", s.handleVMExportDownload)
	s.mux.HandleFunc("DELETE /api/vm-exports/{id}", handleVMExportCancel)
}

// vmExportStart is POST /api/vm-exports: export kind/name in namespace
// (kind VirtualMachine or PersistentVolumeClaim creates an export;
// VirtualMachineExport adopts one, which is left in place afterwards).
type vmExportStart struct {
	Namespace string `json:"namespace"`
	Kind      string `json:"kind"`
	Name      string `json:"name"`
}

func (s *Server) handleVMExportStart(w http.ResponseWriter, r *http.Request) {
	req, ok := httpx.DecodeJSON[vmExportStart](w, r, 1<<16)
	if !ok {
		return
	}
	if req.Namespace == "" || req.Name == "" {
		writeErr(w, httpx.BadRequest("namespace and name are required"))
		return
	}
	var source map[string]any
	switch req.Kind {
	case "VirtualMachine":
		source = map[string]any{"apiGroup": "kubevirt.io", "kind": "VirtualMachine", "name": req.Name}
	case "PersistentVolumeClaim":
		source = map[string]any{"apiGroup": "", "kind": "PersistentVolumeClaim", "name": req.Name}
	case "VirtualMachineExport":
	default:
		writeErr(w, httpx.BadRequest("kind must be VirtualMachine, PersistentVolumeClaim or VirtualMachineExport"))
		return
	}
	// Creating an export changes the cluster; downloading an existing one
	// only reads.
	if source != nil && s.refuseReadOnly(w) {
		return
	}
	c := s.mgr.Clients()
	if c == nil {
		writeErr(w, s.mgr.Err())
		return
	}
	if _, ok := s.typeForKey(r.Context(), c, "export.kubevirt.io/VirtualMachineExport", vmExportGVR.Version); !ok {
		writeErr(w, httpx.BadRequest("this cluster doesn't serve export.kubevirt.io/v1beta1 VirtualMachineExports (KubeVirt 1.1 or later, with the VMExport feature gate)"))
		return
	}
	res := c.Dynamic.Resource(vmExportGVR).Namespace(req.Namespace)
	name := req.Name
	if source != nil {
		obj := &unstructured.Unstructured{Object: map[string]any{
			"apiVersion": vmExportGVR.GroupVersion().String(),
			"kind":       "VirtualMachineExport",
			"metadata": map[string]any{
				"generateName": dnsPrefix(req.Name) + "-export-",
				"labels":       map[string]any{"app.kubernetes.io/managed-by": "k8sman"},
			},
			"spec": map[string]any{"source": source, "ttlDuration": vmExportTTL},
		}}
		created, err := res.Create(r.Context(), obj, metav1.CreateOptions{})
		if err != nil {
			writeErr(w, err)
			return
		}
		name = created.GetName()
	} else if _, err := res.Get(r.Context(), name, metav1.GetOptions{}); err != nil {
		writeErr(w, err)
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	j := &vmExportJob{c: c, res: res, ctx: ctx, cancel: cancel, done: make(chan struct{}),
		st: VMExportStatus{ID: newJobID(), Namespace: req.Namespace, Export: name, Created: source != nil, State: "waiting",
			Conditions: []VMExportCondition{}, Volumes: []VMExportVolume{}, Total: -1}}
	j.seen.Store(time.Now().UnixNano())
	vmExports.mu.Lock()
	vmExports.jobs[j.st.ID] = j
	vmExports.mu.Unlock()
	go j.run()
	httpx.WriteJSON(w, http.StatusCreated, j.status())
}

func vmExportJobFor(w http.ResponseWriter, r *http.Request) *vmExportJob {
	vmExports.mu.Lock()
	j := vmExports.jobs[r.PathValue("id")]
	vmExports.mu.Unlock()
	if j == nil {
		httpx.WriteError(w, http.StatusNotFound, "NotFound", "no such export job")
		return nil
	}
	j.seen.Store(time.Now().UnixNano())
	return j
}

func handleVMExportGet(w http.ResponseWriter, r *http.Request) {
	if j := vmExportJobFor(w, r); j != nil {
		httpx.WriteJSON(w, http.StatusOK, j.status())
	}
}

func handleVMExportCancel(w http.ResponseWriter, r *http.Request) {
	j := vmExportJobFor(w, r)
	if j == nil {
		return
	}
	j.cancel()
	// Wait (briefly) for the clean-up, so the UI's next look at the
	// cluster doesn't show the export it just cancelled.
	select {
	case <-j.done:
	case <-time.After(10 * time.Second):
	}
	httpx.WriteJSON(w, http.StatusOK, j.status())
}

// vmExportDownload is POST /api/vm-exports/{id}/download.
type vmExportDownload struct {
	Volume string `json:"volume"`
	Format string `json:"format"`
	// Path is the absolute path of the file to write, chosen in the save
	// panel (which asked before replacing a file).
	Path string `json:"path"`
}

func (s *Server) handleVMExportDownload(w http.ResponseWriter, r *http.Request) {
	j := vmExportJobFor(w, r)
	if j == nil {
		return
	}
	req, ok := httpx.DecodeJSON[vmExportDownload](w, r, 1<<16)
	if !ok {
		return
	}
	if !filepath.IsAbs(req.Path) {
		writeErr(w, httpx.BadRequest("path must be absolute"))
		return
	}
	if fi, err := os.Stat(filepath.Dir(req.Path)); err != nil || !fi.IsDir() {
		writeErr(w, httpx.BadRequest("%s is not a folder", filepath.Dir(req.Path)))
		return
	}
	j.mu.Lock()
	if j.st.State != "ready" {
		state := j.st.State
		j.mu.Unlock()
		writeErr(w, httpx.BadRequest("the export is %s, not ready", state))
		return
	}
	link, err := exportLink(j.obj, req.Volume, req.Format)
	if err != nil {
		j.mu.Unlock()
		writeErr(w, httpx.BadRequest("%v", err))
		return
	}
	j.st.State, j.st.Path = "downloading", req.Path
	j.dl = make(chan struct{})
	j.mu.Unlock()
	go j.download(link, req.Path)
	httpx.WriteJSON(w, http.StatusAccepted, j.status())
}

func (j *vmExportJob) status() VMExportStatus {
	j.mu.Lock()
	defer j.mu.Unlock()
	st := j.st
	st.Conditions = slices.Clone(st.Conditions)
	st.Volumes = slices.Clone(st.Volumes)
	st.Bytes = j.bytes.Load()
	return st
}

func (j *vmExportJob) set(f func(st *VMExportStatus)) {
	j.mu.Lock()
	f(&j.st)
	j.mu.Unlock()
}

// finished reports whether the job has reached an end state.
func (j *vmExportJob) finished() bool {
	j.mu.Lock()
	defer j.mu.Unlock()
	return j.st.State == "done" || j.st.State == "failed" || j.st.State == "cancelled"
}

// run waits for the export, then for the download (started by the UI),
// then cleans up. A finished job is kept for a minute so the UI sees how
// it ended.
func (j *vmExportJob) run() {
	defer func() {
		j.cleanup()
		close(j.done)
		time.AfterFunc(time.Minute, func() {
			vmExports.mu.Lock()
			delete(vmExports.jobs, j.st.ID)
			vmExports.mu.Unlock()
		})
	}()
	tick := time.NewTicker(2 * time.Second)
	defer tick.Stop()
	for {
		if j.finished() {
			return
		}
		if time.Since(time.Unix(0, j.seen.Load())) > vmExportIdle {
			j.cancel()
		}
		if j.ctx.Err() != nil {
			// Cancelled (or a download ended): wait for a running download
			// to notice and report; anything else ends here.
			var dl chan struct{}
			j.set(func(st *VMExportStatus) {
				if st.State == "downloading" {
					dl = j.dl
				} else if st.State == "waiting" || st.State == "ready" {
					st.State = "cancelled"
				}
			})
			if dl != nil {
				<-dl
			}
			return
		}
		if j.status().State == "waiting" {
			j.poll()
		}
		select {
		case <-tick.C:
		case <-j.ctx.Done():
		}
	}
}

// poll reads the export and updates the job's phase, conditions and
// volumes; Ready makes the job ready, Terminated or Skipped fails it.
func (j *vmExportJob) poll() {
	ctx, cancel := context.WithTimeout(j.ctx, 10*time.Second)
	defer cancel()
	u, err := j.res.Get(ctx, j.status().Export, metav1.GetOptions{})
	if err != nil {
		if j.ctx.Err() == nil && apierrors.IsNotFound(err) {
			j.set(func(st *VMExportStatus) { st.State, st.Error = "failed", "the export was deleted" })
		}
		return
	}
	phase, _, _ := unstructured.NestedString(u.Object, "status", "phase")
	conds := exportConditions(u.Object)
	vols := exportVolumes(u.Object)
	j.mu.Lock()
	defer j.mu.Unlock()
	j.obj, j.st.Phase, j.st.Conditions, j.st.Volumes = u.Object, phase, conds, vols
	switch phase {
	case "Ready":
		if len(vols) == 0 {
			j.st.State, j.st.Error = "failed", "the export is ready but offers no volume to download"
		} else {
			j.st.State = "ready"
		}
	case "Terminated", "Skipped":
		j.st.State, j.st.Error = "failed", "the export is "+phase
	}
}

func exportConditions(obj map[string]any) []VMExportCondition {
	out := []VMExportCondition{}
	list, _, _ := unstructured.NestedSlice(obj, "status", "conditions")
	for _, x := range list {
		m, _ := x.(map[string]any)
		str := func(k string) string { s, _ := m[k].(string); return s }
		out = append(out, VMExportCondition{Type: str("type"), Status: str("status"), Reason: str("reason"), Message: str("message")})
	}
	return out
}

// exportVolumes lists the volumes of an export's internal links with the
// formats offered for each, in vmExportFormatOrder (the default first).
func exportVolumes(obj map[string]any) []VMExportVolume {
	out := []VMExportVolume{}
	vols, _, _ := unstructured.NestedSlice(obj, "status", "links", "internal", "volumes")
	for _, v := range vols {
		vm, _ := v.(map[string]any)
		name, _ := vm["name"].(string)
		have := map[string]bool{}
		fs, _ := vm["formats"].([]any)
		for _, f := range fs {
			fm, _ := f.(map[string]any)
			if format, _ := fm["format"].(string); format != "" {
				if u, _ := fm["url"].(string); u != "" {
					have[format] = true
				}
			}
		}
		vol := VMExportVolume{Name: name, Formats: []string{}}
		for _, f := range vmExportFormatOrder {
			if have[f] {
				vol.Formats = append(vol.Formats, f)
			}
		}
		if name != "" && len(vol.Formats) > 0 {
			out = append(out, vol)
		}
	}
	return out
}

// vmExportLink is what a download needs from the export.
type vmExportLink struct {
	URL         string
	CA          string
	Service     string
	TokenSecret string
}

// exportLink picks volume's format URL from export obj's internal links,
// with what reaching it needs. volume "" picks the only volume, format ""
// the default format.
func exportLink(obj map[string]any, volume, format string) (vmExportLink, error) {
	vols := exportVolumes(obj)
	var vol *VMExportVolume
	for i := range vols {
		if vols[i].Name == volume || (volume == "" && len(vols) == 1) {
			vol = &vols[i]
		}
	}
	if vol == nil {
		return vmExportLink{}, fmt.Errorf("the export has no volume %q", volume)
	}
	if format == "" {
		format = vol.Formats[0]
	}
	if !slices.Contains(vol.Formats, format) {
		return vmExportLink{}, fmt.Errorf("volume %s isn't offered as %q (only %v)", vol.Name, format, vol.Formats)
	}
	var link vmExportLink
	vs, _, _ := unstructured.NestedSlice(obj, "status", "links", "internal", "volumes")
	for _, v := range vs {
		vm, _ := v.(map[string]any)
		if vm["name"] != vol.Name {
			continue
		}
		fs, _ := vm["formats"].([]any)
		for _, f := range fs {
			if fm, _ := f.(map[string]any); fm["format"] == format {
				link.URL, _ = fm["url"].(string)
			}
		}
	}
	link.CA, _, _ = unstructured.NestedString(obj, "status", "links", "internal", "cert")
	link.Service, _, _ = unstructured.NestedString(obj, "status", "serviceName")
	if link.Service == "" {
		name, _, _ := unstructured.NestedString(obj, "metadata", "name")
		link.Service = "virt-export-" + name
	}
	link.TokenSecret, _, _ = unstructured.NestedString(obj, "status", "tokenSecretRef")
	if link.TokenSecret == "" {
		link.TokenSecret, _, _ = unstructured.NestedString(obj, "spec", "tokenSecretRef")
	}
	switch {
	case link.URL == "":
		return vmExportLink{}, fmt.Errorf("volume %s has no %s link", vol.Name, format)
	case link.CA == "":
		return vmExportLink{}, errors.New("the export has no internal certificate to trust")
	case link.TokenSecret == "":
		return vmExportLink{}, errors.New("the export names no token Secret")
	}
	return link, nil
}

// download streams link to path (through path.part) and ends the job.
func (j *vmExportJob) download(link vmExportLink, path string) {
	defer close(j.dl)
	err := j.fetch(link, path)
	j.set(func(st *VMExportStatus) {
		switch {
		case err == nil:
			st.State = "done"
		case j.ctx.Err() != nil:
			st.State = "cancelled"
		default:
			st.State, st.Error = "failed", err.Error()
		}
	})
	j.cancel() // wake run, which cleans up
}

func (j *vmExportJob) fetch(link vmExportLink, path string) error {
	ctx := j.ctx
	ns := j.status().Namespace
	token, err := exportToken(ctx, j.c, ns, link.TokenSecret)
	if err != nil {
		return err
	}
	client, closeClient, err := exportClient(ctx, j.c, ns, link)
	if err != nil {
		return err
	}
	defer closeClient()
	return downloadTo(ctx, client, link.URL, token, path, &j.bytes, func(total int64) {
		j.set(func(st *VMExportStatus) { st.Total = total })
	})
}

// exportToken reads the export token from Secret name with the user's
// credentials. The token goes only into the request header.
func exportToken(ctx context.Context, c *cluster.Clients, ns, name string) (string, error) {
	sec, err := c.Typed.CoreV1().Secrets(ns).Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		if apierrors.IsForbidden(err) {
			return "", fmt.Errorf("not allowed to read the export's token Secret %s (needs get on secrets in %s)", name, ns)
		}
		return "", fmt.Errorf("reading the export's token Secret %s: %w", name, err)
	}
	token := string(sec.Data["token"])
	if token == "" {
		return "", fmt.Errorf("the export's token Secret %s has no token", name)
	}
	return token, nil
}

// exportClient is an HTTP client whose connections go through a
// port-forward to a ready pod behind the export's service, over TLS
// trusting the export's CA and verifying the URL's host name.
func exportClient(ctx context.Context, c *cluster.Clients, ns string, link vmExportLink) (*http.Client, func(), error) {
	u, err := url.Parse(link.URL)
	if err != nil {
		return nil, nil, fmt.Errorf("export link: %v", err)
	}
	port := u.Port()
	if port == "" {
		port = "443"
	}
	pod, podPort, err := portforward.ResolveService(ctx, c, ns, link.Service, port)
	if err != nil {
		return nil, nil, fmt.Errorf("export server: %w", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM([]byte(link.CA)) {
		return nil, nil, errors.New("the export's certificate isn't PEM")
	}
	tr := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return portforward.DialPod(ctx, c, pod.Namespace, pod.Name, podPort)
		},
		TLSClientConfig:       &tls.Config{RootCAs: pool, ServerName: u.Hostname(), MinVersion: tls.VersionTLS12},
		TLSHandshakeTimeout:   30 * time.Second,
		ResponseHeaderTimeout: 2 * time.Minute,
		DisableCompression:    true, // gzip is a format here: keep the bytes as served
		MaxIdleConns:          1,
	}
	return &http.Client{Transport: tr}, tr.CloseIdleConnections, nil
}

// downloadTo GETs u with the token and writes the body to path through
// path.part, counting bytes into n and reporting the size when known. A
// failure or cancel removes the partial file.
func downloadTo(ctx context.Context, client *http.Client, u, token, path string, n *atomic.Int64, total func(int64)) (err error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	req.Header.Set(vmExportTokenHeader, token)
	resp, err := client.Do(req)
	if err != nil {
		var uerr *url.Error
		if errors.As(err, &uerr) {
			err = uerr.Err // the URL is noise; the cause is what matters
		}
		return fmt.Errorf("export server: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("export server answered %s: %s", resp.Status, string(b))
	}
	total(resp.ContentLength)
	part := path + ".part"
	f, err := os.OpenFile(part, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			_ = os.Remove(part)
		}
	}()
	_, err = io.Copy(f, &countingReader{r: resp.Body, n: n})
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return err
	}
	if resp.ContentLength >= 0 && n.Load() != resp.ContentLength {
		return fmt.Errorf("the download stopped at %d of %d bytes", n.Load(), resp.ContentLength)
	}
	return os.Rename(part, path)
}

type countingReader struct {
	r io.Reader
	n *atomic.Int64
}

func (c *countingReader) Read(p []byte) (int, error) {
	k, err := c.r.Read(p)
	c.n.Add(int64(k))
	return k, err
}

// cleanup deletes the export the job created.
func (j *vmExportJob) cleanup() {
	st := j.status()
	if !st.Created {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	err := j.res.Delete(ctx, st.Export, metav1.DeleteOptions{})
	if err != nil && !apierrors.IsNotFound(err) {
		log.Printf("vm export: deleting %s/%s: %v (it expires after %s)", st.Namespace, st.Export, err, vmExportTTL)
	}
}

// dnsPrefix keeps generateName short enough that the export server's
// service, virt-export-<export name>, stays within 63 characters.
func dnsPrefix(name string) string {
	if len(name) > 30 {
		return strings.TrimRight(name[:30], ".-")
	}
	return name
}

var jobSeq atomic.Int64

func newJobID() string {
	return strconv.FormatInt(time.Now().UnixNano(), 36) + "-" + strconv.FormatInt(jobSeq.Add(1), 36)
}
