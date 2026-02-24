package edgecaps

import "testing"

func TestDetectFlagsPrometheusVariant(t *testing.T) {
	help := `Usage:
  polygon-edge server [flags]

Flags:
      --jsonrpc string
      --grpc-address string
      --prometheus string
      --max-inbound-peers uint64
      --max-outbound-peers uint64
`
	got := DetectFlags(help, []string{"prometheus", "metrics", "max-inbound-peers", "max-outbound-peers", "max-peers"})
	if !got["prometheus"] || got["metrics"] {
		t.Fatalf("unexpected prometheus/metrics detection: %#v", got)
	}
	if !got["max-inbound-peers"] || !got["max-outbound-peers"] || got["max-peers"] {
		t.Fatalf("unexpected peers detection: %#v", got)
	}
}

func TestDetectFlagsMetricsVariant(t *testing.T) {
	help := `Flags:
      --metrics string
      --libp2p string
      --secrets-config string
      --seal
      --max-peers uint64
`
	got := DetectFlags(help, []string{"prometheus", "metrics", "libp2p", "secrets-config", "seal", "max-peers"})
	if got["prometheus"] || !got["metrics"] {
		t.Fatalf("unexpected prometheus/metrics detection: %#v", got)
	}
	if !got["libp2p"] || !got["secrets-config"] || !got["seal"] || !got["max-peers"] {
		t.Fatalf("unexpected flag detection: %#v", got)
	}
}

func TestHasFlagTokenBoundary(t *testing.T) {
	help := "  --max-peers uint64\n  --max-peers-extra string"
	if !HasFlag(help, "max-peers") {
		t.Fatal("expected max-peers")
	}
	if HasFlag(help, "max") {
		t.Fatal("did not expect max")
	}
}
