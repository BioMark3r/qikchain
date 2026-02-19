package genesis

import (
	"fmt"
	"regexp"
	"strings"
)

type ValidateOptions struct {
	AllowMissingPOSAddresses bool
	Strict                   bool
	AcceptLegacyConsensus    bool
}

type ValidateResult struct {
	Errors   []error
	Warnings []string
}

var balanceRe = regexp.MustCompile(`^[0-9]+$`)
var addrRe = regexp.MustCompile(`^0x[0-9a-fA-F]{40}$`)

func Validate(gen map[string]any, opts ValidateOptions) ValidateResult {
	res := ValidateResult{Errors: make([]error, 0), Warnings: make([]string, 0)}

	legacyKeys := []string{"consensus", "consensusMode", "pos", "consensusRaw"}
	foundLegacy := make([]string, 0)
	for _, key := range legacyKeys {
		if _, ok := gen[key]; ok {
			foundLegacy = append(foundLegacy, key)
		}
	}
	if len(foundLegacy) > 0 {
		msg := fmt.Sprintf("legacy top-level key(s) present: %s; migrate to params.engine.ibft", strings.Join(foundLegacy, ", "))
		if opts.Strict {
			res.Errors = append(res.Errors, fmt.Errorf(msg))
		} else {
			res.Warnings = append(res.Warnings, msg)
		}
	}

	params, _ := gen["params"].(map[string]any)
	if params == nil {
		res.Errors = append(res.Errors, fmt.Errorf("params object is required"))
	} else {
		if _, ok := params["chainID"].(float64); !ok {
			if _, altOK := params["chainId"].(float64); !altOK {
				res.Errors = append(res.Errors, fmt.Errorf("params.chainID (or params.chainId) must be numeric"))
			}
		}
		if _, ok := params["minGasPrice"]; !ok {
			res.Warnings = append(res.Warnings, "params.minGasPrice is recommended")
		}

		engine, _ := params["engine"].(map[string]any)
		if engine == nil {
			res.Errors = append(res.Errors, fmt.Errorf("params.engine must be an object"))
		} else {
			ibft, _ := engine["ibft"].(map[string]any)
			if ibft == nil {
				legacyAccepted := false
				if opts.AcceptLegacyConsensus {
					cons, _ := gen["consensus"].(map[string]any)
					if strings.EqualFold(asString(cons["type"]), "ibft") {
						legacyAccepted = true
						res.Warnings = append(res.Warnings, "legacy consensus schema accepted; migrate to params.engine.ibft")
					}
				}
				if !legacyAccepted {
					res.Errors = append(res.Errors, fmt.Errorf("params.engine.ibft must be an object"))
				}
			} else {
				typ := asString(ibft["type"])
				if typ == "" {
					res.Errors = append(res.Errors, fmt.Errorf("params.engine.ibft.type is required"))
				} else if typ != "PoA" && typ != "PoS" {
					res.Errors = append(res.Errors, fmt.Errorf("params.engine.ibft.type must be \"PoA\" or \"PoS\""))
				}
			}
		}
	}

	g, _ := gen["genesis"].(map[string]any)
	if g == nil {
		res.Errors = append(res.Errors, fmt.Errorf("genesis object is required"))
	} else {
		if _, ok := g["gasLimit"]; !ok {
			res.Warnings = append(res.Warnings, "genesis.gasLimit is recommended")
		}
		alloc, _ := g["alloc"].(map[string]any)
		if alloc == nil {
			res.Errors = append(res.Errors, fmt.Errorf("genesis.alloc must be an object"))
		} else {
			for addr, raw := range alloc {
				if !addrRe.MatchString(addr) {
					res.Errors = append(res.Errors, fmt.Errorf("genesis.alloc key %q is not an address", addr))
				}
				entry, _ := raw.(map[string]any)
				if entry == nil {
					res.Errors = append(res.Errors, fmt.Errorf("genesis.alloc.%s must be object", addr))
					continue
				}
				bal, _ := entry["balance"].(string)
				if bal == "" || !balanceRe.MatchString(bal) {
					res.Errors = append(res.Errors, fmt.Errorf("genesis.alloc.%s.balance must be numeric string", addr))
				}
			}
		}
	}

	return res
}

func asString(v any) string {
	s, _ := v.(string)
	return s
}
