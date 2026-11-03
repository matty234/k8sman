package icons

import (
	"context"
	"errors"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"syscall"
	"time"

	"golang.org/x/net/publicsuffix"
)

// MaxBytes caps any single download (HTML page or image).
const MaxBytes = 256 << 10

var errNotHTTPS = errors.New("only https URLs are fetched")

// Fetcher downloads pages and images over https with short timeouts, a size
// cap and no access to private/loopback addresses.
type Fetcher struct {
	Client *http.Client
}

// NewFetcher returns a Fetcher whose client refuses non-https redirects and
// connections to non-public IPs (so a CRD group can't be used to probe the
// local network).
func NewFetcher() *Fetcher {
	dialer := &net.Dialer{
		Timeout: 3 * time.Second,
		Control: func(network, address string, _ syscall.RawConn) error {
			host, _, err := net.SplitHostPort(address)
			if err != nil {
				return err
			}
			if ip := net.ParseIP(host); ip == nil || !publicIP(ip) {
				return fmt.Errorf("refusing to connect to non-public address %s", host)
			}
			return nil
		},
	}
	tr := &http.Transport{
		// No proxy: the public-address check must apply to the real target.
		Proxy:                 nil,
		DialContext:           dialer.DialContext,
		TLSHandshakeTimeout:   3 * time.Second,
		ResponseHeaderTimeout: 4 * time.Second,
		MaxIdleConns:          8,
		IdleConnTimeout:       30 * time.Second,
	}
	return &Fetcher{Client: &http.Client{Transport: tr, Timeout: 6 * time.Second, CheckRedirect: checkRedirect}}
}

func checkRedirect(req *http.Request, via []*http.Request) error {
	if req.URL.Scheme != "https" {
		return errNotHTTPS
	}
	if len(via) >= 5 {
		return errors.New("too many redirects")
	}
	return nil
}

func publicIP(ip net.IP) bool {
	return !(ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() ||
		ip.IsMulticast() || ip.IsUnspecified() || ip.IsInterfaceLocalMulticast() ||
		// 100.64.0.0/10 carrier-grade NAT
		(ip.To4() != nil && ip.To4()[0] == 100 && ip.To4()[1]&0xc0 == 64))
}

// Get fetches rawURL (https only) and returns the body, the media type, and
// the final URL after redirects. Bodies over MaxBytes are an error unless
// truncate is set (for HTML the <head> is all we need).
func (f *Fetcher) Get(ctx context.Context, rawURL, accept string, truncate bool) (body []byte, mediaType string, final *url.URL, err error) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return nil, "", nil, err
	}
	if u.Scheme != "https" || u.Host == "" {
		return nil, "", nil, errNotHTTPS
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, "", nil, err
	}
	req.Header.Set("Accept", accept)
	req.Header.Set("User-Agent", "k8sman-icon-fetcher/1")
	res, err := f.Client.Do(req)
	if err != nil {
		return nil, "", nil, err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return nil, "", nil, fmt.Errorf("GET %s: %s", u, res.Status)
	}
	if res.ContentLength > MaxBytes && !truncate {
		return nil, "", nil, fmt.Errorf("GET %s: too large (%d bytes)", u, res.ContentLength)
	}
	body, err = io.ReadAll(io.LimitReader(res.Body, MaxBytes+1))
	if err != nil {
		return nil, "", nil, err
	}
	if len(body) > MaxBytes {
		if !truncate {
			return nil, "", nil, fmt.Errorf("GET %s: larger than %d bytes", u, MaxBytes)
		}
		body = body[:MaxBytes]
	}
	mediaType, _, _ = mime.ParseMediaType(res.Header.Get("Content-Type"))
	return body, strings.ToLower(mediaType), res.Request.URL, nil
}

// imageTypeOK accepts image/* plus the generic types servers use for .ico.
func imageTypeOK(mt string) bool {
	return mt == "" || strings.HasPrefix(mt, "image/") || mt == "application/octet-stream" ||
		mt == "application/ico" || mt == "application/x-ico" || mt == "text/plain"
}

// FetchImage downloads and normalises an icon image.
func (f *Fetcher) FetchImage(ctx context.Context, rawURL string) ([]byte, string, error) {
	data, ct, _, err := f.fetchImage(ctx, rawURL)
	return data, ct, err
}

