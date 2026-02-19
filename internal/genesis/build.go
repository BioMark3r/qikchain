package genesis

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/BioMark3r/qikchain/internal/allocations"
	"github.com/BioMark3r/qikchain/internal/chainmeta"
	"github.com/BioMark3r/qikchain/internal/config"
)

type BuildOptions struct {
	Consensus                string
	Env                      string
	TemplatePath             string
	OverlayDir               string
	TokenPath                string
	AllocationsPath          string
	ChainID                  int
	BlockGasLimit            string
	MinGasPrice              string
	BaseFeeEnabled           bool
	POSDeploymentsPath       string
	OutPath                  string
	MetadataOutPath          string
	Strict                   bool
	AllowMissingPOSAddresses bool
	AcceptLegacyConsensus    bool
	Pretty                   bool
}

type POSAddresses struct {
	Staking      string `json:"staking"`
	ValidatorSet string `json:"validatorSet"`
}

type BuildResult struct {
	GenesisJSON      []byte
	MetadataJSON     []byte
	TotalPremineWei  string
	POSAddresses     POSAddresses
	POSAddressesUsed bool
}

func Build(opts BuildOptions) (BuildResult, error) {
	var res BuildResult

	token, err := config.LoadTokenConfig(opts.TokenPath)
	if err != nil {
		return res, err
	}
	if token.Symbol != "QIK" || token.Name != "QIK" || token.Decimals != 18 {
		return res, fmt.Errorf("token config must represent QIK with 18 decimals")
	}
	if token.SupplyPolicy != "fixed" {
		return res, fmt.Errorf("token supplyPolicy must be fixed, got %q", token.SupplyPolicy)
	}
	if token.Phase1PosRewards != "0" {
		return res, fmt.Errorf("token phase1PosRewards must be 0, got %q", token.Phase1PosRewards)
	}

	allocCfg, err := config.LoadAllocationConfig(opts.AllocationsPath)
	if err != nil {
		return res, err
	}
	if _, errs := allocations.Verify(allocCfg, allocations.VerifyOptions{}); len(errs) > 0 {
		return res, fmt.Errorf("allocation verification failed: %v", errs[0])
	}
	allocJSON, totalPremine, err := allocations.RenderAllocMapAndTotal(allocCfg)
	if err != nil {
		return res, err
	}
	res.TotalPremineWei = totalPremine

	base, err := LoadTemplate(opts.TemplatePath)
	if err != nil {
		return res, err
	}
	overlayPath := filepath.Join(opts.OverlayDir, opts.Consensus+".json")
	overlay, err := loadJSONFile(overlayPath)
	if err != nil {
		return res, err
	}

	placeholders := map[string]string{
		"CHAIN_ID":             strconv.Itoa(opts.ChainID),
		"BLOCK_GAS_LIMIT":      opts.BlockGasLimit,
		"MIN_GAS_PRICE":        strconv.Quote(opts.MinGasPrice),
		"BASE_FEE_ENABLED":     strconv.FormatBool(opts.BaseFeeEnabled),
		"PREALLOCATIONS":       string(allocJSON),
		"POS_BLOCK_REWARD":     strconv.Quote("0"),
		"VALIDATOR_EXTRA_DATA": strconv.Quote("0x"),
	}

	if opts.Consensus == "pos" {
		res.POSAddressesUsed = true
		posAddr, err := loadPOSAddresses(opts.POSDeploymentsPath)
		if err != nil {
			if !opts.AllowMissingPOSAddresses {
				return res, err
			}
			posAddr = POSAddresses{Staking: "{{STAKING_ADDRESS}}", ValidatorSet: "{{VALIDATOR_SET_ADDRESS}}"}
		}
		res.POSAddresses = posAddr
		placeholders["STAKING_ADDRESS"] = posAddr.Staking
		placeholders["VALIDATOR_SET_ADDRESS"] = posAddr.ValidatorSet
	}

	if err := ApplyPlaceholders(base, placeholders, opts.Strict); err != nil {
		return res, err
	}
	if err := ApplyPlaceholders(overlay, placeholders, opts.Strict); err != nil {
		return res, err
	}

	genesis := DeepMerge(base, overlay)
	removeForbiddenTopLevelKeys(genesis)
	ensureParamsEngineIBFT(genesis, overlay)
	v := Validate(genesis, ValidateOptions{
		AllowMissingPOSAddresses: opts.AllowMissingPOSAddresses,
		Strict:                   opts.Strict,
		AcceptLegacyConsensus:    opts.AcceptLegacyConsensus,
	})
	for _, w := range v.Warnings {
		fmt.Fprintf(os.Stderr, "genesis build warning: %s\n", w)
	}
	if len(v.Errors) > 0 {
		return res, fmt.Errorf("genesis validation failed: %v", v.Errors[0])
	}

	if opts.Pretty {
		res.GenesisJSON, err = MarshalCanonicalIndented(genesis)
	} else {
		res.GenesisJSON, err = MarshalCanonical(genesis)
	}
	if err != nil {
		return res, err
	}
	meta, err := chainmeta.RenderMetadata(token)
	if err != nil {
		return res, err
	}
	res.MetadataJSON = meta
	return res, nil
}

func ensureParamsEngineIBFT(base map[string]any, overlay map[string]any) {
	params, _ := base["params"].(map[string]any)
	if params == nil {
		params = map[string]any{}
		base["params"] = params
	}
	engine, _ := params["engine"].(map[string]any)
	if engine == nil {
		engine = map[string]any{}
		params["engine"] = engine
	}
	overlayParams, _ := overlay["params"].(map[string]any)
	overlayEngine, _ := overlayParams["engine"].(map[string]any)
	if overlayEngine == nil {
		return
	}
	for k, v := range overlayEngine {
		engine[k] = cloneAny(v)
	}
}

func removeForbiddenTopLevelKeys(genesis map[string]any) {
	for _, key := range []string{"consensus", "consensusMode", "pos", "consensusRaw"} {
		delete(genesis, key)
	}
}

func WriteOutputs(opts BuildOptions, res BuildResult) error {
	if err := os.MkdirAll(filepath.Dir(opts.OutPath), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(opts.OutPath, res.GenesisJSON, 0o644); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(opts.MetadataOutPath), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(opts.MetadataOutPath, res.MetadataJSON, 0o644); err != nil {
		return err
	}
	if res.POSAddressesUsed {
		data, err := MarshalCanonicalIndented(res.POSAddresses)
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(filepath.Dir(opts.OutPath), "pos-addresses.json"), data, 0o644); err != nil {
			return err
		}
	}
	return nil
}

func loadPOSAddresses(path string) (POSAddresses, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return POSAddresses{}, fmt.Errorf("load pos deployments: %w", err)
	}
	var doc struct {
		Staking struct {
			Address string `json:"address"`
		} `json:"staking"`
		ValidatorSet struct {
			Address string `json:"address"`
		} `json:"validatorSet"`
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		return POSAddresses{}, fmt.Errorf("parse pos deployments: %w", err)
	}
	addr := POSAddresses{Staking: strings.ToLower(doc.Staking.Address), ValidatorSet: strings.ToLower(doc.ValidatorSet.Address)}
	if addr.Staking == "" || addr.ValidatorSet == "" {
		return POSAddresses{}, fmt.Errorf("pos deployments missing staking/validatorSet addresses")
	}
	return addr, nil
}
