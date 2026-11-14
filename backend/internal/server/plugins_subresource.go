package server

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/client-go/rest"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/plugins"
)

// The plugin subresources data source (since 0.2.22): a panel's GET of
// one of the object's subresources (KubeVirt's guestosinfo,
// filesystemlist), with the user's credentials. The plugin package has
// checked permissions.readSubresources and the denied subresources; reads
// are allowed on read-only contexts. Answers and errors are kept briefly,
// so a VMI whose status changes every few seconds (each change renders its
// panel again) doesn't call its guest agent each time.

// pluginSubresTTL is how long an answer (or error) is reused.
const pluginSubresTTL = 10 * time.Second

// pluginSubresCallTimeout bounds one call; the plugin package bounds a
// render's calls together.
const pluginSubresCallTimeout = 3 * time.Second

type pluginSubresEntry struct {
	at   time.Time
	body []byte
	err  error
}

var pluginSubres = struct {
	mu sync.Mutex
	m  map[string]pluginSubresEntry
}{m: map[string]pluginSubresEntry{}}

// GetSubresource implements plugins.SubresourceReader.
func (l *pluginLookup) GetSubresource(ctx context.Context, kindKey, group, version, ns, name, sub string) ([]byte, error) {
	rt, ok := l.s.typeForKey(ctx, l.c, kindKey, "")
	if !ok {
		return nil, plugins.ErrNotServed
	}
	return getSubresourceCached(ctx, l.c, rt, group, version, ns, name, sub)
}

func getSubresourceCached(ctx context.Context, c *cluster.Clients, rt cluster.ResourceType, group, version, ns, name, sub string) ([]byte, error) {
	if !rt.Namespaced {
		ns = ""
	}
	path := subresourcePath(group, version, rt, ns, name, sub)
	key := fmt.Sprintf("%p|%s", c, path)
	pluginSubres.mu.Lock()
	if e, ok := pluginSubres.m[key]; ok && time.Since(e.at) < pluginSubresTTL {
		pluginSubres.mu.Unlock()
		return e.body, e.err
	}
	pluginSubres.mu.Unlock()

	body, err := getSubresource(ctx, c, path)
	if ctx.Err() != nil && err != nil {
		// The render's budget ran out: not the call's answer, don't keep it.
		return nil, fmt.Errorf("timed out")
	}
	pluginSubres.mu.Lock()
	for k, e := range pluginSubres.m {
		if time.Since(e.at) >= pluginSubresTTL {
			delete(pluginSubres.m, k)
		}
	}
	pluginSubres.m[key] = pluginSubresEntry{at: time.Now(), body: body, err: err}
	pluginSubres.mu.Unlock()
	return body, err
}

func getSubresource(ctx context.Context, c *cluster.Clients, path string) ([]byte, error) {
	rc, ok := c.Typed.Discovery().RESTClient().(*rest.RESTClient)
	if !ok || rc == nil {
		return nil, fmt.Errorf("no REST client for %s", c.Context)
	}
	ctx, cancel := context.WithTimeout(ctx, pluginSubresCallTimeout)
	defer cancel()
	body, err := rc.Get().AbsPath(path).SetHeader("Accept", "application/json").DoRaw(ctx)
	if err != nil {
		return nil, subresourceError(ctx, err)
	}
	return body, nil
}

// subresourceError is a short, readable reason for a failed call.
func subresourceError(ctx context.Context, err error) error {
	switch {
	case ctx.Err() != nil:
		return fmt.Errorf("no answer within %s", pluginSubresCallTimeout)
	case apierrors.IsForbidden(err):
		return fmt.Errorf("not allowed")
	case apierrors.IsNotFound(err):
		return fmt.Errorf("not found")
	}
	var se apierrors.APIStatus
	if errors.As(err, &se) && se.Status().Message != "" {
		return errors.New(strings.TrimSpace(se.Status().Message))
	}
	return err
}
