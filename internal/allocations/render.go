package allocations

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math/big"
	"sort"

	"github.com/BioMark3r/qikchain/internal/config"
)

type renderedEntry struct {
	Address string
	Balance string
}

func RenderAllocMap(cfg config.AllocationConfig) ([]byte, error) {
	data, _, err := RenderAllocMapAndTotal(cfg)
	return data, err
}

func RenderAllocMapAndTotal(cfg config.AllocationConfig) ([]byte, string, error) {
	entries := make([]renderedEntry, 0, len(cfg.Buckets)+len(cfg.Operators)+1)
	total := big.NewInt(0)
	for _, bucket := range cfg.Buckets {
		addr, _ := normalizeAddress(bucket.Address, true)
		entries = append(entries, renderedEntry{Address: addr, Balance: bucket.Amount})
		v, _ := config.ParseAmountDecimal(bucket.Amount)
		total.Add(total, v)
	}
	for _, op := range cfg.Operators {
		addr, _ := normalizeAddress(op.Address, true)
		entries = append(entries, renderedEntry{Address: addr, Balance: op.Amount})
		v, _ := config.ParseAmountDecimal(op.Amount)
		total.Add(total, v)
	}
	addr, _ := normalizeAddress(cfg.Deployer.Address, true)
	entries = append(entries, renderedEntry{Address: addr, Balance: cfg.Deployer.Amount})
	v, _ := config.ParseAmountDecimal(cfg.Deployer.Amount)
	total.Add(total, v)

	sort.Slice(entries, func(i, j int) bool {
		return entries[i].Address < entries[j].Address
	})

	buf := &bytes.Buffer{}
	buf.WriteString("{\n")
	for i, entry := range entries {
		key, _ := json.Marshal(entry.Address)
		obj, _ := json.Marshal(map[string]string{"balance": entry.Balance})
		if _, err := fmt.Fprintf(buf, "  %s: %s", key, obj); err != nil {
			return nil, "", err
		}
		if i < len(entries)-1 {
			buf.WriteString(",")
		}
		buf.WriteString("\n")
	}
	buf.WriteString("}\n")
	return buf.Bytes(), total.String(), nil
}
