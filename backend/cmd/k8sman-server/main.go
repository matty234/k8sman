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
	"syscall"
	"time"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/columns"
	"github.com/matty234/k8sman/backend/internal/icons"
	"github.com/matty234/k8sman/backend/internal/portforward"
	"github.com/matty234/k8sman/backend/internal/server"
	"github.com/matty234/k8sman/backend/internal/settings"
)

func main() {
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
		exitOnEOF    = flag.Bool("exit-on-stdin-eof", false, "shut down when stdin closes (set by the macOS app so the backend dies with it)")
	)
	flag.Parse()

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

	srv := &http.Server{Handler: server.New(mgr, store, pf, server.Options{ReadOnly: *readOnly, Settings: st, NoRemoteIcons: *noRemoteIcon, IconCacheDir: *iconCache})}
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
