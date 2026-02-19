package allocations

import (
	"testing"

	"github.com/BioMark3r/qikchain/internal/config"
)

func validConfig() config.AllocationConfig {
	return config.AllocationConfig{
		Meta: config.AllocationMeta{Unit: "wei", Decimals: 18, Token: "QIK"},
		Buckets: config.BucketMap{
			"treasury": {Address: "0x1000000000000000000000000000000000000001", Amount: "100"},
			"faucet":   {Address: "0x1000000000000000000000000000000000000002", Amount: "200"},
		},
		Operators: []config.AllocationEntry{{Address: "0x1000000000000000000000000000000000000003", Amount: "300"}},
		Deployer:  config.AllocationEntry{Address: "0x1000000000000000000000000000000000000004", Amount: "400"},
	}
}

func TestVerifyRejectsCases(t *testing.T) {
	t.Run("missing fields", func(t *testing.T) {
		cfg := validConfig()
		cfg.Deployer.Address = ""
		_, errs := Verify(cfg, VerifyOptions{})
		if len(errs) == 0 {
			t.Fatal("expected error")
		}
	})

	t.Run("wrong meta", func(t *testing.T) {
		cfg := validConfig()
		cfg.Meta.Token = "NOTQIK"
		cfg.Meta.Unit = "gwei"
		cfg.Meta.Decimals = 8
		_, errs := Verify(cfg, VerifyOptions{})
		if len(errs) < 3 {
			t.Fatalf("expected meta errors, got %d", len(errs))
		}
	})

	t.Run("invalid address", func(t *testing.T) {
		cfg := validConfig()
		cfg.Buckets["treasury"] = config.AllocationEntry{Address: "0x123", Amount: "1"}
		_, errs := Verify(cfg, VerifyOptions{})
		if len(errs) == 0 {
			t.Fatal("expected invalid address error")
		}
	})

	t.Run("zero address disallowed", func(t *testing.T) {
		cfg := validConfig()
		cfg.Deployer.Address = "0x0000000000000000000000000000000000000000"
		_, errs := Verify(cfg, VerifyOptions{})
		if len(errs) == 0 {
			t.Fatal("expected zero address error")
		}
	})

	t.Run("duplicate address", func(t *testing.T) {
		cfg := validConfig()
		cfg.Operators[0].Address = cfg.Buckets["faucet"].Address
		_, errs := Verify(cfg, VerifyOptions{})
		if len(errs) == 0 {
			t.Fatal("expected duplicate error")
		}
	})

	t.Run("bad amount", func(t *testing.T) {
		cfg := validConfig()
		cfg.Deployer.Amount = "12x"
		_, errs := Verify(cfg, VerifyOptions{})
		if len(errs) == 0 {
			t.Fatal("expected amount error")
		}
	})
}

func TestRenderDeterministic(t *testing.T) {
	cfg1 := validConfig()
	cfg2 := validConfig()
	cfg2.Operators = []config.AllocationEntry{{Address: "0x1000000000000000000000000000000000000005", Amount: "333"}, {Address: "0x1000000000000000000000000000000000000003", Amount: "300"}}
	cfg1.Operators = []config.AllocationEntry{{Address: "0x1000000000000000000000000000000000000003", Amount: "300"}, {Address: "0x1000000000000000000000000000000000000005", Amount: "333"}}
	out1, err := RenderAllocMap(cfg1)
	if err != nil {
		t.Fatal(err)
	}
	out2, err := RenderAllocMap(cfg2)
	if err != nil {
		t.Fatal(err)
	}
	if string(out1) != string(out2) {
		t.Fatalf("render output differs:\n%s\n%s", out1, out2)
	}
}

func TestReportTotalsAndFormatting(t *testing.T) {
	cfg := validConfig()
	cfg.Buckets["treasury"] = config.AllocationEntry{Address: "0x1000000000000000000000000000000000000001", Amount: "1000000000000000000"}
	cfg.Buckets["faucet"] = config.AllocationEntry{Address: "0x1000000000000000000000000000000000000002", Amount: "2500000000000000000"}
	cfg.Operators = []config.AllocationEntry{{Address: "0x1000000000000000000000000000000000000003", Amount: "500000000000000000"}}
	cfg.Deployer = config.AllocationEntry{Address: "0x1000000000000000000000000000000000000004", Amount: "100000000000000000"}

	token := config.TokenConfig{Name: "QIK", Symbol: "QIK", Decimals: 18, SupplyPolicy: "fixed", Phase1PosRewards: "0"}
	report, err := BuildReport(cfg, token, 6)
	if err != nil {
		t.Fatal(err)
	}
	if report.TotalPremineWei != "4100000000000000000" {
		t.Fatalf("unexpected total wei: %s", report.TotalPremineWei)
	}
	if report.TotalPremineQIK != "4.1" {
		t.Fatalf("unexpected total qik: %s", report.TotalPremineQIK)
	}
}
