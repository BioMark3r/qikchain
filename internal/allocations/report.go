package allocations

import (
	"fmt"
	"math/big"
	"sort"
	"strings"

	"github.com/BioMark3r/qikchain/internal/config"
)

type ReportLine struct {
	Name    string `json:"name"`
	Address string `json:"address"`
	Wei     string `json:"wei"`
	QIK     string `json:"qik"`
}

type Report struct {
	Token             config.TokenConfig `json:"token"`
	Buckets           []ReportLine       `json:"buckets"`
	Operators         []ReportLine       `json:"operators"`
	Deployer          ReportLine         `json:"deployer"`
	TotalPremineWei   string             `json:"totalPremineWei"`
	TotalPremineQIK   string             `json:"totalPremineQIK"`
	SupplyPolicyNotes string             `json:"supplyPolicyNote"`
}

func BuildReport(cfg config.AllocationConfig, token config.TokenConfig, maxDecimals int) (Report, error) {
	total := big.NewInt(0)
	report := Report{Token: token, SupplyPolicyNotes: "fixed supply => premine total is total supply if no inflation"}

	bucketNames := make([]string, 0, len(cfg.Buckets))
	for name := range cfg.Buckets {
		bucketNames = append(bucketNames, name)
	}
	sort.Strings(bucketNames)
	for _, name := range bucketNames {
		entry := cfg.Buckets[name]
		addr, _ := normalizeAddress(entry.Address, true)
		amount, _ := config.ParseAmountDecimal(entry.Amount)
		total.Add(total, amount)
		report.Buckets = append(report.Buckets, ReportLine{Name: name, Address: addr, Wei: amount.String(), QIK: FormatQIK(amount, maxDecimals)})
	}

	operators := make([]ReportLine, 0, len(cfg.Operators))
	for _, op := range cfg.Operators {
		addr, _ := normalizeAddress(op.Address, true)
		amount, _ := config.ParseAmountDecimal(op.Amount)
		total.Add(total, amount)
		operators = append(operators, ReportLine{Name: "operator", Address: addr, Wei: amount.String(), QIK: FormatQIK(amount, maxDecimals)})
	}
	sort.Slice(operators, func(i, j int) bool { return operators[i].Address < operators[j].Address })
	report.Operators = operators

	deployerAddr, _ := normalizeAddress(cfg.Deployer.Address, true)
	deployerAmt, _ := config.ParseAmountDecimal(cfg.Deployer.Amount)
	total.Add(total, deployerAmt)
	report.Deployer = ReportLine{Name: "deployer", Address: deployerAddr, Wei: deployerAmt.String(), QIK: FormatQIK(deployerAmt, maxDecimals)}
	report.TotalPremineWei = total.String()
	report.TotalPremineQIK = FormatQIK(total, maxDecimals)

	return report, nil
}

func FormatQIK(wei *big.Int, maxDecimals int) string {
	if maxDecimals < 0 {
		maxDecimals = 0
	}
	divisor := big.NewInt(1_000_000_000_000_000_000)
	whole := new(big.Int).Div(new(big.Int).Set(wei), divisor)
	rem := new(big.Int).Mod(new(big.Int).Set(wei), divisor)
	if maxDecimals == 0 {
		return whole.String()
	}
	frac := fmt.Sprintf("%018s", rem.String())
	if maxDecimals < len(frac) {
		frac = frac[:maxDecimals]
	}
	frac = strings.TrimRight(frac, "0")
	if frac == "" {
		return whole.String()
	}
	return whole.String() + "." + frac
}
