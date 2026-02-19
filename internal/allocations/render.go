package allocations

import (
	"bytes"
	"encoding/json"
	"fmt"
	"sort"

	"github.com/BioMark3r/qikchain/internal/config"
)

type renderedEntry struct {
	Address string
	Balance string
}

func RenderAllocMap(cfg config.AllocationConfig) ([]byte, error) {
	entries := make([]renderedEntry, 0, len(cfg.Buckets)+len(cfg.Operators)+1)
	for _, bucket := range cfg.Buckets {
		addr, _ := normalizeAddress(bucket.Address, true)
		entries = append(entries, renderedEntry{Address: addr, Balance: bucket.Amount})
	}
	for _, op := range cfg.Operators {
		addr, _ := normalizeAddress(op.Address, true)
		entries = append(entries, renderedEntry{Address: addr, Balance: op.Amount})
	}
	addr, _ := normalizeAddress(cfg.Deployer.Address, true)
	entries = append(entries, renderedEntry{Address: addr, Balance: cfg.Deployer.Amount})

	sort.Slice(entries, func(i, j int) bool {
		return entries[i].Address < entries[j].Address
	})

	buf := &bytes.Buffer{}
	buf.WriteString("{\n")
	for i, entry := range entries {
		key, _ := json.Marshal(entry.Address)
		obj, _ := json.Marshal(map[string]string{"balance": entry.Balance})
		if _, err := fmt.Fprintf(buf, "  %s: %s", key, obj); err != nil {
			return nil, err
		}
		if i < len(entries)-1 {
			buf.WriteString(",")
		}
		buf.WriteString("\n")
	}
	buf.WriteString("}\n")
	return buf.Bytes(), nil
}
