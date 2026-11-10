package columns

import "testing"

func TestConfigMapAndSecretSizes(t *testing.T) {
	cm := map[string]any{"data": map[string]any{"a": "héllo"}, "binaryData": map[string]any{"b": "AAECAw=="}} // 6 + 4 bytes
	sec := map[string]any{"data": map[string]any{"x": "c2VjcmV0", "y": "YQ=="}}                               // 6 + 1 bytes
	row := func(key string, obj map[string]any) []any {
		cells, errs := NewEvaluator(builtin[key]).Row(obj)
		for _, e := range errs {
			if e != nil {
				t.Fatal(e)
			}
		}
		return cells
	}
	if c := row("configmaps", cm); c[0] != 2 || c[1] != 10 {
		t.Fatalf("configmap keys/size = %v", c)
	}
	if c := row("secrets", sec); c[1] != 2 || c[2] != 7 {
		t.Fatalf("secret keys/size = %v", c)
	}
}
