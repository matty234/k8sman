// Command k8sman-server is the local API backend for the k8sman UI.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/bargrove/k8sman/backend/internal/cluster"
	"github.com/bargrove/k8sman/backend/internal/columns"
	"github.com/bargrove/k8sman/backend/internal/portforward"
	"github.com/bargrove/k8sman/backend/internal/server"
)

func main() {
	var (
		addr       = flag.String("addr", "127.0.0.1:7443", "listen address (keep on loopback)")
		kubeconfig = flag.String("kubeconfig", "", "kubeconfig path (default: $KUBECONFIG or ~/.kube/config)")
		kubectx    = flag.String("context", "", "kube context (default: current-context)")
		colsPath   = flag.String("columns", columns.DefaultStorePath(), "column customisation file")
		pfPath     = flag.String("portforwards", portforward.DefaultPath(), "saved port-forwards file")
		readOnly   = flag.Bool("read-only", false, "disable object edits and starting port-forwards")
	)
	flag.Parse()

	mgr, err := cluster.NewManager(*kubeconfig, *kubectx)
	if err != nil {
		log.Fatalf("connect: %v", err)
	}
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
	c := mgr.Clients()
	log.Printf("k8sman-server context=%s host=%s read-only=%v", c.Context, c.RESTConfig.Host, *readOnly)
	// Machine-readable ready line so a parent process can discover the port.
	fmt.Fprintf(os.Stdout, "K8SMAN_LISTENING %s\n", ln.Addr().String())

	srv := &http.Server{Handler: server.New(mgr, store, pf, server.Options{ReadOnly: *readOnly})}
	go func() {
		if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
			log.Fatal(err)
		}
	}()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	log.Print("shutting down: stopping port-forwards")
	pf.StopAll()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
}
