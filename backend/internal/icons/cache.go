package icons

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// DefaultCacheDir is ~/.cache/k8sman/icons.
func DefaultCacheDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".cache", "k8sman", "icons")
}

// Entry is a cached lookup: an image, or a remembered failure.
type Entry struct {
	OK          bool      `json:"ok"`
	URL         string    `json:"url,omitempty"`
	ContentType string    `json:"contentType,omitempty"`
	Error       string    `json:"error,omitempty"`
	FetchedAt   time.Time `json:"fetchedAt"`
	Data        []byte    `json:"-"`
}

// Cache stores entries in memory and under dir (<hash>.json + <hash>.img).
// Successes live for PositiveTTL, failures for NegativeTTL. An empty dir
// keeps the cache in memory only.
type Cache struct {
	dir         string
	PositiveTTL time.Duration
	NegativeTTL time.Duration
	now         func() time.Time

	mu  sync.Mutex
	mem map[string]Entry
}

// NewCache returns a cache rooted at dir with default TTLs (7 days for
// icons, 12 hours for misses).
func NewCache(dir string) *Cache {
	return &Cache{dir: dir, PositiveTTL: 7 * 24 * time.Hour, NegativeTTL: 12 * time.Hour, now: time.Now, mem: map[string]Entry{}}
}

func (c *Cache) file(key, ext string) string {
	sum := sha256.Sum256([]byte(key))
	return filepath.Join(c.dir, hex.EncodeToString(sum[:12])+ext)
}

func (c *Cache) fresh(e Entry) bool {
	ttl := c.NegativeTTL
	if e.OK {
		ttl = c.PositiveTTL
	}
	return c.now().Sub(e.FetchedAt) < ttl
}

// Get returns the entry for key. Expired entries are returned only when
// allowStale is set (used when remote fetching is disabled: an old icon is
// better than none, and serving it leaks nothing).
func (c *Cache) Get(key string, allowStale bool) (Entry, bool) {
	c.mu.Lock()
	e, ok := c.mem[key]
	c.mu.Unlock()
	if !ok && c.dir != "" {
		e, ok = c.load(key)
		if ok {
			c.mu.Lock()
			c.mem[key] = e
			c.mu.Unlock()
		}
	}
	if !ok || !(c.fresh(e) || (allowStale && e.OK)) {
		return Entry{}, false
	}
	return e, true
}

func (c *Cache) load(key string) (Entry, bool) {
	b, err := os.ReadFile(c.file(key, ".json"))
	if err != nil {
		return Entry{}, false
	}
	var e Entry
	if json.Unmarshal(b, &e) != nil {
		return Entry{}, false
	}
	if e.OK {
		if e.Data, err = os.ReadFile(c.file(key, ".img")); err != nil || len(e.Data) == 0 {
			return Entry{}, false
		}
	}
	return e, true
}

// Put records an entry (stamping FetchedAt) in memory and on disk. Disk
// errors are ignored: the cache is an optimisation.
func (c *Cache) Put(key string, e Entry) Entry {
	e.FetchedAt = c.now()
	c.mu.Lock()
	c.mem[key] = e
	c.mu.Unlock()
	if c.dir == "" {
		return e
	}
	if err := os.MkdirAll(c.dir, 0o755); err != nil {
		return e
	}
	if e.OK {
		if writeAtomic(c.file(key, ".img"), e.Data) != nil {
			return e
		}
	} else {
		_ = os.Remove(c.file(key, ".img"))
	}
	if b, err := json.Marshal(e); err == nil {
		_ = writeAtomic(c.file(key, ".json"), b)
	}
	return e
}

func writeAtomic(path string, b []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
