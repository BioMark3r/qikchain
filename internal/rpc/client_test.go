package rpc

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/ethereum/go-ethereum/common"
)

type rpcReq struct {
	Method string `json:"method"`
}

type rpcResp struct {
	JSONRPC string `json:"jsonrpc"`
	ID      int    `json:"id"`
	Result  any    `json:"result,omitempty"`
	Error   any    `json:"error,omitempty"`
}

func TestStatus(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer r.Body.Close()
		var req rpcReq
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("decode request: %v", err)
		}

		resp := rpcResp{JSONRPC: "2.0", ID: 1}
		switch req.Method {
		case "eth_chainId":
			resp.Result = "0x89"
		case "eth_blockNumber":
			resp.Result = "0x2a"
		case "web3_clientVersion":
			resp.Result = "polygon-edge/test"
		default:
			t.Fatalf("unexpected method: %s", req.Method)
		}

		if err := json.NewEncoder(w).Encode(resp); err != nil {
			t.Fatalf("encode response: %v", err)
		}
	}))
	defer srv.Close()

	c, err := Dial(srv.URL)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer c.Close()

	status, err := c.Status(context.Background())
	if err != nil {
		t.Fatalf("status: %v", err)
	}

	if status.ChainID != "137" {
		t.Fatalf("got chain id %s", status.ChainID)
	}
	if status.BlockNumber != 42 {
		t.Fatalf("got block number %d", status.BlockNumber)
	}
	if status.ClientVersion != "polygon-edge/test" {
		t.Fatalf("got client version %s", status.ClientVersion)
	}
}

func TestBalanceAt(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer r.Body.Close()
		var req rpcReq
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("decode request: %v", err)
		}
		if req.Method != "eth_getBalance" {
			t.Fatalf("unexpected method: %s", req.Method)
		}

		resp := rpcResp{JSONRPC: "2.0", ID: 1, Result: "0xde0b6b3a7640000"}
		if err := json.NewEncoder(w).Encode(resp); err != nil {
			t.Fatalf("encode response: %v", err)
		}
	}))
	defer srv.Close()

	c, err := Dial(srv.URL)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer c.Close()

	bal, err := c.BalanceAt(context.Background(), common.Address{}, "latest")
	if err != nil {
		t.Fatalf("balance: %v", err)
	}

	if bal.String() != "1000000000000000000" {
		t.Fatalf("unexpected balance: %s", bal.String())
	}
}
