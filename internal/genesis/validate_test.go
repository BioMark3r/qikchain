package genesis

import (
	"strings"
	"testing"
)

func TestValidatePolygonEdgeSchema(t *testing.T) {
	validAddr := "0x1000000000000000000000000000000000000001"

	tests := []struct {
		name            string
		doc             map[string]any
		opts            ValidateOptions
		wantErr         bool
		wantWarning     bool
		containsErr     string
		containsWarning string
	}{
		{
			name: "pass minimal PoA",
			doc: map[string]any{
				"name":      "qikchain",
				"bootnodes": []any{},
				"genesis":   map[string]any{"gasLimit": "0x1", "alloc": map[string]any{validAddr: map[string]any{"balance": "1"}}},
				"params":    map[string]any{"chainID": float64(100), "minGasPrice": "0", "engine": map[string]any{"ibft": map[string]any{"type": "PoA"}}},
			},
			opts: ValidateOptions{Strict: true},
		},
		{
			name: "pass minimal PoS",
			doc: map[string]any{
				"genesis": map[string]any{"gasLimit": "0x1", "alloc": map[string]any{validAddr: map[string]any{"balance": "1"}}},
				"params":  map[string]any{"chainID": float64(100), "minGasPrice": "0", "engine": map[string]any{"ibft": map[string]any{"type": "PoS"}}},
			},
			opts: ValidateOptions{Strict: true},
		},
		{
			name: "fail missing ibft type",
			doc: map[string]any{
				"genesis": map[string]any{"gasLimit": "0x1", "alloc": map[string]any{validAddr: map[string]any{"balance": "1"}}},
				"params":  map[string]any{"chainID": float64(100), "engine": map[string]any{"ibft": map[string]any{}}},
			},
			opts:        ValidateOptions{Strict: true},
			wantErr:     true,
			containsErr: "params.engine.ibft.type is required",
		},
		{
			name: "fail invalid alloc address",
			doc: map[string]any{
				"genesis": map[string]any{"gasLimit": "0x1", "alloc": map[string]any{"0x123": map[string]any{"balance": "1"}}},
				"params":  map[string]any{"chainID": float64(100), "engine": map[string]any{"ibft": map[string]any{"type": "PoA"}}},
			},
			opts:        ValidateOptions{Strict: true},
			wantErr:     true,
			containsErr: "is not an address",
		},
		{
			name: "fail invalid alloc balance",
			doc: map[string]any{
				"genesis": map[string]any{"gasLimit": "0x1", "alloc": map[string]any{validAddr: map[string]any{"balance": "abc"}}},
				"params":  map[string]any{"chainID": float64(100), "engine": map[string]any{"ibft": map[string]any{"type": "PoA"}}},
			},
			opts:        ValidateOptions{Strict: true},
			wantErr:     true,
			containsErr: "balance must be numeric string",
		},
		{
			name: "warn on legacy consensus in non-strict",
			doc: map[string]any{
				"consensus": map[string]any{"type": "ibft"},
				"genesis":   map[string]any{"gasLimit": "0x1", "alloc": map[string]any{validAddr: map[string]any{"balance": "1"}}},
				"params":    map[string]any{"chainID": float64(100), "engine": map[string]any{"ibft": map[string]any{"type": "PoA"}}},
			},
			opts:            ValidateOptions{Strict: false},
			wantWarning:     true,
			containsWarning: "legacy top-level key(s) present",
		},
		{
			name: "fail on legacy consensus in strict",
			doc: map[string]any{
				"consensus": map[string]any{"type": "ibft"},
				"genesis":   map[string]any{"gasLimit": "0x1", "alloc": map[string]any{validAddr: map[string]any{"balance": "1"}}},
				"params":    map[string]any{"chainID": float64(100), "engine": map[string]any{"ibft": map[string]any{"type": "PoA"}}},
			},
			opts:        ValidateOptions{Strict: true},
			wantErr:     true,
			containsErr: "legacy top-level key(s) present",
		},
		{
			name: "pass legacy acceptance when ibft missing and enabled",
			doc: map[string]any{
				"consensus": map[string]any{"type": "ibft"},
				"genesis":   map[string]any{"gasLimit": "0x1", "alloc": map[string]any{validAddr: map[string]any{"balance": "1"}}},
				"params":    map[string]any{"chainID": float64(100), "engine": map[string]any{}},
			},
			opts:            ValidateOptions{Strict: false, AcceptLegacyConsensus: true},
			wantWarning:     true,
			containsWarning: "legacy consensus schema accepted",
		},
		{
			name: "fail legacy consensus when ibft missing and acceptance disabled",
			doc: map[string]any{
				"consensus": map[string]any{"type": "ibft"},
				"genesis":   map[string]any{"gasLimit": "0x1", "alloc": map[string]any{validAddr: map[string]any{"balance": "1"}}},
				"params":    map[string]any{"chainID": float64(100), "engine": map[string]any{}},
			},
			opts:        ValidateOptions{Strict: false, AcceptLegacyConsensus: false},
			wantErr:     true,
			containsErr: "params.engine.ibft must be an object",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			res := Validate(tt.doc, tt.opts)
			if tt.wantErr && len(res.Errors) == 0 {
				t.Fatalf("expected validation errors")
			}
			if !tt.wantErr && len(res.Errors) > 0 {
				t.Fatalf("expected no errors, got %v", res.Errors)
			}
			if tt.containsErr != "" && len(res.Errors) > 0 {
				found := false
				for _, err := range res.Errors {
					if strings.Contains(err.Error(), tt.containsErr) {
						found = true
						break
					}
				}
				if !found {
					t.Fatalf("expected error containing %q, got %v", tt.containsErr, res.Errors)
				}
			}
			if tt.wantWarning && len(res.Warnings) == 0 {
				t.Fatalf("expected validation warnings")
			}
			if tt.containsWarning != "" {
				found := false
				for _, warning := range res.Warnings {
					if strings.Contains(warning, tt.containsWarning) {
						found = true
						break
					}
				}
				if !found {
					t.Fatalf("expected warning containing %q, got %v", tt.containsWarning, res.Warnings)
				}
			}
		})
	}
}
