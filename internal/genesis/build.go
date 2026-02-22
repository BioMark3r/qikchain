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
	"github.com/BioMark3r/qikchain/internal/edge"
)

type BuildOptions struct {
	Consensus                string
	Env                      string
	TemplatePath             string
	OverlayDir               string
	TokenPath                string
	AllocationsPath          string
	ChainID                  int
	GasLimit                 string
	Difficulty               string
	ExtraData                string
	MinGasPrice              string
	BaseFeeEnabled           bool
	POSDeploymentsPath       string
	OutPath                  string
	OutCombinedPath          string
	OutChainPath             string
	OutGenesisPath           string
	MetadataOutPath          string
	Strict                   bool
	AllowMissingPOSAddresses bool
	AcceptLegacyConsensus    bool
	Pretty                   bool
	SupportedForks           []string
}

type POSAddresses struct {
	Staking      string `json:"staking"`
	ValidatorSet string `json:"validatorSet"`
}

type ForkObject struct {
	Block uint64 `json:"block"`
}

type BuildResult struct {
	GenesisJSON      []byte
	ChainJSON        []byte
	EthGenesisJSON   []byte
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
		"BLOCK_GAS_LIMIT":      opts.GasLimit,
		"GENESIS_DIFFICULTY":   strconv.Quote(opts.Difficulty),
		"MIN_GAS_PRICE":        strconv.Quote(opts.MinGasPrice),
		"BASE_FEE_ENABLED":     strconv.FormatBool(opts.BaseFeeEnabled),
		"PREALLOCATIONS":       string(allocJSON),
		"POS_BLOCK_REWARD":     strconv.Quote("0"),
		"VALIDATOR_EXTRA_DATA": strconv.Quote(opts.ExtraData),
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

	combined := DeepMerge(base, overlay)
	removeForbiddenTopLevelKeys(combined)
	ensureParamsEngineIBFT(combined, overlay)
	ensureParamsForks(combined, opts.Env, opts.SupportedForks)

	ethGenesis, _ := combined["genesis"].(map[string]any)
	if ethGenesis == nil {
		return res, fmt.Errorf("genesis object is required")
	}
	chainDoc := cloneMap(combined)
	chainDoc["genesis"] = "__GENESIS_PATH__"

	v := ValidateChainConfig(chainDoc, ValidateOptions{
		AllowMissingPOSAddresses: opts.AllowMissingPOSAddresses,
		Strict:                   opts.Strict,
		AcceptLegacyConsensus:    opts.AcceptLegacyConsensus,
	})
	ethValidation := ValidateEthereumGenesis(ethGenesis)
	v.Warnings = append(v.Warnings, ethValidation.Warnings...)
	v.Errors = append(v.Errors, ethValidation.Errors...)
	for _, w := range v.Warnings {
		fmt.Fprintf(os.Stderr, "genesis build warning: %s\n", w)
	}
	if len(v.Errors) > 0 {
		return res, fmt.Errorf("genesis validation failed: %v", v.Errors[0])
	}

	if opts.Pretty {
		res.GenesisJSON, err = MarshalCanonicalIndented(combined)
	} else {
		res.GenesisJSON, err = MarshalCanonical(combined)
	}
	if err != nil {
		return res, err
	}

	if opts.Pretty {
		res.EthGenesisJSON, err = MarshalCanonicalIndented(ethGenesis)
	} else {
		res.EthGenesisJSON, err = MarshalCanonical(ethGenesis)
	}
	if err != nil {
		return res, err
	}
	if opts.Pretty {
		res.ChainJSON, err = MarshalCanonicalIndented(chainDoc)
	} else {
		res.ChainJSON, err = MarshalCanonical(chainDoc)
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

func ensureParamsForks(doc map[string]any, env string, supported []string) {
	params, _ := doc["params"].(map[string]any)
	if params == nil {
		params = map[string]any{}
		doc["params"] = params
	}
	if forks, _ := params["forks"].(map[string]any); forks != nil {
		return
	}

	if strings.EqualFold(env, "devnet") {
		desired := edge.DesiredForks()
		if len(supported) > 0 {
			desired = edge.FilterSupportedForks(desired, supported)
		}
		forks := make(map[string]ForkObject, len(desired))
		for _, key := range desired {
			forks[key] = ForkObject{Block: 0}
		}
		params["forks"] = toAnyForkMap(forks)
		return
	}

	params["forks"] = map[string]any{}
}

func toAnyForkMap(in map[string]ForkObject) map[string]any {
	out := make(map[string]any, len(in))
	for name, fork := range in {
		out[name] = map[string]any{"block": fork.Block}
	}
	return out
}

func removeForbiddenTopLevelKeys(genesis map[string]any) {
	for _, key := range []string{"consensus", "consensusMode", "pos", "consensusRaw"} {
		delete(genesis, key)
	}
}

func WriteOutputs(opts BuildOptions, res BuildResult) error {
	combinedPath := opts.OutCombinedPath
	if combinedPath == "" {
		if opts.OutPath != "" {
			combinedPath = opts.OutPath
		} else {
			combinedPath = filepath.Join("build", "genesis.json")
		}
	}
	chainPath := opts.OutChainPath
	if chainPath == "" {
		chainPath = filepath.Join(filepath.Dir(combinedPath), "chain.json")
	}
	genesisPath := opts.OutGenesisPath
	if genesisPath == "" {
		genesisPath = filepath.Join(filepath.Dir(chainPath), "genesis-eth.json")
	}
	absGenesisPath, err := filepath.Abs(genesisPath)
	if err != nil {
		return err
	}

	if err := os.MkdirAll(filepath.Dir(absGenesisPath), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(absGenesisPath, res.EthGenesisJSON, 0o644); err != nil {
		return err
	}

	if err := os.MkdirAll(filepath.Dir(combinedPath), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(combinedPath, res.GenesisJSON, 0o644); err != nil {
		return err
	}

	var chainDoc map[string]any
	if err := json.Unmarshal(res.ChainJSON, &chainDoc); err != nil {
		return err
	}
	chainDoc["genesis"] = absGenesisPath
	chainJSON, err := MarshalCanonicalIndented(chainDoc)
	if err != nil {
		return err
	}

	if err := os.MkdirAll(filepath.Dir(chainPath), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(chainPath, chainJSON, 0o644); err != nil {
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
		if err := os.WriteFile(filepath.Join(filepath.Dir(chainPath), "pos-addresses.json"), data, 0o644); err != nil {
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
