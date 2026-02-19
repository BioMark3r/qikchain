package chainmeta

import (
	"encoding/json"
	"fmt"

	"github.com/BioMark3r/qikchain/internal/config"
)

func RenderMetadata(token config.TokenConfig) ([]byte, error) {
	out, err := json.MarshalIndent(token, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("marshal metadata: %w", err)
	}
	return append(out, '\n'), nil
}
