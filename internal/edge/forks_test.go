package edge

import "testing"

func TestFilterSupportedForks(t *testing.T) {
	desired := []string{"homestead", "london", "txHashWithType"}
	supported := []string{"homestead", "istanbul"}
	got := FilterSupportedForks(desired, supported)
	if len(got) != 1 || got[0] != "homestead" {
		t.Fatalf("unexpected filtered forks: %#v", got)
	}
}

func TestDetectSupportedForksFallback(t *testing.T) {
	got, source := DetectSupportedForks(t.TempDir())
	if source != "fallback" {
		t.Fatalf("expected fallback source, got %s", source)
	}
	if len(got) == 0 {
		t.Fatalf("expected non-empty fallback list")
	}
}
