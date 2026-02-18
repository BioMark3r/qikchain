package cli

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"
)

const (
	defaultRPC     = "http://127.0.0.1:8545"
	defaultTimeout = 5 * time.Second
)

type Config struct {
	RPCURL  string
	Timeout time.Duration
	JSON    bool
}

func NewRootCmd() *cobra.Command {
	cfg := &Config{}

	root := &cobra.Command{
		Use:   "qikchain",
		Short: "Qikchain CLI for chain status and block head queries",
		Long:  "qikchain provides simple commands for querying JSON-RPC status and block head data.",
	}

	root.SilenceUsage = true
	root.SilenceErrors = true

	root.PersistentFlags().StringVar(&cfg.RPCURL, "rpc", defaultRPCFromEnv(), "JSON-RPC endpoint URL")
	root.PersistentFlags().DurationVar(&cfg.Timeout, "timeout", defaultTimeoutFromEnv(), "RPC request timeout")
	root.PersistentFlags().BoolVar(&cfg.JSON, "json", false, "Output JSON")

	root.AddCommand(newStatusCmd(cfg))
	root.AddCommand(newBlockCmd(cfg))
	root.InitDefaultCompletionCmd()

	return root
}

func Execute() {
	if err := NewRootCmd().Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(classifyError(err))
	}
}

func classifyError(err error) int {
	if err == nil {
		return 0
	}

	if errors.Is(err, flag.ErrHelp) || strings.Contains(err.Error(), cobra.ShellCompRequestCmd) {
		return 2
	}

	msg := err.Error()
	usageMarkers := []string{
		"unknown command",
		"unknown shorthand flag",
		"unknown flag",
		"required flag",
		"accepts ",
		"invalid argument",
		"argument",
	}
	for _, marker := range usageMarkers {
		if strings.Contains(msg, marker) {
			return 2
		}
	}

	return 1
}

func defaultRPCFromEnv() string {
	if rpc := os.Getenv("QIKCHAIN_RPC"); rpc != "" {
		return rpc
	}
	return defaultRPC
}

func defaultTimeoutFromEnv() time.Duration {
	raw := os.Getenv("QIKCHAIN_TIMEOUT")
	if raw == "" {
		return defaultTimeout
	}

	timeout, err := time.ParseDuration(raw)
	if err == nil {
		return timeout
	}

	seconds, err := strconv.Atoi(raw)
	if err == nil && seconds > 0 {
		return time.Duration(seconds) * time.Second
	}

	return defaultTimeout
}
