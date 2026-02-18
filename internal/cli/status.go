package cli

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/BioMark3r/qikchain/internal/rpc"
	"github.com/spf13/cobra"
)

type statusOutput struct {
	RPC         string `json:"rpc"`
	ChainID     uint64 `json:"chainId"`
	ChainHex    string `json:"chainHex"`
	BlockNumber uint64 `json:"blockNumber"`
	BlockHex    string `json:"blockHex"`
	PeerCount   uint64 `json:"peerCount"`
	PeerHex     string `json:"peerHex"`
	Timestamp   string `json:"timestamp"`
}

func newStatusCmd(cfg *Config) *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Show basic chain status",
		RunE: func(cmd *cobra.Command, args []string) error {
			client := rpc.NewClient(cfg.RPCURL, cfg.Timeout)

			chainHex, err := client.CallString("eth_chainId")
			if err != nil {
				return err
			}
			blockHex, err := client.CallString("eth_blockNumber")
			if err != nil {
				return err
			}
			peerHex, err := client.CallString("net_peerCount")
			if err != nil {
				return err
			}

			chainID, err := rpc.HexToUint64(chainHex)
			if err != nil {
				return err
			}
			blockNumber, err := rpc.HexToUint64(blockHex)
			if err != nil {
				return err
			}
			peerCount, err := rpc.HexToUint64(peerHex)
			if err != nil {
				return err
			}

			if cfg.JSON {
				out := statusOutput{
					RPC:         cfg.RPCURL,
					ChainID:     chainID,
					ChainHex:    chainHex,
					BlockNumber: blockNumber,
					BlockHex:    blockHex,
					PeerCount:   peerCount,
					PeerHex:     peerHex,
					Timestamp:   time.Now().UTC().Format(time.RFC3339),
				}
				body, err := json.MarshalIndent(out, "", "  ")
				if err != nil {
					return err
				}
				fmt.Println(string(body))
				return nil
			}

			fmt.Printf("rpc: %s\n", cfg.RPCURL)
			fmt.Printf("chainId: %d (%s)\n", chainID, chainHex)
			fmt.Printf("blockHead: %d (%s)\n", blockNumber, blockHex)
			fmt.Printf("peerCount: %d (%s)\n", peerCount, peerHex)
			return nil
		},
	}
}
