package config

import (
	"encoding/json"
	"fmt"
	"math/big"
	"os"
)

type AllocationEntry struct {
	Address string `json:"address"`
	Amount  string `json:"amount"`
}

type BucketMap map[string]AllocationEntry

type AllocationMeta struct {
	Unit     string `json:"unit"`
	Decimals int    `json:"decimals"`
	Token    string `json:"token"`
}

type AllocationConfig struct {
	Meta      AllocationMeta    `json:"meta"`
	Buckets   BucketMap         `json:"buckets"`
	Operators []AllocationEntry `json:"operators"`
	Deployer  AllocationEntry   `json:"deployer"`
}

func LoadAllocationConfig(path string) (AllocationConfig, error) {
	var cfg AllocationConfig
	data, err := os.ReadFile(path)
	if err != nil {
		return cfg, fmt.Errorf("read allocation config: %w", err)
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return cfg, fmt.Errorf("parse allocation config: %w", err)
	}
	return cfg, nil
}

func ParseAmountDecimal(amount string) (*big.Int, error) {
	value, ok := new(big.Int).SetString(amount, 10)
	if !ok {
		return nil, fmt.Errorf("must be a base-10 integer string")
	}
	if value.Sign() < 0 {
		return nil, fmt.Errorf("must be non-negative")
	}
	return value, nil
}
