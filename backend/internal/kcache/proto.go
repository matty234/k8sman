package kcache

import (
	"context"
	"net/http"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/rest"
)

// Protobuf fills.
//
// The fill of a built-in heavy kind (Secrets, ConfigMaps) asks for its
// pages in protobuf and summarises the typed objects: a value is measured
// (len of the bytes), never base64-encoded into a map and decoded again.
// Against JSON this reads ~20% fewer bytes (Secret values travel as raw
// bytes, not base64) with about half the CPU and 40% less peak heap; see
// docs/PERFORMANCE.md. A server that answers JSON instead is decoded as
// JSON (the Accept header lists both), so there is nothing to detect.
//
// Only summaries come this way. Full objects (the watch that follows, every
// other kind) stay JSON into unstructured: a typed decode drops fields newer
// than client-go's types, which a summary never reads but the inspector
// would. CRDs stay JSON too (their types aren't in client-go's scheme and
// the gain measured small).

// protoFill turns the switch off: every fill then reads JSON.
var protoFill = true

// protoSummarisers summarise the typed list of a kind with a protobuf fill,
// to the same maps as its summariser in summarisers.
var protoSummarisers = map[schema.GroupResource]func(runtime.Object) []map[string]any{
	{Resource: "secrets"}: func(o runtime.Object) []map[string]any {
		l := o.(*corev1.SecretList)
		out := make([]map[string]any, len(l.Items))
		for i := range l.Items {
			out[i] = summariseSecretTyped(&l.Items[i])
		}
		return out
	},
	{Resource: "configmaps"}: func(o runtime.Object) []map[string]any {
		l := o.(*corev1.ConfigMapList)
		out := make([]map[string]any, len(l.Items))
		for i := range l.Items {
			out[i] = summariseConfigMapTyped(&l.Items[i])
		}
		return out
	},
}

// newProtoList is the typed list a protobuf page decodes into.
func newProtoList(gr schema.GroupResource) runtime.Object {
	switch gr.Resource {
	case "secrets":
		return &corev1.SecretList{}
	default:
		return &corev1.ConfigMapList{}
	}
}

// NewProtoClient is a REST client for the protobuf fills, on the cluster's
// shared HTTP client. Requests use absolute paths, so one client serves
// every namespace.
func NewProtoClient(cfg *rest.Config, hc *http.Client) (rest.Interface, error) {
	c := rest.CopyConfig(cfg)
	c.APIPath, c.GroupVersion = "/api", &corev1.SchemeGroupVersion
	c.ContentType = runtime.ContentTypeProtobuf
	c.AcceptContentTypes = runtime.ContentTypeProtobuf + "," + runtime.ContentTypeJSON
	c.NegotiatedSerializer = scheme.Codecs.WithoutConversion()
	return rest.RESTClientForConfigAndClient(c, hc)
}

// pageFunc reads one page and summarises it, returning the summaries, the
// list's resourceVersion and its continue token.
type pageFunc func(ctx context.Context, opts metav1.ListOptions) ([]*unstructured.Unstructured, string, string, error)

// pager reads pages of key's summaries: in protobuf where it can (see
// above), else in JSON through the dynamic client.
func (c *Cache) pager(key Key, sum func(map[string]any) map[string]any) pageFunc {
	if f := protoSummarisers[key.GVR.GroupResource()]; f != nil && protoFill && c.proto != nil && key.GVR.Version == "v1" {
		p := "/api/v1/" + key.GVR.Resource
		if key.Namespace != "" {
			p = "/api/v1/namespaces/" + key.Namespace + "/" + key.GVR.Resource
		}
		_, kind, _ := heavy(key.GVR)
		return func(ctx context.Context, opts metav1.ListOptions) ([]*unstructured.Unstructured, string, string, error) {
			l := newProtoList(key.GVR.GroupResource())
			if err := c.proto.Get().AbsPath(p).VersionedParams(&opts, scheme.ParameterCodec).Do(ctx).Into(l); err != nil {
				return nil, "", "", err
			}
			lm := l.(metav1.ListInterface)
			objs := f(l)
			items := make([]*unstructured.Unstructured, len(objs))
			for i, o := range objs {
				o["apiVersion"], o["kind"] = "v1", kind
				items[i] = &unstructured.Unstructured{Object: o}
			}
			return items, lm.GetResourceVersion(), lm.GetContinue(), nil
		}
	}
	ri := c.source(key)
	return func(ctx context.Context, opts metav1.ListOptions) ([]*unstructured.Unstructured, string, string, error) {
		list, err := ri.List(ctx, opts)
		if err != nil {
			return nil, "", "", err
		}
		items := make([]*unstructured.Unstructured, len(list.Items))
		for i := range list.Items {
			u := &list.Items[i]
			u.Object = sum(u.Object)
			items[i] = u
		}
		return items, list.GetResourceVersion(), list.GetContinue(), nil
	}
}

// typedMap is a typed object as the map the summarisers take.
func typedMap(o any) map[string]any {
	m, _ := runtime.DefaultUnstructuredConverter.ToUnstructured(o)
	return m
}

// summariseSecretTyped is summariseSecret of a typed Secret. It takes the
// values out of s.
func summariseSecretTyped(s *corev1.Secret) map[string]any {
	d := byteSizes(s.Data)
	s.Data, s.StringData = nil, nil
	out := summariseSecret(typedMap(s))
	if d != nil {
		out["data"] = d
	}
	return out
}

// summariseConfigMapTyped is summariseConfigMap of a typed ConfigMap. It
// takes the values out of cm.
func summariseConfigMapTyped(cm *corev1.ConfigMap) map[string]any {
	var d map[string]any
	if len(cm.Data) > 0 {
		d = make(map[string]any, len(cm.Data))
		for k, v := range cm.Data {
			d[k] = textSize(v)
		}
	}
	bd := byteSizes(cm.BinaryData)
	cm.Data, cm.BinaryData = nil, nil
	out := summariseConfigMap(typedMap(cm))
	if d != nil {
		out["data"] = d
	}
	if bd != nil {
		out["binaryData"] = bd
	}
	return out
}

// byteSizes maps each key of m to its value's length; nil for no keys.
func byteSizes(m map[string][]byte) map[string]any {
	if len(m) == 0 {
		return nil
	}
	out := make(map[string]any, len(m))
	for k, v := range m {
		out[k] = int64(len(v))
	}
	return out
}
