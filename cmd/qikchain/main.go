package main

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/BioMark3r/qikchain/internal/allocations"
	"github.com/BioMark3r/qikchain/internal/chainmeta"
	"github.com/BioMark3r/qikchain/internal/config"
	"github.com/BioMark3r/qikchain/internal/genesis"
)

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(argv []string) int {
	if len(argv) == 0 {
		fmt.Println("qikchain: no command (try --help)")
		return 2
	}

	switch argv[0] {
	case "-h", "--help", "help":
		printHelp()
		return 0
	case "status":
		return cmdStatus(argv[1:])
	case "block":
		return cmdBlock(argv[1:])
	case "allocations":
		return cmdAllocations(argv[1:])
	case "chain":
		return cmdChain(argv[1:])
	case "genesis":
		return cmdGenesis(argv[1:])
	default:
		fmt.Fprintf(os.Stderr, "qikchain: unknown command %q (try --help)\n", argv[0])
		return 2
	}
}

func printHelp() {
	fmt.Print(`qikchain

Usage:
  qikchain status --rpc http://127.0.0.1:8545
  qikchain block head --rpc http://127.0.0.1:8545
  qikchain allocations verify --file config/allocations/devnet.json
  qikchain allocations report --file config/allocations/devnet.json [--json]
  qikchain allocations render --file config/allocations/devnet.json
  qikchain chain metadata --token config/token.json [--out build/chain-metadata.json]
  qikchain genesis build [--consensus poa|pos --env devnet|staging|mainnet]
  qikchain genesis validate --chain build/chain.json [--genesis build/genesis-eth.json]
  qikchain genesis print --file build/chain.json [--json]
`)
}

func cmdAllocations(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "allocations: expected subcommand (verify|report|render)")
		return 2
	}
	switch args[0] {
	case "verify":
		return cmdAllocationsVerify(args[1:])
	case "report":
		return cmdAllocationsReport(args[1:])
	case "render":
		return cmdAllocationsRender(args[1:])
	default:
		fmt.Fprintf(os.Stderr, "allocations: unknown subcommand %q\n", args[0])
		return 2
	}
}

func cmdGenesis(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "genesis: expected subcommand (build|validate|print)")
		return 2
	}
	switch args[0] {
	case "build":
		return cmdGenesisBuild(args[1:])
	case "validate":
		return cmdGenesisValidate(args[1:])
	case "print":
		return cmdGenesisPrint(args[1:])
	default:
		fmt.Fprintf(os.Stderr, "genesis: unknown subcommand %q\n", args[0])
		return 2
	}
}

