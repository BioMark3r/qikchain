package genesis

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/BioMark3r/qikchain/internal/allocations"
	"github.com/BioMark3r/qikchain/internal/config"
)

func TestBuildDeterministicSameInputs(t *testing.T) {
	tmp := t.TempDir()
	deploy := filepath.Join(tmp, "pos.json")
	if err := os.WriteFile(deploy, []byte(`{"staking":{"address":"0x10000000000000000000000000000000000000aa"},"validatorSet":{"address":"0x10000000000000000000000000000000000000bb"}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	opts := BuildOptions{Consensus: "poa", Env: "devnet", TemplatePath: "../../config/genesis.template.json", OverlayDir: "../../config/consensus", TokenPath: "../../config/token.json", AllocationsPath: "../../config/allocations/devnet.json", ChainID: 100, BlockGasLimit: "0x1c9c380", MinGasPrice: "0", BaseFeeEnabled: false, POSDeploymentsPath: deploy, Pretty: true, Strict: false}
	a, err := Build(opts)
	if err != nil {
		t.Fatal(err)
	}
	b, err := Build(opts)
	if err != nil {
		t.Fatal(err)
	}
	if string(a.ChainJSON) != string(b.ChainJSON) || string(a.EthGenesisJSON) != string(b.EthGenesisJSON) {
		t.Fatalf("build bytes differ")
	}
}

func TestAllocOrderingDeterministic(t *testing.T) {
	cfg1 := config.AllocationConfig{Meta: config.AllocationMeta{Unit: "wei", Decimals: 18, Token: "QIK"}, Buckets: config.BucketMap{"a": {Address: "0x1000000000000000000000000000000000000002", Amount: "1"}, "b": {Address: "0x1000000000000000000000000000000000000001", Amount: "2"}}, Operators: []config.AllocationEntry{{Address: "0x1000000000000000000000000000000000000003", Amount: "3"}}, Deployer: config.AllocationEntry{Address: "0x1000000000000000000000000000000000000004", Amount: "4"}}
	cfg2 := cfg1
	cfg2.Buckets = config.BucketMap{"b": {Address: "0x1000000000000000000000000000000000000001", Amount: "2"}, "a": {Address: "0x1000000000000000000000000000000000000002", Amount: "1"}}
	a, _, err := renderAllocForTest(cfg1)
	if err != nil {
		t.Fatal(err)
	}
	b, _, err := renderAllocForTest(cfg2)
	if err != nil {
		t.Fatal(err)
	}
	if string(a) != string(b) {
		t.Fatalf("alloc differs")
	}
}

func TestPOSBuildFailsWithoutDeploymentsUnlessAllowed(t *testing.T) {
	opts := BuildOptions{Consensus: "pos", Env: "devnet", TemplatePath: "../../config/genesis.template.json", OverlayDir: "../../config/consensus", TokenPath: "../../config/token.json", AllocationsPath: "../../config/allocations/devnet.json", ChainID: 100, BlockGasLimit: "0x1c9c380", MinGasPrice: "0", BaseFeeEnabled: false, POSDeploymentsPath: filepath.Join(t.TempDir(), "missing.json"), Pretty: true, Strict: false}
	if _, err := Build(opts); err == nil {
		t.Fatal("expected error for missing pos deployments")
	}
	opts.AllowMissingPOSAddresses = true
	opts.AcceptLegacyConsensus = true
	if _, err := Build(opts); err != nil {
		t.Fatal(err)
	}
}

func renderAllocForTest(cfg config.AllocationConfig) ([]byte, string, error) {
	return allocations.RenderAllocMapAndTotal(cfg)
}

func TestGenesisBuildSplitOutputsAndWrite(t *testing.T) {
	tmp := t.TempDir()
	chainOut := filepath.Join(tmp, "build", "chain.json")
	genOut := filepath.Join(tmp, "build", "genesis-eth.json")
	opts := BuildOptions{Consensus: "poa", Env: "devnet", TemplatePath: "../../config/genesis.template.json", OverlayDir: "../../config/consensus", TokenPath: "../../config/token.json", AllocationsPath: "../../config/allocations/devnet.json", ChainID: 100, BlockGasLimit: "0x1c9c380", MinGasPrice: "0", BaseFeeEnabled: false, Pretty: true, Strict: true, OutChainPath: chainOut, OutGenesisPath: genOut, MetadataOutPath: filepath.Join(tmp, "build", "meta.json")}
	res, err := Build(opts)
	if err != nil {
		t.Fatal(err)
	}
	if err := WriteOutputs(opts, res); err != nil {
		t.Fatal(err)
	}
	chainBytes, err := os.ReadFile(chainOut)
	if err != nil {
		t.Fatal(err)
	}
	ethBytes, err := os.ReadFile(genOut)
	if err != nil {
		t.Fatal(err)
	}

	var chainDoc map[string]any
	if err := json.Unmarshal(chainBytes, &chainDoc); err != nil {
		t.Fatal(err)
	}
	genPath, ok := chainDoc["genesis"].(string)
	if !ok {
		t.Fatalf("chain genesis must be string")
	}
	wantAbs, _ := filepath.Abs(genOut)
	if genPath != wantAbs {
		t.Fatalf("chain genesis path mismatch: got %s want %s", genPath, wantAbs)
	}

	var ethDoc map[string]any
	if err := json.Unmarshal(ethBytes, &ethDoc); err != nil {
		t.Fatal(err)
	}
	if _, ok := ethDoc["alloc"].(map[string]any); !ok {
		t.Fatalf("expected alloc in ethereum genesis")
	}
	if _, ok := ethDoc["gasLimit"].(string); !ok {
		t.Fatalf("expected gasLimit in ethereum genesis")
	}
}
