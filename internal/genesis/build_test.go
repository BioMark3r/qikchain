package genesis

import (
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
	opts := BuildOptions{
		Consensus:          "poa",
		Env:                "devnet",
		TemplatePath:       "../../config/genesis.template.json",
		OverlayDir:         "../../config/consensus",
		TokenPath:          "../../config/token.json",
		AllocationsPath:    "../../config/allocations/devnet.json",
		ChainID:            100,
		BlockGasLimit:      "0x1c9c380",
		MinGasPrice:        "0",
		BaseFeeEnabled:     false,
		POSDeploymentsPath: deploy,
		Pretty:             true,
		Strict:             false,
	}
	a, err := Build(opts)
	if err != nil {
		t.Fatal(err)
	}
	b, err := Build(opts)
	if err != nil {
		t.Fatal(err)
	}
	if string(a.GenesisJSON) != string(b.GenesisJSON) {
		t.Fatalf("genesis bytes differ")
	}
}

func TestAllocOrderingDeterministic(t *testing.T) {
	cfg1 := config.AllocationConfig{
		Meta: config.AllocationMeta{Unit: "wei", Decimals: 18, Token: "QIK"},
		Buckets: config.BucketMap{
			"a": {Address: "0x1000000000000000000000000000000000000002", Amount: "1"},
			"b": {Address: "0x1000000000000000000000000000000000000001", Amount: "2"},
		},
		Operators: []config.AllocationEntry{{Address: "0x1000000000000000000000000000000000000003", Amount: "3"}},
		Deployer:  config.AllocationEntry{Address: "0x1000000000000000000000000000000000000004", Amount: "4"},
	}
	cfg2 := cfg1
	cfg2.Buckets = config.BucketMap{
		"b": {Address: "0x1000000000000000000000000000000000000001", Amount: "2"},
		"a": {Address: "0x1000000000000000000000000000000000000002", Amount: "1"},
	}
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
	opts := BuildOptions{
		Consensus:          "pos",
		Env:                "devnet",
		TemplatePath:       "../../config/genesis.template.json",
		OverlayDir:         "../../config/consensus",
		TokenPath:          "../../config/token.json",
		AllocationsPath:    "../../config/allocations/devnet.json",
		ChainID:            100,
		BlockGasLimit:      "0x1c9c380",
		MinGasPrice:        "0",
		BaseFeeEnabled:     false,
		POSDeploymentsPath: filepath.Join(t.TempDir(), "missing.json"),
		Pretty:             true,
		Strict:             false,
	}
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
