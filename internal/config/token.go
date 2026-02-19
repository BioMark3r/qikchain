package config

import (
	"encoding/json"
	"fmt"
	"os"
)

type TokenConfig struct {
	Name             string `json:"name"`
	Symbol           string `json:"symbol"`
	Decimals         int    `json:"decimals"`
	SupplyPolicy     string `json:"supplyPolicy"`
	Phase1PosRewards string `json:"phase1PosRewards"`
}

func LoadTokenConfig(path string) (TokenConfig, error) {
	var cfg TokenConfig
	data, err := os.ReadFile(path)
	if err != nil {
		return cfg, fmt.Errorf("read token config: %w", err)
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return cfg, fmt.Errorf("parse token config: %w", err)
	}
	return cfg, nil
}
