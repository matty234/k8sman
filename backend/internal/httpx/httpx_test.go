package httpx

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestDecodeJSONRejectsBadAndOversizedBodies(t *testing.T) {
	type body struct{ A string }
	for name, in := range map[string]string{"bad": "{nope", "large": `{"A":"` + strings.Repeat("x", 100) + `"}`} {
		rec := httptest.NewRecorder()
		_, ok := DecodeJSON[body](rec, httptest.NewRequest("POST", "/", strings.NewReader(in)), 32)
		if ok || rec.Code != http.StatusBadRequest {
			t.Errorf("%s: ok=%v code=%d", name, ok, rec.Code)
		}
	}
	rec := httptest.NewRecorder()
	if v, ok := DecodeJSON[body](rec, httptest.NewRequest("POST", "/", strings.NewReader(`{"A":"b"}`)), 32); !ok || v.A != "b" {
		t.Errorf("good body: %v %v", v, ok)
	}
}
