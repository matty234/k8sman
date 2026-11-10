// Command k8sman-server is the local API backend for the k8sman UI.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"runtime/debug"
	"strings"
	"syscall"
	"time"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/columns"
	"github.com/matty234/k8sman/backend/internal/icons"
	"github.com/matty234/k8sman/backend/internal/plugins"
	"github.com/matty234/k8sman/backend/internal/portforward"
	"github.com/matty234/k8sman/backend/internal/server"
	"github.com/matty234/k8sman/backend/internal/settings"
)

// stringList is a repeatable string flag.
type stringList []string

func (l *stringList) String() string     { return strings.Join(*l, ",") }
func (l *stringList) Set(v string) error { *l = append(*l, v); return nil }

func main() {
	if len(os.Args) > 1 && os.Args[1] == "plugin" {
		os.Exit(pluginCommand(os.Args[2:]))
	}
	var pluginDev stringList
	flag.Var(&pluginDev, "plugin-dev", "load the plugin in this folder (or the plugins in its subfolders) in dev mode, hot reloaded; repeatable")
	var (
		addr         = flag.String("addr", "127.0.0.1:7443", "listen address (keep on loopback; port 0 picks a free one)")
		kubeconfig   = flag.String("kubeconfig", "", "kubeconfig path (default: the one chosen in the app, else $KUBECONFIG or ~/.kube/config)")
		kubectx      = flag.String("context", "", "kube context (default: last used for the kubeconfig, else its current-context)")
		colsPath     = flag.String("columns", columns.DefaultStorePath(), "column customisation file")
		pfPath       = flag.String("portforwards", portforward.DefaultPath(), "saved port-forwards file")
		settingsPath = flag.String("settings", settings.DefaultPath(), "app settings file (chosen kubeconfig, last contexts)")
		readOnly     = flag.Bool("read-only", false, "disable object edits and starting port-forwards")
		noRemoteIcon = flag.Bool("no-remote-icons", false, "never fetch CRD group icons (chart icons, website favicons) from the internet")
		iconCache    = flag.String("icon-cache", icons.DefaultCacheDir(), "CRD group icon cache directory")
		exitOnEOF    = flag.Bool("exit-on-stdin-eof", false, "shut down when stdin closes (set by the desktop app so the backend dies with it)")
		pprofAddr    = flag.String("pprof", "", "serve net/http/pprof on this loopback address (e.g. 127.0.0.1:6060); off by default")
		cacheDir     = flag.String("cache-dir", cluster.DefaultCacheDir(), "on-disk discovery cache for fast cold starts (\"\" = memory only)")
	)
	flag.Parse()
	tuneGC()
	token, err := authToken()
	if err != nil {
		log.Fatalf("auth token: %v", err)
	}
	if *pprofAddr != "" {
		startPprof(*pprofAddr, token)
	}

	cluster.CacheDir = *cacheDir
	st, err := settings.Open(*settingsPath)
	if err != nil {
		log.Printf("settings: %v (using defaults)", err)
	}
	mgr := connect(*kubeconfig, *kubectx, st.Get())
	store, err := columns.OpenStore(*colsPath)
	if err != nil {
		log.Fatalf("columns: %v", err)
	}
	pf, err := portforward.NewManager(mgr, *pfPath)
	if err != nil {
		log.Fatalf("port-forwards: %v", err)
	}

	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	if c := mgr.Clients(); c != nil {
		log.Printf("k8sman-server kubeconfig=%q context=%s host=%s read-only=%v", mgr.Kubeconfig(), c.Context, c.RESTConfig.Host, *readOnly)
	} else {
		log.Printf("k8sman-server started without a cluster connection: %v", mgr.Err())
	}
	// Machine-readable ready line so a parent process can discover the port.
	fmt.Fprintf(os.Stdout, "K8SMAN_LISTENING %s\n", ln.Addr().String())

	// Plugins load in the background (dev mode only in this version).
	ph := plugins.NewHost(plugins.Options{InstalledDir: filepath.Join(filepath.Dir(*settingsPath), "plugins"), FlagDirs: pluginDev, Settings: st})
	ph.Start()
	defer ph.Close()

	srv := &http.Server{Handler: server.New(mgr, store, pf, server.Options{ReadOnly: *readOnly, Settings: st, NoRemoteIcons: *noRemoteIcon, IconCacheDir: *iconCache, AuthToken: token, Plugins: ph})}
	go func() {
		if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
			log.Fatal(err)
		}
	}()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	if *exitOnEOF {
		go func() {
			_, _ = io.Copy(io.Discard, os.Stdin)
			log.Print("stdin closed (parent exited)")
			sig <- syscall.SIGTERM
		}()
	}
	<-sig
	log.Print("shutting down: stopping port-forwards")
	pf.StopAll()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
}