func cmdGenesisBuild(args []string) int {
	fs := flag.NewFlagSet("genesis build", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	consensus := fs.String("consensus", "poa", "consensus mode (poa|pos)")
	env := fs.String("env", "devnet", "environment (devnet|staging|mainnet)")
	templatePath := fs.String("template", "config/genesis.template.json", "genesis template path")
	overlayDir := fs.String("overlay-dir", "config/consensus", "consensus overlay directory")
	tokenPath := fs.String("token", "config/token.json", "token metadata file path")
	allocationsPath := fs.String("allocations", "", "allocation file path")
	chainID := fs.Int("chain-id", 0, "chain id")
	gasLimitRaw := fs.String("gas-limit", "0x1c9c380", "ethereum genesis gas limit (decimal or 0x-hex)")
	blockGasLimit := fs.String("block-gas-limit", "", "deprecated alias for --gas-limit")
	difficulty := fs.String("difficulty", "0x1", "ethereum genesis difficulty (decimal or 0x-hex)")
	extraData := fs.String("extra-data", "0x", "ethereum genesis extraData")
	minGasPrice := fs.String("min-gas-price", "0", "minimum gas price in wei")
	baseFeeEnabled := fs.Bool("base-fee-enabled", false, "enable base fee in ethereum genesis")
	posDeployments := fs.String("pos-deployments", "build/deployments/pos.local.json", "PoS deployment file path")
	out := fs.String("out", "", "deprecated single output path (writes chain file)")
	outChain := fs.String("out-chain", "build/chain.json", "output chain config path")
	outGenesis := fs.String("out-genesis", "build/genesis-eth.json", "output Ethereum genesis path")
	metadataOut := fs.String("metadata-out", "build/chain-metadata.json", "output chain metadata path")
	strict := fs.Bool("strict", true, "strict genesis validation (fail on legacy top-level consensus keys)")
	acceptLegacyConsensus := fs.Bool("accept-legacy-consensus", false, "temporarily accept top-level legacy consensus schema when params.engine.ibft is missing")
	allowMissingPOS := fs.Bool("allow-missing-pos-addresses", false, "allow unresolved PoS addresses")
	pretty := fs.Bool("pretty", true, "pretty print output")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	if *consensus != "poa" && *consensus != "pos" {
		fmt.Fprintln(os.Stderr, "genesis build: --consensus must be poa or pos")
		return 2
	}
	if *env != "devnet" && *env != "staging" && *env != "mainnet" {
		fmt.Fprintln(os.Stderr, "genesis build: --env must be devnet|staging|mainnet")
		return 2
	}
	if *allocationsPath == "" {
		*allocationsPath = filepath.Join("config", "allocations", *env+".json")
	}
	if *chainID == 0 {
		switch *env {
		case "devnet":
			*chainID = 100
		case "staging":
			*chainID = 101
		case "mainnet":
			fmt.Fprintln(os.Stderr, "genesis build: --chain-id is required for mainnet")
			return 2
		}
	}

	if strings.TrimSpace(*blockGasLimit) != "" {
		*gasLimitRaw = *blockGasLimit
	}
	gasLimit, err := toHexQuantity(*gasLimitRaw)
	if err != nil {
		fmt.Fprintf(os.Stderr, "genesis build: invalid --gas-limit: %v\n", err)
		return 2
	}
	difficultyHex, err := toHexQuantity(*difficulty)
	if err != nil {
		fmt.Fprintf(os.Stderr, "genesis build: invalid --difficulty: %v\n", err)
		return 2
	}

	opts := genesis.BuildOptions{
		Consensus:                *consensus,
		Env:                      *env,
		TemplatePath:             *templatePath,
		OverlayDir:               *overlayDir,
		TokenPath:                *tokenPath,
		AllocationsPath:          *allocationsPath,
		ChainID:                  *chainID,
		GasLimit:                 gasLimit,
		Difficulty:               difficultyHex,
		ExtraData:                *extraData,
		MinGasPrice:              *minGasPrice,
		BaseFeeEnabled:           *baseFeeEnabled,
		POSDeploymentsPath:       *posDeployments,
		OutPath:                  *out,
		OutChainPath:             *outChain,
		OutGenesisPath:           *outGenesis,
		MetadataOutPath:          *metadataOut,
		Strict:                   *strict,
		AllowMissingPOSAddresses: *allowMissingPOS,
		AcceptLegacyConsensus:    *acceptLegacyConsensus,
		Pretty:                   *pretty,
	}

	res, err := genesis.Build(opts)
	if err != nil {
		fmt.Fprintln(os.Stderr, "genesis build:", err)
		return 1
	}
	if err := genesis.WriteOutputs(opts, res); err != nil {
		fmt.Fprintln(os.Stderr, "genesis build:", err)
		return 1
	}

	fmt.Printf("consensus=%s env=%s chainId=%d\n", *consensus, *env, *chainID)
	fmt.Printf("allocTotalWei=%s\n", res.TotalPremineWei)
	chainOut := *outChain
	if chainOut == "" {
		chainOut = *out
	}
	if chainOut == "" {
		chainOut = "build/chain.json"
	}
	genOut := *outGenesis
	if genOut == "" {
		genOut = "build/genesis-eth.json"
	}
	fmt.Printf("chain=%s\ngenesis=%s\nmetadata=%s\n", chainOut, genOut, *metadataOut)
	if res.POSAddressesUsed {
		fmt.Printf("pos.staking=%s\npos.validatorSet=%s\n", res.POSAddresses.Staking, res.POSAddresses.ValidatorSet)
	}
	return 0
}

func cmdGenesisValidate(args []string) int {
	fs := flag.NewFlagSet("genesis validate", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	file := fs.String("file", "", "genesis or chain file path (legacy)")
	chain := fs.String("chain", "", "chain config file path")
	ethGenesis := fs.String("genesis", "", "ethereum genesis file path")
	strict := fs.Bool("strict", true, "strict genesis validation (fail on legacy top-level consensus keys)")
	acceptLegacyConsensus := fs.Bool("accept-legacy-consensus", false, "temporarily accept top-level legacy consensus schema when params.engine.ibft is missing")
	allowMissingPOS := fs.Bool("allow-missing-pos-addresses", false, "allow unresolved PoS addresses")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	validateDoc := func(label, path string, opts genesis.ValidateOptions) (genesis.ValidateResult, bool) {
		data, err := os.ReadFile(path)
		if err != nil {
			fmt.Fprintf(os.Stderr, "genesis validate: failed to read %s: %v\n", label, err)
			return genesis.ValidateResult{}, false
		}
		var doc map[string]any
		if err := json.Unmarshal(data, &doc); err != nil {
			fmt.Fprintf(os.Stderr, "genesis validate: invalid JSON in %s: %v\n", label, err)
			return genesis.ValidateResult{}, false
		}
		return genesis.Validate(doc, opts), true
	}

	opts := genesis.ValidateOptions{AllowMissingPOSAddresses: *allowMissingPOS, Strict: *strict, AcceptLegacyConsensus: *acceptLegacyConsensus}
	results := make([]genesis.ValidateResult, 0, 2)

	if *chain != "" {
		res, ok := validateDoc("chain", *chain, opts)
		if !ok {
			return 1
		}
		results = append(results, res)
	}
	if *ethGenesis != "" {
		res, ok := validateDoc("genesis", *ethGenesis, opts)
		if !ok {
			return 1
		}
		results = append(results, res)
	}
	if *chain == "" && *ethGenesis == "" {
		if *file == "" {
			fmt.Fprintln(os.Stderr, "genesis validate: provide --chain (and optionally --genesis), or --file")
			return 2
		}
		res, ok := validateDoc("file", *file, opts)
		if !ok {
			return 1
		}
		results = append(results, res)
	}

	hasErr := false
	for _, res := range results {
		for _, w := range res.Warnings {
			fmt.Fprintln(os.Stderr, "warning:", w)
		}
		for _, e := range res.Errors {
			fmt.Fprintln(os.Stderr, "-", e)
			hasErr = true
		}
	}
	if hasErr {
		return 1
	}
	fmt.Println("genesis validation: PASS")
	return 0
}

func cmdGenesisPrint(args []string) int {
	fs := flag.NewFlagSet("genesis print", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	file := fs.String("file", "", "genesis file path")
	raw := fs.Bool("json", false, "print raw JSON as-is")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *file == "" {
		fmt.Fprintln(os.Stderr, "genesis print: --file is required")
		return 2
	}
	data, err := os.ReadFile(*file)
	if err != nil {
		fmt.Fprintln(os.Stderr, "genesis print:", err)
		return 1
	}
	if *raw {
		fmt.Print(string(data))
		if len(data) == 0 || data[len(data)-1] != '\n' {
			fmt.Println()
		}
		return 0
	}
	var doc map[string]any
	if err := json.Unmarshal(data, &doc); err != nil {
		fmt.Fprintln(os.Stderr, "genesis print: invalid JSON:", err)
		return 1
	}
	out, err := genesis.MarshalCanonicalIndented(doc)
	if err != nil {
		fmt.Fprintln(os.Stderr, "genesis print:", err)
		return 1
	}
	fmt.Print(string(out))
	return 0
}

func loadAndVerifyAllocationFile(path string, allowZero bool) (config.AllocationConfig, allocations.Summary, error) {
	cfg, err := config.LoadAllocationConfig(path)
	if err != nil {
		return cfg, allocations.Summary{}, err
	}
	summary, errs := allocations.Verify(cfg, allocations.VerifyOptions{AllowZeroAddress: allowZero})
	if len(errs) > 0 {
		var sb strings.Builder
		for _, verifyErr := range errs {
			sb.WriteString("- ")
			sb.WriteString(verifyErr.Error())
			sb.WriteString("\n")
		}
		return cfg, summary, errors.New(strings.TrimSpace(sb.String()))
	}
	return cfg, summary, nil
}

func cmdAllocationsVerify(args []string) int {
	fs := flag.NewFlagSet("allocations verify", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	file := fs.String("file", "", "allocation file path")
	allowZero := fs.Bool("allow-zero-addr", false, "allow 0x000... address")
	_ = fs.Bool("allow-dup-devnet", false, "unused legacy compatibility flag")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *file == "" {
		fmt.Fprintln(os.Stderr, "allocations verify: --file is required")
		return 2
	}
	_, summary, err := loadAndVerifyAllocationFile(*file, *allowZero)
	if err != nil {
		fmt.Fprintf(os.Stderr, "FAIL\n%s\n", err)
		return 1
	}
	fmt.Printf("PASS buckets=%d operators=%d addresses=%d\n", summary.BucketCount, summary.OperatorCount, summary.AddressCount)
	return 0
}

func cmdAllocationsRender(args []string) int {
	fs := flag.NewFlagSet("allocations render", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	file := fs.String("file", "", "allocation file path")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *file == "" {
		fmt.Fprintln(os.Stderr, "allocations render: --file is required")
		return 2
	}
	cfg, _, err := loadAndVerifyAllocationFile(*file, false)
	if err != nil {
		fmt.Fprintf(os.Stderr, "allocations render: verification failed\n%s\n", err)
		return 1
	}
	out, err := allocations.RenderAllocMap(cfg)
	if err != nil {
		fmt.Fprintln(os.Stderr, "allocations render:", err)
		return 1
	}
	fmt.Print(string(out))
	return 0
}

func cmdAllocationsReport(args []string) int {
	fs := flag.NewFlagSet("allocations report", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	file := fs.String("file", "", "allocation file path")
	tokenPath := fs.String("token", "", "token metadata file path")
	jsonOut := fs.Bool("json", false, "print structured json")
	maxDecimals := fs.Int("max-decimals", 6, "max fractional decimals in human QIK output")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *file == "" {
		fmt.Fprintln(os.Stderr, "allocations report: --file is required")
		return 2
	}
	cfg, _, err := loadAndVerifyAllocationFile(*file, false)
	if err != nil {
		fmt.Fprintf(os.Stderr, "allocations report: verification failed\n%s\n", err)
		return 1
	}
	if *tokenPath == "" {
		if _, err := os.Stat("config/token.json"); err == nil {
			*tokenPath = "config/token.json"
		} else {
			fmt.Fprintln(os.Stderr, "allocations report: --token is required when config/token.json is absent")
			return 2
		}
	}
	token, err := config.LoadTokenConfig(*tokenPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "allocations report:", err)
		return 1
	}
	report, err := allocations.BuildReport(cfg, token, *maxDecimals)
	if err != nil {
		fmt.Fprintln(os.Stderr, "allocations report:", err)
		return 1
	}
	if *jsonOut {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		_ = enc.Encode(report)
		return 0
	}
	fmt.Printf("Token: %s (%s), decimals=%d, supplyPolicy=%s, phase1PosRewards=%s\n", report.Token.Name, report.Token.Symbol, report.Token.Decimals, report.Token.SupplyPolicy, report.Token.Phase1PosRewards)
	for _, b := range report.Buckets {
		fmt.Printf("Bucket %-10s %s wei=%s qik=%s\n", b.Name, b.Address, b.Wei, b.QIK)
	}
	fmt.Println("Operators:")
	for _, op := range report.Operators {
		fmt.Printf("  %s wei=%s qik=%s\n", op.Address, op.Wei, op.QIK)
	}
	fmt.Printf("Deployer %s wei=%s qik=%s\n", report.Deployer.Address, report.Deployer.Wei, report.Deployer.QIK)
	fmt.Printf("Total premine wei=%s qik=%s\n", report.TotalPremineWei, report.TotalPremineQIK)
	fmt.Println(report.SupplyPolicyNotes)
	return 0
}

func cmdChain(args []string) int {
	if len(args) == 0 || args[0] != "metadata" {
		fmt.Fprintln(os.Stderr, "chain: expected subcommand metadata")
		return 2
	}
	fs := flag.NewFlagSet("chain metadata", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	tokenPath := fs.String("token", "", "token metadata file path")
	outPath := fs.String("out", "", "output file path")
	if err := fs.Parse(args[1:]); err != nil {
		return 2
	}
	if *tokenPath == "" {
		fmt.Fprintln(os.Stderr, "chain metadata: --token is required")
		return 2
	}
	token, err := config.LoadTokenConfig(*tokenPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "chain metadata:", err)
		return 1
	}
	data, err := chainmeta.RenderMetadata(token)
	if err != nil {
		fmt.Fprintln(os.Stderr, "chain metadata:", err)
		return 1
	}
	if *outPath == "" {
		fmt.Print(string(data))
		return 0
	}
	if err := os.MkdirAll(filepath.Dir(*outPath), 0o755); err != nil {
		fmt.Fprintln(os.Stderr, "chain metadata:", err)
		return 1
	}
	if err := os.WriteFile(*outPath, data, 0o644); err != nil {
		fmt.Fprintln(os.Stderr, "chain metadata:", err)
		return 1
	}
	return 0
}

func cmdStatus(args []string) int {
	fs := flag.NewFlagSet("status", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	rpc := fs.String("rpc", "", "JSON-RPC endpoint (e.g. http://127.0.0.1:8545)")
	timeout := fs.Duration("timeout", 5*time.Second, "request timeout")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *rpc == "" {
		fmt.Fprintln(os.Stderr, "status: --rpc is required")
		return 2
	}

	c := &rpcClient{url: *rpc, http: &http.Client{Timeout: *timeout}}

	chainIDHex, err := c.callString("eth_chainId")
	if err != nil {
		fmt.Fprintln(os.Stderr, "status: eth_chainId:", err)
		return 1
	}
	blockHex, err := c.callString("eth_blockNumber")
	if err != nil {
		fmt.Fprintln(os.Stderr, "status: eth_blockNumber:", err)
		return 1
	}
	peerHex, err := c.callString("net_peerCount")
	if err != nil {
		fmt.Fprintln(os.Stderr, "status: net_peerCount:", err)
		return 1
	}

	chainID, _ := hexToUint64(chainIDHex)
	blockNum, _ := hexToUint64(blockHex)
	peers, _ := hexToUint64(peerHex)

	fmt.Printf("rpc:        %s\n", *rpc)
	fmt.Printf("chainId:    %d (%s)\n", chainID, chainIDHex)
	fmt.Printf("blockHead:  %d (%s)\n", blockNum, blockHex)
	fmt.Printf("peerCount:  %d (%s)\n", peers, peerHex)
	return 0
}

func cmdBlock(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "block: expected subcommand (try: block head)")
		return 2
	}
	switch args[0] {
	case "head":
		return cmdBlockHead(args[1:])
	default:
		fmt.Fprintf(os.Stderr, "block: unknown subcommand %q\n", args[0])
		return 2
	}
}

func cmdBlockHead(args []string) int {
	fs := flag.NewFlagSet("block head", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	rpc := fs.String("rpc", "", "JSON-RPC endpoint (e.g. http://127.0.0.1:8545)")
	timeout := fs.Duration("timeout", 5*time.Second, "request timeout")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *rpc == "" {
		fmt.Fprintln(os.Stderr, "block head: --rpc is required")
		return 2
	}

	c := &rpcClient{url: *rpc, http: &http.Client{Timeout: *timeout}}
	blockHex, err := c.callString("eth_blockNumber")
	if err != nil {
		fmt.Fprintln(os.Stderr, "block head: eth_blockNumber:", err)
		return 1
	}
	blockNum, _ := hexToUint64(blockHex)
	fmt.Println(blockNum)
	return 0
}

type rpcClient struct {
	url  string
	http *http.Client
}

type rpcReq struct {
	JSONRPC string        `json:"jsonrpc"`
	ID      int           `json:"id"`
	Method  string        `json:"method"`
	Params  []interface{} `json:"params"`
}

type rpcResp struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      int             `json:"id"`
	Result  json.RawMessage `json:"result"`
	Error   *rpcErr         `json:"error,omitempty"`
}

type rpcErr struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (c *rpcClient) callString(method string) (string, error) {
	reqBody, _ := json.Marshal(rpcReq{
		JSONRPC: "2.0",
		ID:      1,
		Method:  method,
		Params:  []interface{}{},
	})

	req, err := http.NewRequest(http.MethodPost, c.url, bytes.NewReader(reqBody))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.http.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<10))
		return "", fmt.Errorf("http %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var out rpcResp
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", err
	}
	if out.Error != nil {
		return "", fmt.Errorf("rpc %d: %s", out.Error.Code, out.Error.Message)
	}

	var s string
	if err := json.Unmarshal(out.Result, &s); err != nil {
		return "", fmt.Errorf("unexpected result type: %s", string(out.Result))
	}
	return s, nil
}

func toHexQuantity(v string) (string, error) {
	v = strings.TrimSpace(v)
	if v == "" {
		return "", fmt.Errorf("value is empty")
	}
	if strings.HasPrefix(v, "0x") || strings.HasPrefix(v, "0X") {
		n, err := strconv.ParseUint(v[2:], 16, 64)
		if err != nil {
			return "", fmt.Errorf("must be decimal or 0x hex")
		}
		return fmt.Sprintf("0x%x", n), nil
	}
	n, err := strconv.ParseUint(v, 10, 64)
	if err != nil {
		return "", fmt.Errorf("must be decimal or 0x hex")
	}
	return fmt.Sprintf("0x%x", n), nil
}

func hexToUint64(h string) (uint64, error) {
	h = strings.TrimPrefix(strings.ToLower(strings.TrimSpace(h)), "0x")
	if h == "" {
		return 0, nil
	}
	b, err := hex.DecodeString(padEven(h))
	if err != nil {
		return 0, err
	}
	var n uint64
	for _, v := range b {
		n = (n << 8) | uint64(v)
	}
	return n, nil
}

func padEven(s string) string {
	if len(s)%2 == 1 {
		return "0" + s
	}
	return s
}
