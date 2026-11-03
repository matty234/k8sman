package icons

import (
	"bytes"
	"net/url"
	"path"
	"sort"
	"strconv"
	"strings"

	"golang.org/x/net/html"
)

// IconLink is a candidate icon declared by a page's <link> tags.
type IconLink struct {
	URL  string
	Rel  string
	Size int  // largest declared (or assumed) edge in px
	SVG  bool // vector; the UI can't render these
}

// ParseIconLinks extracts <link rel="icon" | "shortcut icon" |
// "apple-touch-icon"> entries from an HTML document, resolving hrefs against
// page (and any <base href>). Raster icons come first, largest first; SVGs
// are kept at the end so callers can skip them.
func ParseIconLinks(page *url.URL, doc []byte) []IconLink {
	links, _ := parsePage(page, doc)
	return links
}

// parsePage returns the icon links and any <meta http-equiv="refresh"> URL.
func parsePage(page *url.URL, doc []byte) (out []IconLink, refresh *url.URL) {
	base := page
	z := html.NewTokenizer(bytes.NewReader(doc))
	seen := map[string]bool{}
loop:
	for {
		switch z.Next() {
		case html.ErrorToken:
			break loop
		case html.EndTagToken:
			if name, _ := z.TagName(); string(name) == "head" {
				break loop
			}
		case html.StartTagToken, html.SelfClosingTagToken:
			name, hasAttr := z.TagName()
			tag := string(name)
			if tag == "body" {
				break loop
			}
			if !hasAttr || (tag != "link" && tag != "base" && tag != "meta") {
				continue
			}
			attrs := map[string]string{}
			for {
				k, v, more := z.TagAttr()
				attrs[strings.ToLower(string(k))] = strings.TrimSpace(string(v))
				if !more {
					break
				}
			}
			if tag == "meta" {
				if strings.EqualFold(attrs["http-equiv"], "refresh") && refresh == nil {
					refresh = refreshURL(page, attrs["content"])
				}
				continue
			}
			if tag == "base" {
				if b, err := page.Parse(attrs["href"]); err == nil && attrs["href"] != "" {
					base = b
				}
				continue
			}
			rel := iconRel(attrs["rel"])
			href := attrs["href"]
			if rel == "" || href == "" || strings.HasPrefix(href, "data:") {
				continue
			}
			u, err := base.Parse(href)
			if err != nil || seen[u.String()] {
				continue
			}
			seen[u.String()] = true
			typ := strings.ToLower(attrs["type"])
			ext := strings.ToLower(path.Ext(u.Path))
			l := IconLink{URL: u.String(), Rel: rel, SVG: typ == "image/svg+xml" || ext == ".svg"}
			l.Size = largestSize(attrs["sizes"])
			if l.Size == 0 {
				switch {
				case rel == "apple-touch-icon":
					l.Size = 180 // the iOS default
				case ext == ".ico":
					l.Size = 32 // usually 16+32
				default:
					l.Size = 24 // unknown: below anything declared ≥32
				}
			}
			out = append(out, l)
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].SVG != out[j].SVG {
			return !out[i].SVG
		}
		return out[i].Size > out[j].Size
	})
	return out, refresh
}

// refreshURL parses a meta refresh content value: "0; url=https://…".
func refreshURL(page *url.URL, content string) *url.URL {
	_, rest, ok := strings.Cut(content, ";")
	if !ok {
		return nil
	}
	rest = strings.TrimSpace(rest)
	if len(rest) < 4 || !strings.EqualFold(rest[:4], "url=") {
		return nil
	}
	target := strings.Trim(strings.TrimSpace(rest[4:]), `"'`)
	u, err := page.Parse(target)
	if err != nil || target == "" {
		return nil
	}
	return u
}

// iconRel normalises a rel attribute to "icon" / "apple-touch-icon", or "".
// mask-icon (monochrome Safari pinned-tab SVG) is excluded.
func iconRel(rel string) string {
	isIcon := false
	for _, r := range strings.Fields(strings.ToLower(rel)) {
		switch r {
		case "apple-touch-icon", "apple-touch-icon-precomposed":
			return "apple-touch-icon"
		case "icon":
			isIcon = true
		}
	}
	if isIcon {
		return "icon"
	}
	return ""
}

func largestSize(sizes string) int {
	best := 0
	for _, s := range strings.Fields(strings.ToLower(sizes)) {
		w, h, ok := strings.Cut(s, "x")
		if !ok {
			continue
		}
		wi, err1 := strconv.Atoi(w)
		hi, err2 := strconv.Atoi(h)
		if err1 == nil && err2 == nil {
			best = max(best, min(wi, hi))
		}
	}
	return best
}