func (f *Fetcher) fetchImage(ctx context.Context, rawURL string) ([]byte, string, *url.URL, error) {
	body, mt, final, err := f.Get(ctx, rawURL, "image/png,image/x-icon,image/*;q=0.8", false)
	if err != nil {
		return nil, "", nil, err
	}
	if !imageTypeOK(mt) {
		return nil, "", nil, fmt.Errorf("%s: content type %q is not an image", rawURL, mt)
	}
	data, ct, err := Normalize(body)
	return data, ct, final, err
}

// sharedPlatforms host many organisations' pages, so their favicon says
// nothing about a project (aquasecurity.github.io redirects to
// github.com/aquasecurity, whose icon is GitHub's).
var sharedPlatforms = map[string]bool{
	"github.com": true, "gitlab.com": true, "bitbucket.org": true, "codeberg.org": true,
	"google.com": true, "medium.com": true, "sourceforge.net": true, "artifacthub.io": true,
	"npmjs.com": true, "pypi.org": true, "x.com": true, "twitter.com": true, "linkedin.com": true,
	"wordpress.com": true, "notion.site": true, "godaddy.com": true, "sedoparking.com": true,
}

// onSharedPlatform reports whether u is on a shared platform that domain
// itself doesn't belong to.
func onSharedPlatform(domain string, u *url.URL) bool {
	if u == nil {
		return false
	}
	reg, err := publicsuffix.EffectiveTLDPlusOne(u.Hostname())
	if err != nil || !sharedPlatforms[reg] {
		return false
	}
	own, _ := publicsuffix.EffectiveTLDPlusOne(domain)
	return own != reg
}

func isHTML(mt string) bool { return mt == "text/html" || mt == "application/xhtml+xml" || mt == "" }

// FetchFavicon finds the best icon for a website: the largest raster
// <link rel=icon|apple-touch-icon> on its home page (following one
// <meta http-equiv=refresh>), else /favicon.ico. It gives up when the site
// sends us to a shared platform such as github.com.
func (f *Fetcher) FetchFavicon(ctx context.Context, domain string) (data []byte, contentType, iconURL string, err error) {
	home := "https://" + domain + "/"
	page, mt, final, perr := f.Get(ctx, home, "text/html", true)
	var dnsErr *net.DNSError
	if errors.As(perr, &dnsErr) {
		return nil, "", "", perr // host doesn't exist: no point trying /favicon.ico
	}
	if perr == nil && isHTML(mt) {
		// Static redirect pages (argoproj.io → argoproj.github.io).
		if _, refresh := parsePage(final, page); refresh != nil && refresh.Scheme == "https" {
			if p2, mt2, f2, err := f.Get(ctx, refresh.String(), "text/html", true); err == nil {
				page, mt, final = p2, mt2, f2
			} else if onSharedPlatform(domain, refresh) {
				final = refresh
			}
		}
	}
	if onSharedPlatform(domain, final) {
		return nil, "", "", fmt.Errorf("%s redirects to %s", domain, final.Host)
	}
	var tried []string
	if perr == nil && isHTML(mt) {
		for i, l := range ParseIconLinks(final, page) {
			if l.SVG || i >= 4 {
				break
			}
			tried = append(tried, l.URL)
			if d, ct, fu, err := f.fetchImage(ctx, l.URL); err == nil && !onSharedPlatform(domain, fu) {
				return d, ct, l.URL, nil
			}
		}
	}
	base := home
	if final != nil && final.Scheme == "https" {
		base = (&url.URL{Scheme: "https", Host: final.Host, Path: "/"}).String()
	}
	for _, fav := range slices.Compact([]string{base + "favicon.ico", home + "favicon.ico"}) {
		if slices.Contains(tried, fav) {
			continue
		}
		if d, ct, fu, err := f.fetchImage(ctx, fav); err == nil && !onSharedPlatform(domain, fu) {
			return d, ct, fav, nil
		}
	}
	if perr != nil {
		return nil, "", "", perr
	}
	return nil, "", "", fmt.Errorf("no usable icon on %s", domain)
}
