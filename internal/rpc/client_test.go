package rpc

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestCallString(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer r.Body.Close()
		var req map[string]any
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("decode request: %v", err)
		}
		if req["method"] != "eth_blockNumber" {
			t.Fatalf("unexpected method: %v", req["method"])
		}

		_ = json.NewEncoder(w).Encode(map[string]any{
			"jsonrpc": "2.0",
			"id":      1,
			"result":  "0x2a",
		})
	}))
	defer srv.Close()

	client := NewClient(srv.URL, 2*time.Second)
	got, err := client.CallString("eth_blockNumber")
	if err != nil {
		t.Fatalf("CallString: %v", err)
	}
	if got != "0x2a" {
		t.Fatalf("got %q", got)
	}
}

func TestHexToUint64(t *testing.T) {
	got, err := HexToUint64("0x64")
	if err != nil {
		t.Fatalf("HexToUint64: %v", err)
	}
	if got != 100 {
		t.Fatalf("got %d", got)
	}
}
