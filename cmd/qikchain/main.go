package main

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(argv []string) int {
	if len(argv) == 0 {
		fmt.Println("qikchain: no command (try --help)")
		return 2
	}

	switch argv[0] {
	case "-h", "--help", "help":
		printHelp()
		return 0
	case "status":
		return cmdStatus(argv[1:])
	case "block":
		return cmdBlock(argv[1:])
	default:
		fmt.Fprintf(os.Stderr, "qikchain: unknown command %q (try --help)\n", argv[0])
		return 2
	}
}

func printHelp() {
	fmt.Println(`qikchain (WIP)

Usage:
  qikchain status --rpc http://127.0.0.1:8545
  qikchain block head --rpc http://127.0.0.1:8545

Flags:
  --rpc     JSON-RPC endpoint (required for commands that query a node)
  --timeout Request timeout (default 5s)
`)
}

func cmdStatus(args []string) int {
	fs := flag.NewFlagSet("status", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	rpc := fs.String("rpc", "", "JSON-RPC endpoint (e.g. http://127.0.0.1:8545)")
	timeout := fs.Duration("timeout", 5*time.Second, "request timeout")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *rpc == "" {
		fmt.Fprintln(os.Stderr, "status: --rpc is required")
		return 2
	}

	c := &rpcClient{url: *rpc, http: &http.Client{Timeout: *timeout}}

	chainIDHex, err := c.callString("eth_chainId")
	if err != nil {
		fmt.Fprintln(os.Stderr, "status: eth_chainId:", err)
		return 1
	}
	blockHex, err := c.callString("eth_blockNumber")
	if err != nil {
		fmt.Fprintln(os.Stderr, "status: eth_blockNumber:", err)
		return 1
	}
	peerHex, err := c.callString("net_peerCount")
	if err != nil {
		fmt.Fprintln(os.Stderr, "status: net_peerCount:", err)
		return 1
	}

	chainID, _ := hexToUint64(chainIDHex)
	blockNum, _ := hexToUint64(blockHex)
	peers, _ := hexToUint64(peerHex)

	fmt.Printf("rpc:        %s\n", *rpc)
	fmt.Printf("chainId:    %d (%s)\n", chainID, chainIDHex)
	fmt.Printf("blockHead:  %d (%s)\n", blockNum, blockHex)
	fmt.Printf("peerCount:  %d (%s)\n", peers, peerHex)
	return 0
}

func cmdBlock(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "block: expected subcommand (try: block head)")
		return 2
	}
	switch args[0] {
	case "head":
		return cmdBlockHead(args[1:])
	default:
		fmt.Fprintf(os.Stderr, "block: unknown subcommand %q\n", args[0])
		return 2
	}
}

func cmdBlockHead(args []string) int {
	fs := flag.NewFlagSet("block head", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	rpc := fs.String("rpc", "", "JSON-RPC endpoint (e.g. http://127.0.0.1:8545)")
	timeout := fs.Duration("timeout", 5*time.Second, "request timeout")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *rpc == "" {
		fmt.Fprintln(os.Stderr, "block head: --rpc is required")
		return 2
	}

	c := &rpcClient{url: *rpc, http: &http.Client{Timeout: *timeout}}
	blockHex, err := c.callString("eth_blockNumber")
	if err != nil {
		fmt.Fprintln(os.Stderr, "block head: eth_blockNumber:", err)
		return 1
	}
	blockNum, _ := hexToUint64(blockHex)
	fmt.Println(blockNum)
	return 0
}

type rpcClient struct {
	url  string
	http *http.Client
}

type rpcReq struct {
	JSONRPC string        `json:"jsonrpc"`
	ID      int           `json:"id"`
	Method  string        `json:"method"`
	Params  []interface{} `json:"params"`
}

type rpcResp struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      int             `json:"id"`
	Result  json.RawMessage `json:"result"`
	Error   *rpcErr         `json:"error,omitempty"`
}

type rpcErr struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (c *rpcClient) callString(method string) (string, error) {
	reqBody, _ := json.Marshal(rpcReq{
		JSONRPC: "2.0",
		ID:      1,
		Method:  method,
		Params:  []interface{}{},
	})

	req, err := http.NewRequest("POST", c.url, bytes.NewReader(reqBody))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.http.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	b, _ := io.ReadAll(resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("http %d: %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}

	var rr rpcResp
	if err := json.Unmarshal(b, &rr); err != nil {
		return "", err
	}
	if rr.Error != nil {
		return "", fmt.Errorf("rpc error %d: %s", rr.Error.Code, rr.Error.Message)
	}

	var s string
	if err := json.Unmarshal(rr.Result, &s); err != nil {
		return "", fmt.Errorf("unexpected result: %s", string(rr.Result))
	}
	return s, nil
}

func hexToUint64(h string) (uint64, error) {
	h = strings.TrimSpace(h)
	h = strings.TrimPrefix(h, "0x")
	if h == "" {
		return 0, nil
	}
	// allow odd length
	if len(h)%2 == 1 {
		h = "0" + h
	}
	b, err := hex.DecodeString(h)
	if err != nil {
		return 0, err
	}
	var n uint64
	for _, by := range b {
		n = (n << 8) | uint64(by)
	}
	return n, nil
}

