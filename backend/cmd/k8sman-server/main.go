// Command k8sman-server is the local API backend for the k8sman UI.
package main

import (
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"

	"github.com/bargrove/k8sman/backend/internal/cluster"
	"github.com/bargrove/k8sman/backend/internal/columns"
	"github.com/bargrove/k8sman/backend/internal/server"
)

func main() {
	var (
		addr       = flag.String("addr", "127.0.0.1:7443", "listen address (keep on loopback)")
		kubeconfig = flag.String("kubeconfig", "", "kubeconfig path (default: $KUBECONFIG or ~/.kube/config)")
		kubectx    = flag.String("context", "", "kube context (default: current-context)")
		colsPath   = flag.String("columns", columns.DefaultStorePath(), "column customisation file")
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

	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	c := mgr.Clients()
	log.Printf("k8sman-server context=%s host=%s columns=%s", c.Context, c.RESTConfig.Host, *colsPath)
	// Machine-readable ready line so a parent process can discover the port.
	fmt.Fprintf(os.Stdout, "K8SMAN_LISTENING %s\n", ln.Addr().String())
	log.Fatal(http.Serve(ln, server.New(mgr, store)))
}
