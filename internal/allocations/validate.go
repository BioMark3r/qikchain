package allocations

import (
	"fmt"
	"regexp"
	"strings"

	"github.com/BioMark3r/qikchain/internal/config"
)

var addressPattern = regexp.MustCompile(`^0x[0-9a-fA-F]{40}$`)

type VerifyOptions struct {
	AllowZeroAddress bool
}

type Summary struct {
	BucketCount   int
	OperatorCount int
	AddressCount  int
}

func Verify(cfg config.AllocationConfig, opts VerifyOptions) (Summary, []error) {
	errs := make([]error, 0)
	summary := Summary{}

	if cfg.Meta.Unit != "wei" {
		errs = append(errs, fmt.Errorf("meta.unit must be wei"))
	}
	if cfg.Meta.Decimals != 18 {
		errs = append(errs, fmt.Errorf("meta.decimals must be 18"))
	}
	if cfg.Meta.Token != "QIK" {
		errs = append(errs, fmt.Errorf("meta.token must be QIK"))
	}
	if len(cfg.Buckets) == 0 {
		errs = append(errs, fmt.Errorf("buckets must not be empty"))
	}
	seen := map[string]string{}

	for name, entry := range cfg.Buckets {
		summary.BucketCount++
		addr, err := normalizeAddress(entry.Address, opts.AllowZeroAddress)
		if err != nil {
			errs = append(errs, fmt.Errorf("buckets.%s.address: %w", name, err))
		} else {
			if first, ok := seen[addr]; ok {
				errs = append(errs, fmt.Errorf("buckets.%s.address duplicates %s (%s)", name, first, addr))
			} else {
				seen[addr] = "buckets." + name + ".address"
				summary.AddressCount++
			}
		}
		if _, err := config.ParseAmountDecimal(entry.Amount); err != nil {
			errs = append(errs, fmt.Errorf("buckets.%s.amount: %w", name, err))
		}
	}

	for i, op := range cfg.Operators {
		summary.OperatorCount++
		addr, err := normalizeAddress(op.Address, opts.AllowZeroAddress)
		if err != nil {
			errs = append(errs, fmt.Errorf("operators[%d].address: %w", i, err))
		} else {
			if first, ok := seen[addr]; ok {
				errs = append(errs, fmt.Errorf("operators[%d].address duplicates %s (%s)", i, first, addr))
			} else {
				seen[addr] = fmt.Sprintf("operators[%d].address", i)
				summary.AddressCount++
			}
		}
		if _, err := config.ParseAmountDecimal(op.Amount); err != nil {
			errs = append(errs, fmt.Errorf("operators[%d].amount: %w", i, err))
		}
	}

	if cfg.Deployer.Address == "" {
		errs = append(errs, fmt.Errorf("deployer.address is required"))
	} else {
		addr, err := normalizeAddress(cfg.Deployer.Address, opts.AllowZeroAddress)
		if err != nil {
			errs = append(errs, fmt.Errorf("deployer.address: %w", err))
		} else {
			if first, ok := seen[addr]; ok {
				errs = append(errs, fmt.Errorf("deployer.address duplicates %s (%s)", first, addr))
			} else {
				seen[addr] = "deployer.address"
				summary.AddressCount++
			}
		}
	}
	if _, err := config.ParseAmountDecimal(cfg.Deployer.Amount); err != nil {
		errs = append(errs, fmt.Errorf("deployer.amount: %w", err))
	}

	return summary, errs
}

func normalizeAddress(value string, allowZero bool) (string, error) {
	if !addressPattern.MatchString(value) {
		return "", fmt.Errorf("must be 0x + 40 hex chars")
	}
	addr := strings.ToLower(value)
	if !allowZero && addr == "0x0000000000000000000000000000000000000000" {
		return "", fmt.Errorf("zero address is not allowed")
	}
	return addr, nil
}
