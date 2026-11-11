package plugins

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

// MaxPackageSize caps a plugin package (docs/PLUGINS.md §10).
const MaxPackageSize = 1 << 20

// packExts are the top-level file types a package holds.
var packExts = []string{".yaml", ".md", ".png", ".svg"}

// ReadManifest reads and checks dir's plugin.yaml, without compiling the
// kinds (use Validate for that). Any error diag fails it.
func ReadManifest(dir string) (*Manifest, error) {
	src, err := os.ReadFile(filepath.Join(dir, ManifestFile))
	if err != nil {
		return nil, err
	}
	m, diags := parseManifest(src)
	for _, d := range diags {
		if !d.Warning {
			return nil, d
		}
	}
	return m, nil
}

// Pack writes dir as a deterministic .tar.gz: top-level .yaml, .md, .png
// and .svg files only, sorted, with zero times and owners and mode 0644.
// The fixtures folder stays out; symlinks, other folders and other files
// are errors.
func Pack(dir string) ([]byte, error) {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var names []string
	for _, e := range ents {
		name := e.Name()
		switch {
		case e.Type()&os.ModeSymlink != 0:
			return nil, fmt.Errorf("%s: symlinks are not allowed", name)
		case e.IsDir():
			if name == FixtureDir || name == "tests" {
				continue
			}
			return nil, fmt.Errorf("%s: folders other than %s/ are not allowed", name, FixtureDir)
		case !e.Type().IsRegular():
			return nil, fmt.Errorf("%s: not a regular file", name)
		case !slices.Contains(packExts, strings.ToLower(filepath.Ext(name))):
			return nil, fmt.Errorf("%s: only %s files are allowed", name, strings.Join(packExts, ", "))
		}
		names = append(names, name)
	}
	if !slices.Contains(names, ManifestFile) {
		return nil, errors.New("no " + ManifestFile)
	}
	slices.Sort(names)
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	tw := tar.NewWriter(zw)
	for _, name := range names {
		b, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return nil, err
		}
		hdr := &tar.Header{Name: name, Mode: 0o644, Size: int64(len(b)), Typeflag: tar.TypeReg, Format: tar.FormatUSTAR}
		if err := tw.WriteHeader(hdr); err != nil {
			return nil, err
		}
		if _, err := tw.Write(b); err != nil {
			return nil, err
		}
	}
	if err := tw.Close(); err != nil {
		return nil, err
	}
	if err := zw.Close(); err != nil {
		return nil, err
	}
	if buf.Len() > MaxPackageSize {
		return nil, fmt.Errorf("package is %d bytes; the limit is %d", buf.Len(), MaxPackageSize)
	}
	return buf.Bytes(), nil
}
