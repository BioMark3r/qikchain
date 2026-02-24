package edgecaps

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/BioMark3r/qikchain/internal/edge"
)

type Report struct {
	EdgeBin        string          `json:"edgeBin"`
	EdgeVersion    string          `json:"edgeVersion"`
	ServerFlags    map[string]bool `json:"serverFlags"`
	GenesisFlags   map[string]bool `json:"genesisFlags"`
	SupportedForks []string        `json:"supportedForks"`
	Timestamp      string          `json:"timestamp"`
	EdgeSHA256     string          `json:"edgeSha256,omitempty"`
}

var serverFlagNames = []string{"prometheus", "metrics", "jsonrpc", "grpc-address", "libp2p", "secrets-config", "seal", "max-peers", "max-inbound-peers", "max-outbound-peers"}

var genesisFlagNames = []string{"consensus", "pos", "ibft-validator-type", "validators", "validators-path", "validators-prefix", "block-time", "block-gas-limit", "chain-id", "premine"}

func Collect(ctx context.Context, edgeBin string, timeout time.Duration) (Report, error) {
	resolved, err := resolveEdgeBinary(edgeBin)
	if err != nil {
		return Report{}, err
	}

	version := strings.TrimSpace(firstVersion(ctx, timeout, resolved))
	serverHelp, _ := run(ctx, timeout, resolved, "server", "--help")
	genesisHelp, _ := run(ctx, timeout, resolved, "genesis", "--help")

	root, _ := os.Getwd()
	forks, _ := edge.DetectSupportedForks(root)

	report := Report{
		EdgeBin:        resolved,
		EdgeVersion:    version,
		ServerFlags:    DetectFlags(serverHelp, serverFlagNames),
		GenesisFlags:   DetectFlags(genesisHelp, genesisFlagNames),
		SupportedForks: forks,
		Timestamp:      time.Now().UTC().Format(time.RFC3339),
	}

	if sum, err := fileSHA256(resolved); err == nil {
		report.EdgeSHA256 = sum
	}

	return report, nil
}

func resolveEdgeBinary(path string) (string, error) {
	if strings.TrimSpace(path) == "" {
		path = "./bin/polygon-edge"
	}
	resolved, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	st, err := os.Stat(resolved)
	if err != nil {
		return "", err
	}
	if st.IsDir() {
		return "", &os.PathError{Op: "exec", Path: resolved, Err: os.ErrInvalid}
	}
	if st.Mode()&0o111 == 0 {
		return "", &os.PathError{Op: "exec", Path: resolved, Err: os.ErrPermission}
	}
	return resolved, nil
}

func firstVersion(ctx context.Context, timeout time.Duration, bin string) string {
	attempts := [][]string{{"version"}, {"--version"}, {"version", "--json"}}
	for _, args := range attempts {
		out, err := run(ctx, timeout, bin, args...)
		if err == nil {
			trimmed := strings.TrimSpace(out)
			if trimmed != "" {
				return firstLine(trimmed)
			}
		}
	}
	return ""
}

func run(parent context.Context, timeout time.Duration, bin string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, args...)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

func fileSHA256(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:]), nil
}
