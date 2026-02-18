package rpc

import (
	"fmt"
	"strconv"
	"strings"
)

func HexToUint64(v string) (uint64, error) {
	v = strings.TrimSpace(v)
	if len(v) < 2 || (v[:2] != "0x" && v[:2] != "0X") {
		return 0, fmt.Errorf("invalid hex value: %q", v)
	}

	raw := strings.TrimPrefix(strings.ToLower(v), "0x")
	if raw == "" {
		return 0, fmt.Errorf("invalid hex value: %q", v)
	}

	n, err := strconv.ParseUint(raw, 16, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid hex value: %q", v)
	}

	return n, nil
}
