package kapi

import "testing"

func TestPick(t *testing.T) {
	prefs := []string{"v1", "v1beta1"}
	served := func(vs ...string) func(string) bool {
		return func(v string) bool {
			for _, s := range vs {
				if s == v {
					return true
				}
			}
			return false
		}
	}
	for _, tc := range []struct {
		served []string
		want   string
	}{
		{[]string{"v1beta1", "v1"}, "v1"}, // newest served wins
		{[]string{"v1beta1"}, "v1beta1"},  // falls back in order
		{[]string{"v2alpha1"}, ""},        // nothing we know
	} {
		if got := Pick(prefs, served(tc.served...)); got != tc.want {
			t.Errorf("Pick with %v served = %q, want %q", tc.served, got, tc.want)
		}
	}
}
