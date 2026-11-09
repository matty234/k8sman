package upgrade

import (
	"fmt"
	"regexp"
	"strconv"
)

// Version is a Kubernetes minor release, e.g. 1.32. The zero Version means
// "none" (an API never removed, a version that couldn't be parsed).
type Version struct{ Major, Minor int }

// V is Version{1, minor}.
func V(minor int) Version { return Version{1, minor} }

var versionRE = regexp.MustCompile(`^v?(\d+)\.(\d+)`)

// ParseVersion reads the major and minor of "v1.31.4-eks-1234", "1.31",
// "v1.30.2+k3s1" and the like.
func ParseVersion(s string) (Version, bool) {
	m := versionRE.FindStringSubmatch(s)
	if m == nil {
		return Version{}, false
	}
	maj, err1 := strconv.Atoi(m[1])
	mnr, err2 := strconv.Atoi(m[2])
	if err1 != nil || err2 != nil {
		return Version{}, false
	}
	return Version{maj, mnr}, true
}

// IsZero reports whether v is "none".
func (v Version) IsZero() bool { return v == Version{} }

func (v Version) String() string {
	if v.IsZero() {
		return ""
	}
	return fmt.Sprintf("%d.%d", v.Major, v.Minor)
}

// Plus is v moved n minors on (n may be negative).
func (v Version) Plus(n int) Version { return Version{v.Major, v.Minor + n} }

// Before reports whether v is an earlier release than o.
func (v Version) Before(o Version) bool {
	if v.Major != o.Major {
		return v.Major < o.Major
	}
	return v.Minor < o.Minor
}

// AtMost reports whether v is o or earlier.
func (v Version) AtMost(o Version) bool { return !o.Before(v) }

// Behind is how many minors v is behind o (negative when ahead).
func (v Version) Behind(o Version) int {
	if v.Major != o.Major {
		return (o.Major - v.Major) * 100
	}
	return o.Minor - v.Minor
}

// MarshalText writes "1.32" (JSON strings).
func (v Version) MarshalText() ([]byte, error) { return []byte(v.String()), nil }
