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
	opts := BuildOptions{Consensus: "poa", Env: "devnet", TemplatePath: "../../config/genesis.template.json", OverlayDir: "../../config/consensus", TokenPath: "../../config/token.json", AllocationsPath: "../../config/allocations/devnet.json", ChainID: 100, GasLimit: "0x1c9c380", Difficulty: "0x1", ExtraData: "0x", MinGasPrice: "0", BaseFeeEnabled: false, POSDeploymentsPath: deploy, Pretty: true, Strict: false}
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
	opts := BuildOptions{Consensus: "pos", Env: "devnet", TemplatePath: "../../config/genesis.template.json", OverlayDir: "../../config/consensus", TokenPath: "../../config/token.json", AllocationsPath: "../../config/allocations/devnet.json", ChainID: 100, GasLimit: "0x1c9c380", Difficulty: "0x1", ExtraData: "0x", MinGasPrice: "0", BaseFeeEnabled: false, POSDeploymentsPath: filepath.Join(t.TempDir(), "missing.json"), Pretty: true, Strict: false}
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
	opts := BuildOptions{Consensus: "poa", Env: "devnet", TemplatePath: "../../config/genesis.template.json", OverlayDir: "../../config/consensus", TokenPath: "../../config/token.json", AllocationsPath: "../../config/allocations/devnet.json", ChainID: 100, GasLimit: "0x1c9c380", Difficulty: "0x1", ExtraData: "0x", MinGasPrice: "0", BaseFeeEnabled: false, Pretty: true, Strict: true, OutCombinedPath: filepath.Join(tmp, "build", "genesis.json"), OutChainPath: chainOut, OutGenesisPath: genOut, MetadataOutPath: filepath.Join(tmp, "build", "meta.json")}
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
	if gas, ok := ethDoc["gasLimit"].(string); !ok || gas == "" {
		t.Fatalf("expected gasLimit in ethereum genesis")
	}
	if got, _ := ethDoc["difficulty"].(string); got != "0x1" {
		t.Fatalf("expected default difficulty 0x1, got %q", got)
	}
	if got, _ := ethDoc["extraData"].(string); got != "0x" {
		t.Fatalf("expected default extraData 0x, got %q", got)
	}
	if got, _ := ethDoc["baseFeeEnabled"].(bool); got {
		t.Fatalf("expected default baseFeeEnabled false")
	}
}

func TestGenesisBuildWritesCombinedOutput(t *testing.T) {
	tmp := t.TempDir()
	combinedOut := filepath.Join(tmp, "build", "genesis.json")
	opts := BuildOptions{Consensus: "poa", Env: "devnet", TemplatePath: "../../config/genesis.template.json", OverlayDir: "../../config/consensus", TokenPath: "../../config/token.json", AllocationsPath: "../../config/allocations/devnet.json", ChainID: 100, GasLimit: "0x1c9c380", Difficulty: "0x1", ExtraData: "0x", MinGasPrice: "0", BaseFeeEnabled: false, Pretty: true, Strict: true, OutCombinedPath: combinedOut, MetadataOutPath: filepath.Join(tmp, "build", "meta.json")}
	res, err := Build(opts)
	if err != nil {
		t.Fatal(err)
	}
	if err := WriteOutputs(opts, res); err != nil {
		t.Fatal(err)
	}
	combinedBytes, err := os.ReadFile(combinedOut)
	if err != nil {
		t.Fatal(err)
	}
	var combinedDoc map[string]any
	if err := json.Unmarshal(combinedBytes, &combinedDoc); err != nil {
		t.Fatal(err)
	}
	genesis, ok := combinedDoc["genesis"].(map[string]any)
	if !ok {
		t.Fatalf("combined genesis must embed genesis object")
	}
	params, ok := combinedDoc["params"].(map[string]any)
	if !ok {
		t.Fatalf("combined output must include params object")
	}
	forks, ok := params["forks"].(map[string]any)
	if !ok || forks == nil {
		t.Fatalf("combined output must include params.forks object")
	}
	for _, k := range []string{"homestead", "byzantium", "constantinople", "petersburg", "istanbul", "london", "eip150", "eip155", "eip158", "quorumCalcAlignment", "txHashWithType", "londonFix"} {
		rawFork, ok := forks[k]
		if !ok {
			t.Fatalf("expected devnet fork %s", k)
		}
		forkObj, ok := rawFork.(map[string]any)
		if !ok || forkObj == nil {
			t.Fatalf("expected params.forks.%s to be object, got %T", k, rawFork)
		}
		if _, ok := forkObj["block"].(float64); !ok {
			t.Fatalf("expected params.forks.%s.block to be numeric", k)
		}
	}
	if gas, ok := genesis["gasLimit"].(string); !ok || gas == "" {
		t.Fatalf("expected gasLimit in embedded genesis")
	}
}

func TestGenesisBuildFiltersUnsupportedForks(t *testing.T) {
	opts := BuildOptions{Consensus: "poa", Env: "devnet", TemplatePath: "../../config/genesis.template.json", OverlayDir: "../../config/consensus", TokenPath: "../../config/token.json", AllocationsPath: "../../config/allocations/devnet.json", ChainID: 100, GasLimit: "0x1c9c380", Difficulty: "0x1", ExtraData: "0x", MinGasPrice: "0", BaseFeeEnabled: false, Pretty: true, Strict: true, SupportedForks: []string{"homestead", "istanbul"}}
	res, err := Build(opts)
	if err != nil {
		t.Fatal(err)
	}
	var combinedDoc map[string]any
	if err := json.Unmarshal(res.GenesisJSON, &combinedDoc); err != nil {
		t.Fatal(err)
	}
	params, ok := combinedDoc["params"].(map[string]any)
	if !ok {
		t.Fatalf("combined output must include params object")
	}
	forks, ok := params["forks"].(map[string]any)
	if !ok || forks == nil {
		t.Fatalf("combined output must include params.forks object")
	}
	if len(forks) != 2 {
		t.Fatalf("expected only supported forks to remain, got %d", len(forks))
	}
	if _, ok := forks["homestead"]; !ok {
		t.Fatalf("expected homestead")
	}
	if _, ok := forks["istanbul"]; !ok {
		t.Fatalf("expected istanbul")
	}
	if _, ok := forks["london"]; ok {
		t.Fatalf("did not expect london")
	}
}