// tuneGC lets the heap grow to 1.5x the live data between collections
// instead of Go's default 2x, unless $GOGC says otherwise. Most of the live
// heap is the shared watch cache, which is long-lived, so the extra GC work
// is small; it keeps ~15 MB less around with a few large tables open.
func tuneGC() {
	if _, ok := os.LookupEnv("GOGC"); !ok {
		debug.SetGCPercent(50)
	}
}

// authToken returns the bearer token clients must send. The desktop app
// passes a fresh one per launch in $K8SMAN_AUTH_TOKEN, which is then removed
// from the environment so child processes don't inherit it. A server started
// by hand (make backend) generates one, writes it to devTokenPath() (mode
// 0600) for `make app-dev`, and prints it on stderr for curl.
func authToken() (string, error) {
	if t, ok := os.LookupEnv(server.AuthTokenEnv); ok {
		_ = os.Unsetenv(server.AuthTokenEnv)
		if len(t) < server.MinTokenLength {
			return "", fmt.Errorf("$%s must be at least %d characters", server.AuthTokenEnv, server.MinTokenLength)
		}
		return t, nil
	}
	t, err := server.NewToken()
	if err != nil {
		return "", err
	}
	path := devTokenPath()
	if err := writeDevToken(path, t); err != nil {
		log.Printf("could not write the dev token file %s: %v", path, err)
	} else {
		log.Printf("no $%s set: generated a dev token, written to %s (mode 0600)", server.AuthTokenEnv, path)
	}
	fmt.Fprintf(os.Stderr, "K8SMAN_DEV_TOKEN %s\n", t)
	return t, nil
}

// devTokenPath is ~/.config/k8sman/dev-token, next to settings.json. The
// frontend reads the same path (lib/app/backend.dart).
func devTokenPath() string {
	return filepath.Join(filepath.Dir(settings.DefaultPath()), "dev-token")
}

// writeDevToken atomically replaces path with token, readable only by the user.
func writeDevToken(path, token string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".dev-token-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if err := f.Chmod(0o600); err != nil {
		f.Close()
		return err
	}
	if _, err := f.WriteString(token + "\n"); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(f.Name(), path)
}

// connect picks the kubeconfig and context to start with. Explicit flags
// win; otherwise the kubeconfig chosen in the app and its last context are
// restored, falling back to the default kubeconfig. If nothing loads, the
// server still starts (disconnected) so the UI can let the user pick a file.
func connect(flagKubeconfig, flagContext string, s settings.Settings) *cluster.Manager {
	home, _ := os.UserHomeDir()
	type attempt struct{ kubeconfig, context string }
	var attempts []attempt
	addFor := func(kc string) {
		if flagContext != "" {
			attempts = append(attempts, attempt{kc, flagContext})
			return
		}
		if last := s.LastContext[kc]; last != "" {
			attempts = append(attempts, attempt{kc, last})
		}
		attempts = append(attempts, attempt{kc, ""})
	}
	if flagKubeconfig != "" {
		addFor(flagKubeconfig)
	} else {
		if s.Kubeconfig != "" {
			addFor(s.Kubeconfig)
		}
		addFor(cluster.DefaultKubeconfig(home, os.Getenv("KUBECONFIG")))
	}
	var firstErr error
	for _, a := range attempts {
		mgr, err := cluster.NewManager(a.kubeconfig, a.context)
		if err == nil {
			return mgr
		}
		log.Printf("connect kubeconfig=%q context=%q: %v", a.kubeconfig, a.context, err)
		if firstErr == nil {
			firstErr = err
		}
	}
	kc := flagKubeconfig
	if kc == "" {
		kc = cluster.DefaultKubeconfig(home, os.Getenv("KUBECONFIG"))
	}
	return cluster.NewDisconnected(kc, firstErr)
}
