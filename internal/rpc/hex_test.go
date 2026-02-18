package rpc

import "testing"

func TestHexToUint64RequiresPrefix(t *testing.T) {
	if _, err := HexToUint64("64"); err == nil {
		t.Fatalf("expected error for non-prefixed hex")
	}
}
