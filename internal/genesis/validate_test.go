package genesis

import (
	"strings"
	"testing"
)

func TestValidateChainAndEthereumGenesis(t *testing.T) {
	validAddr := "0x1000000000000000000000000000000000000001"
	eth := map[string]any{
		"alloc":          map[string]any{validAddr: map[string]any{"balance": "1"}},
		"gasLimit":       "0x1",
		"difficulty":     "0x1",
		"extraData":      "0x",
		"baseFeeEnabled": false,
	}
	chain := map[string]any{
		"name":      "qikchain",
		"bootnodes": []any{},
		"genesis":   "/tmp/genesis-eth.json",
		"params":    map[string]any{"chainID": float64(100), "minGasPrice": "0", "forks": map[string]any{}, "engine": map[string]any{"ibft": map[string]any{"type": "PoA"}}},
	}

	if res := ValidateEthereumGenesis(eth); len(res.Errors) > 0 {
		t.Fatalf("ethereum genesis should pass: %v", res.Errors)
	}
	if res := ValidateChainConfig(chain, ValidateOptions{Strict: true}); len(res.Errors) > 0 {
		t.Fatalf("chain config should pass: %v", res.Errors)
	}
}

func TestValidateCombinedFormatPasses(t *testing.T) {
	validAddr := "0x1000000000000000000000000000000000000001"
	combined := map[string]any{
		"genesis": map[string]any{"gasLimit": "0x1", "difficulty": "0x1", "extraData": "0x", "baseFeeEnabled": false, "alloc": map[string]any{validAddr: map[string]any{"balance": "1"}}},
		"params":  map[string]any{"chainID": float64(100), "forks": map[string]any{}, "engine": map[string]any{"ibft": map[string]any{"type": "PoA"}}},
	}
	res := ValidateChainConfig(combined, ValidateOptions{Strict: true})
	if len(res.Errors) > 0 {
		t.Fatalf("combined format should pass: %v", res.Errors)
	}
}

func TestValidateChainConfigRejectsMissingForks(t *testing.T) {
	doc := map[string]any{
		"genesis": map[string]any{"gasLimit": "0x1", "difficulty": "0x1", "extraData": "0x", "baseFeeEnabled": false, "alloc": map[string]any{}},
		"params":  map[string]any{"chainID": float64(100), "engine": map[string]any{"ibft": map[string]any{"type": "PoA"}}},
	}

	res := ValidateChainConfig(doc, ValidateOptions{Strict: true})
	found := false
	for _, err := range res.Errors {
		if strings.Contains(err.Error(), "params.forks must be a non-nil object") {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("expected params.forks error, got %v", res.Errors)
	}
}

func TestValidateEthereumGenesisMissingFieldsMessageLocation(t *testing.T) {
	res := ValidateEthereumGenesis(map[string]any{"alloc": map[string]any{}})
	if len(res.Errors) == 0 {
		t.Fatalf("expected validation errors")
	}
	want := "ethereum genesis: top-level gasLimit is required"
	found := false
	for _, err := range res.Errors {
		if strings.Contains(err.Error(), want) {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("expected contextual ethereum genesis error, got %v", res.Errors)
	}
}

func TestValidateChainConfigRejectsNonObjectForkValues(t *testing.T) {
	doc := map[string]any{
		"genesis": map[string]any{"gasLimit": "0x1", "difficulty": "0x1", "extraData": "0x", "baseFeeEnabled": false, "alloc": map[string]any{}},
		"params": map[string]any{
			"chainID": float64(100),
			"engine":  map[string]any{"ibft": map[string]any{"type": "PoA"}},
			"forks":   map[string]any{"london": float64(0), "istanbul": "0"},
		},
	}

	res := ValidateChainConfig(doc, ValidateOptions{Strict: true})
	if len(res.Errors) == 0 {
		t.Fatalf("expected validation errors")
	}
	if !containsError(res.Errors, "params.forks.london must be an object") {
		t.Fatalf("expected london object-shape error, got %v", res.Errors)
	}
	if !containsError(res.Errors, "params.forks.istanbul must be an object") {
		t.Fatalf("expected istanbul object-shape error, got %v", res.Errors)
	}
}

func containsError(errs []error, want string) bool {
	for _, err := range errs {
		if strings.Contains(err.Error(), want) {
			return true
		}
	}
	return false
}
