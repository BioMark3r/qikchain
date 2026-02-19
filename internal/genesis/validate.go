package genesis

import (
	"fmt"
	"regexp"
)

type ValidateOptions struct {
	AllowMissingPOSAddresses bool
}

var balanceRe = regexp.MustCompile(`^[0-9]+$`)
var addrRe = regexp.MustCompile(`^0x[0-9a-fA-F]{40}$`)

func Validate(gen map[string]any, opts ValidateOptions) []error {
	errs := make([]error, 0)
	params, _ := gen["params"].(map[string]any)
	if params == nil {
		errs = append(errs, fmt.Errorf("params object is required"))
	} else {
		if _, ok := params["chainID"].(float64); !ok {
			errs = append(errs, fmt.Errorf("params.chainID must be numeric"))
		}
	}
	g, _ := gen["genesis"].(map[string]any)
	if g == nil {
		errs = append(errs, fmt.Errorf("genesis object is required"))
	} else {
		alloc, _ := g["alloc"].(map[string]any)
		if alloc == nil {
			errs = append(errs, fmt.Errorf("genesis.alloc must be an object"))
		} else {
			for addr, raw := range alloc {
				if !addrRe.MatchString(addr) {
					errs = append(errs, fmt.Errorf("genesis.alloc key %q is not an address", addr))
				}
				entry, _ := raw.(map[string]any)
				if entry == nil {
					errs = append(errs, fmt.Errorf("genesis.alloc.%s must be object", addr))
					continue
				}
				bal, _ := entry["balance"].(string)
				if bal == "" || !balanceRe.MatchString(bal) {
					errs = append(errs, fmt.Errorf("genesis.alloc.%s.balance must be numeric string", addr))
				}
			}
		}
	}
	cons, _ := gen["consensus"].(map[string]any)
	if cons == nil {
		errs = append(errs, fmt.Errorf("consensus object is required"))
	} else if _, ok := cons["type"].(string); !ok {
		errs = append(errs, fmt.Errorf("consensus.type is required"))
	}
	if mode, _ := gen["consensusMode"].(string); mode == "ibft-pos" {
		pos, _ := gen["pos"].(map[string]any)
		if pos == nil {
			errs = append(errs, fmt.Errorf("pos object is required for ibft-pos"))
		} else {
			for _, key := range []string{"stakingContract", "validatorSetContract"} {
				v, _ := pos[key].(string)
				if v == "" {
					errs = append(errs, fmt.Errorf("pos.%s is required", key))
					continue
				}
				if opts.AllowMissingPOSAddresses && (v == "{{STAKING_ADDRESS}}" || v == "{{VALIDATOR_SET_ADDRESS}}") {
					continue
				}
				if !addrRe.MatchString(v) {
					errs = append(errs, fmt.Errorf("pos.%s must be 0x address", key))
				}
			}
		}
	}
	return errs
}
