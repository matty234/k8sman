package helm

import (
	"helm.sh/helm/v3/pkg/action"
	"helm.sh/helm/v3/pkg/kube"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/cli-runtime/pkg/genericclioptions"
	"k8s.io/client-go/discovery"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/restmapper"
	"k8s.io/client-go/tools/clientcmd"
	clientcmdapi "k8s.io/client-go/tools/clientcmd/api"

	"github.com/bargrove/k8sman/backend/internal/cluster"
)

// restGetter adapts a cluster.Clients snapshot to the RESTClientGetter the
// Helm SDK expects, so Helm talks to the same context (and with the same
// credentials) as the rest of the app instead of re-reading kubeconfig.
type restGetter struct {
	c         *cluster.Clients
	namespace string
}

var _ genericclioptions.RESTClientGetter = (*restGetter)(nil)

func (g *restGetter) ToRESTConfig() (*rest.Config, error) {
	return rest.CopyConfig(g.c.RESTConfig), nil
}

func (g *restGetter) ToDiscoveryClient() (discovery.CachedDiscoveryInterface, error) {
	return g.c.Discovery, nil
}

func (g *restGetter) ToRESTMapper() (meta.RESTMapper, error) {
	m := restmapper.NewDeferredDiscoveryRESTMapper(g.c.Discovery)
	return restmapper.NewShortcutExpander(m, g.c.Discovery, nil), nil
}

func (g *restGetter) ToRawKubeConfigLoader() clientcmd.ClientConfig {
	return &nsClientConfig{getter: g}
}

// nsClientConfig only answers the questions Helm's kube client asks: the
// REST config and the default namespace.
type nsClientConfig struct{ getter *restGetter }

func (n *nsClientConfig) RawConfig() (clientcmdapi.Config, error) {
	cfg := clientcmdapi.NewConfig()
	cfg.CurrentContext = n.getter.c.Context
	return *cfg, nil
}

func (n *nsClientConfig) ClientConfig() (*rest.Config, error) { return n.getter.ToRESTConfig() }

func (n *nsClientConfig) Namespace() (string, bool, error) {
	if n.getter.namespace == "" {
		return "default", false, nil
	}
	return n.getter.namespace, true, nil
}

func (n *nsClientConfig) ConfigAccess() clientcmd.ConfigAccess {
	return clientcmd.NewDefaultClientConfigLoadingRules()
}

// NewConfig builds a Helm action configuration for one namespace ("" = all
// namespaces, for listing) using the Secrets storage driver (Helm's default).
func NewConfig(c *cluster.Clients, namespace string) (*action.Configuration, error) {
	cfg := new(action.Configuration)
	getter := &restGetter{c: c, namespace: namespace}
	if err := cfg.Init(getter, namespace, "secret", func(string, ...any) {}); err != nil {
		return nil, err
	}
	if kc, ok := cfg.KubeClient.(*kube.Client); ok {
		kc.Namespace = namespace
	}
	return cfg, nil
}
