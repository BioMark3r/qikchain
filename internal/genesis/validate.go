package genesis

import (
	"fmt"
	"os"
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

func Validate(doc map[string]any, opts ValidateOptions) ValidateResult {
	if _, hasAlloc := doc["alloc"]; hasAlloc {
		return ValidateEthereumGenesis(doc)
	}
	return ValidateChainConfig(doc, opts)
}

func ValidateChainConfig(doc map[string]any, opts ValidateOptions) ValidateResult {
	res := ValidateResult{Errors: make([]error, 0), Warnings: make([]string, 0)}

	legacyKeys := []string{"consensus", "consensusMode", "pos", "consensusRaw"}
	foundLegacy := make([]string, 0)
	for _, key := range legacyKeys {
		if _, ok := doc[key]; ok {
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

	params, _ := doc["params"].(map[string]any)
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
		if forks, ok := params["forks"].(map[string]any); !ok || forks == nil {
			res.Errors = append(res.Errors, fmt.Errorf("params.forks must be a non-nil object"))
		}

		engine, _ := params["engine"].(map[string]any)
		if engine == nil {
			res.Errors = append(res.Errors, fmt.Errorf("params.engine must be an object"))
		} else {
			ibft, _ := engine["ibft"].(map[string]any)
			if ibft == nil {
				legacyAccepted := false
				if opts.AcceptLegacyConsensus {
					cons, _ := doc["consensus"].(map[string]any)
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

	g, existsGenesis := doc["genesis"]
	if !existsGenesis {
		res.Errors = append(res.Errors, fmt.Errorf("genesis field is required"))
		return res
	}
	if embeddedGenesis, ok := g.(map[string]any); ok {
		ev := ValidateEthereumGenesis(embeddedGenesis)
		res.Warnings = append(res.Warnings, ev.Warnings...)
		res.Errors = append(res.Errors, ev.Errors...)
		return res
	}
	genesisPath, ok := g.(string)
	if !ok || strings.TrimSpace(genesisPath) == "" {
		res.Errors = append(res.Errors, fmt.Errorf("genesis must be an embedded object or a non-empty string path"))
		return res
	}

	if stat, err := os.Stat(genesisPath); err == nil && !stat.IsDir() {
		ethDoc, err := loadJSONFile(genesisPath)
		if err != nil {
			res.Errors = append(res.Errors, fmt.Errorf("failed to parse genesis file %q: %v", genesisPath, err))
		} else {
			ev := ValidateEthereumGenesis(ethDoc)
			res.Warnings = append(res.Warnings, ev.Warnings...)
			res.Errors = append(res.Errors, ev.Errors...)
		}
	}

	return res
}

func ValidateEthereumGenesis(doc map[string]any) ValidateResult {
	res := ValidateResult{Errors: make([]error, 0), Warnings: make([]string, 0)}

	alloc, _ := doc["alloc"].(map[string]any)
	if alloc == nil {
		res.Errors = append(res.Errors, fmt.Errorf("alloc must be an object"))
	} else {
		for addr, raw := range alloc {
			if !addrRe.MatchString(addr) {
				res.Errors = append(res.Errors, fmt.Errorf("alloc key %q is not an address", addr))
			}
			entry, _ := raw.(map[string]any)
			if entry == nil {
				res.Errors = append(res.Errors, fmt.Errorf("alloc.%s must be object", addr))
				continue
			}
			bal, _ := entry["balance"].(string)
			if bal == "" || !balanceRe.MatchString(bal) {
				res.Errors = append(res.Errors, fmt.Errorf("alloc.%s.balance must be numeric string", addr))
			}
		}
	}

	if _, ok := doc["gasLimit"].(string); !ok {
		res.Errors = append(res.Errors, fmt.Errorf("ethereum genesis: top-level gasLimit is required"))
	}
	if _, ok := doc["difficulty"].(string); !ok {
		res.Errors = append(res.Errors, fmt.Errorf("ethereum genesis: top-level difficulty is required"))
	}
	if _, ok := doc["extraData"].(string); !ok {
		res.Errors = append(res.Errors, fmt.Errorf("ethereum genesis: top-level extraData is required"))
	}
	if _, ok := doc["baseFeeEnabled"].(bool); !ok {
		res.Errors = append(res.Errors, fmt.Errorf("ethereum genesis: top-level baseFeeEnabled is required and must be boolean"))
	}

	return res
}

func asString(v any) string {
	s, _ := v.(string)
	return s
}
