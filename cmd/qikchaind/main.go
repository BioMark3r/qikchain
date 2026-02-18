package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/BioMark3r/qikchain/internal/rpc"
)

type output struct {
	RPC         string `json:"rpc"`
	Timestamp   string `json:"timestamp"`
	ChainID     uint64 `json:"chainId,omitempty"`
	ChainHex    string `json:"chainHex,omitempty"`
	BlockNumber uint64 `json:"blockNumber,omitempty"`
	BlockHex    string `json:"blockHex,omitempty"`
	PeerCount   uint64 `json:"peerCount,omitempty"`
	PeerHex     string `json:"peerHex,omitempty"`
	Error       string `json:"error,omitempty"`
}

type commonFlags struct {
	rpcURL  string
	timeout time.Duration
}

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(argv []string) int {
	if len(argv) == 0 {
		fmt.Fprintln(os.Stderr, "qikchaind: expected command: once|run")
		return 2
	}

	switch argv[0] {
	case "once":
		return cmdOnce(argv[1:])
	case "run":
		return cmdRun(argv[1:])
	case "-h", "--help", "help":
		printHelp()
		return 0
	default:
		fmt.Fprintf(os.Stderr, "qikchaind: unknown command %q\n", argv[0])
		return 2
	}
}

func printHelp() {
	fmt.Print(`Usage:
  qikchaind once --rpc <url> [--timeout 5s]
  qikchaind run --rpc <url> [--timeout 5s] [--interval 5s]

Commands:
  once    Poll one cycle and print one JSON line.
  run     Poll continuously and print JSON lines.
`)
}

func cmdOnce(args []string) int {
	flags, err := parseCommonFlags("once", args)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 2
	}

	c := rpc.NewClient(flags.rpcURL, flags.timeout)
	out, err := collect(c, flags.rpcURL)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	printJSON(out)
	return 0
}

func cmdRun(args []string) int {
	fs := flag.NewFlagSet("run", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	common := bindCommonFlags(fs)
	interval := fs.Duration("interval", 5*time.Second, "poll interval")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 0 {
		fmt.Fprintln(os.Stderr, "run: unexpected positional arguments")
		return 2
	}
	if *interval <= 0 {
		fmt.Fprintln(os.Stderr, "run: --interval must be > 0")
		return 2
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	c := rpc.NewClient(common.rpcURL, common.timeout)
	runCycle := func() {
		out, err := collect(c, common.rpcURL)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			printJSON(output{
				RPC:       common.rpcURL,
				Timestamp: time.Now().UTC().Format(time.RFC3339),
				Error:     err.Error(),
			})
			return
		}
		printJSON(out)
	}

	runCycle()

	ticker := time.NewTicker(*interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return 0
		case <-ticker.C:
			runCycle()
		}
	}
}

func parseCommonFlags(name string, args []string) (commonFlags, error) {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	common := bindCommonFlags(fs)
	if err := fs.Parse(args); err != nil {
		return common, err
	}
	if fs.NArg() != 0 {
		return common, fmt.Errorf("%s: unexpected positional arguments", name)
	}
	return common, nil
}

func bindCommonFlags(fs *flag.FlagSet) commonFlags {
	defaultRPC := os.Getenv("QIKCHAIN_RPC")
	if defaultRPC == "" {
		defaultRPC = "http://127.0.0.1:8545"
	}

	defaultTimeout := 5 * time.Second
	if v := os.Getenv("QIKCHAIN_TIMEOUT"); v != "" {
		d, err := time.ParseDuration(v)
		if err == nil {
			defaultTimeout = d
		}
	}

	common := commonFlags{}
	fs.StringVar(&common.rpcURL, "rpc", defaultRPC, "JSON-RPC endpoint")
	fs.DurationVar(&common.timeout, "timeout", defaultTimeout, "request timeout")
	return common
}

func collect(c *rpc.Client, rpcURL string) (output, error) {
	chainHex, err := c.CallString("eth_chainId")
	if err != nil {
		return output{}, fmt.Errorf("eth_chainId: %w", err)
	}
	blockHex, err := c.CallString("eth_blockNumber")
	if err != nil {
		return output{}, fmt.Errorf("eth_blockNumber: %w", err)
	}
	peerHex, err := c.CallString("net_peerCount")
	if err != nil {
		return output{}, fmt.Errorf("net_peerCount: %w", err)
	}

	chainID, err := rpc.HexToUint64(chainHex)
	if err != nil {
		return output{}, fmt.Errorf("eth_chainId decode: %w", err)
	}
	blockNumber, err := rpc.HexToUint64(blockHex)
	if err != nil {
		return output{}, fmt.Errorf("eth_blockNumber decode: %w", err)
	}
	peerCount, err := rpc.HexToUint64(peerHex)
	if err != nil {
		return output{}, fmt.Errorf("net_peerCount decode: %w", err)
	}

	return output{
		RPC:         rpcURL,
		Timestamp:   time.Now().UTC().Format(time.RFC3339),
		ChainID:     chainID,
		ChainHex:    chainHex,
		BlockNumber: blockNumber,
		BlockHex:    blockHex,
		PeerCount:   peerCount,
		PeerHex:     peerHex,
	}, nil
}

func printJSON(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return
	}
	fmt.Println(string(b))
}
