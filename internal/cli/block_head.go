package cli

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/BioMark3r/qikchain/internal/rpc"
	"github.com/spf13/cobra"
)

type blockHeadOutput struct {
	RPC         string `json:"rpc"`
	BlockNumber uint64 `json:"blockNumber"`
	BlockHex    string `json:"blockHex"`
	Timestamp   string `json:"timestamp"`
}

func newBlockHeadCmd(cfg *Config) *cobra.Command {
	return &cobra.Command{
		Use:   "head",
		Short: "Show latest block number",
		RunE: func(cmd *cobra.Command, args []string) error {
			client := rpc.NewClient(cfg.RPCURL, cfg.Timeout)
			blockHex, err := client.CallString("eth_blockNumber")
			if err != nil {
				return err
			}

			blockNumber, err := rpc.HexToUint64(blockHex)
			if err != nil {
				return err
			}

			if cfg.JSON {
				out := blockHeadOutput{
					RPC:         cfg.RPCURL,
					BlockNumber: blockNumber,
					BlockHex:    blockHex,
					Timestamp:   time.Now().UTC().Format(time.RFC3339),
				}
				body, err := json.MarshalIndent(out, "", "  ")
				if err != nil {
					return err
				}
				fmt.Println(string(body))
				return nil
			}

			fmt.Println(blockNumber)
			return nil
		},
	}
}
