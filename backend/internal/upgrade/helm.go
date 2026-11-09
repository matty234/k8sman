package upgrade

import (
	"bytes"
	"compress/gzip"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"

	"helm.sh/helm/v3/pkg/release"

	"github.com/matty234/k8sman/backend/internal/helm"
)

// HelmRelease is the latest stored revision of one Helm release, reduced to
// what the API check needs.
type HelmRelease struct {
	Namespace string
	Name      string
	Revision  int
	Chart     string // "name-version"
	// Secret is the Secret the revision is stored in.
	Secret string
	// Objects are the rendered manifest's objects.
	Objects []helm.Resource
}

// maxReleaseBytes bounds a decompressed release (Helm caps them near 1MiB
// compressed; manifests compress well).
const maxReleaseBytes = 64 << 20

// DecodeHelmRelease reads a Secret's "release" value as Helm's secret
// driver stores it (base64 of gzipped JSON) and lists its manifest's objects.
func DecodeHelmRelease(namespace, secret string, data []byte) (HelmRelease, error) {
	raw, err := base64.StdEncoding.DecodeString(string(data))
	if err != nil {
		return HelmRelease{}, fmt.Errorf("release %s/%s: %w", namespace, secret, err)
	}
	if len(raw) > 2 && raw[0] == 0x1f && raw[1] == 0x8b {
		zr, err := gzip.NewReader(bytes.NewReader(raw))
		if err != nil {
			return HelmRelease{}, fmt.Errorf("release %s/%s: %w", namespace, secret, err)
		}
		if raw, err = io.ReadAll(io.LimitReader(zr, maxReleaseBytes)); err != nil {
			return HelmRelease{}, fmt.Errorf("release %s/%s: %w", namespace, secret, err)
		}
	}
	var rel release.Release
	if err := json.Unmarshal(raw, &rel); err != nil {
		return HelmRelease{}, fmt.Errorf("release %s/%s: %w", namespace, secret, err)
	}
	out := HelmRelease{Namespace: namespace, Name: rel.Name, Revision: rel.Version, Secret: secret}
	if rel.Namespace != "" {
		out.Namespace = rel.Namespace
	}
	if rel.Chart != nil && rel.Chart.Metadata != nil {
		out.Chart = rel.Chart.Metadata.Name + "-" + rel.Chart.Metadata.Version
	}
	// Without a REST mapper: namespaces come from the manifest or the
	// release; that is all the check needs.
	out.Objects = helm.ParseResources(rel.Manifest, out.Namespace, nil)
	return out, nil
}
