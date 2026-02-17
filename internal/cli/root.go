package cli

import (
	"context"
	"crypto/ecdsa"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"strconv"
	"strings"
	"time"

	qikr "github.com/BioMark3r/qikchain/internal/rpc"
	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/spf13/cobra"
)

const defaultRPC = "http://127.0.0.1:8545"

func NewRootCmd() *cobra.Command {
	var rpcURL string

	root := &cobra.Command{
		Use:   "qikchain",
		Short: "qikchain CLI for Ethereum JSON-RPC",
	}

	root.PersistentFlags().StringVar(&rpcURL, "rpc", defaultRPC, "JSON-RPC endpoint")

	root.AddCommand(newStatusCmd(&rpcURL))
	root.AddCommand(newBlockCmd(&rpcURL))
	root.AddCommand(newTxCmd(&rpcURL))
	root.AddCommand(newReceiptCmd(&rpcURL))
	root.AddCommand(newBalanceCmd(&rpcURL))
	root.AddCommand(newSendCmd(&rpcURL))

	return root
}

func Execute() {
	if err := NewRootCmd().Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func newStatusCmd(rpcURL *string) *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Get chain status",
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := context.WithTimeout(cmd.Context(), 10*time.Second)
			defer cancel()

			client, err := qikr.Dial(*rpcURL)
			if err != nil {
				return err
			}
			defer client.Close()

			status, err := client.Status(ctx)
			if err != nil {
				return err
			}

			return printJSON(status)
		},
	}
}

func newBlockCmd(rpcURL *string) *cobra.Command {
	blockCmd := &cobra.Command{Use: "block", Short: "Get block information"}

	headCmd := &cobra.Command{
		Use:   "head",
		Short: "Get latest block",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runBlockByTag(cmd, *rpcURL, "latest")
		},
	}

	byNumberCmd := &cobra.Command{
		Use:   "<number|latest>",
		Short: "Get block by number or latest",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			tag, err := qikr.DecimalOrHexToBlockTag(args[0])
			if err != nil {
				return err
			}

			return runBlockByTag(cmd, *rpcURL, tag)
		},
	}

	blockCmd.AddCommand(headCmd, byNumberCmd)
	return blockCmd
}

func runBlockByTag(cmd *cobra.Command, rpcURL string, tag string) error {
	ctx, cancel := context.WithTimeout(cmd.Context(), 10*time.Second)
	defer cancel()

	client, err := qikr.Dial(rpcURL)
	if err != nil {
		return err
	}
	defer client.Close()

	block, err := client.BlockByNumber(ctx, tag)
	if err != nil {
		return err
	}

	return printJSON(block)
}

func newTxCmd(rpcURL *string) *cobra.Command {
	return &cobra.Command{
		Use:   "tx <hash>",
		Short: "Get transaction by hash",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			hash := common.HexToHash(args[0])
			ctx, cancel := context.WithTimeout(cmd.Context(), 10*time.Second)
			defer cancel()

			client, err := qikr.Dial(*rpcURL)
			if err != nil {
				return err
			}
			defer client.Close()

			tx, err := client.TransactionByHash(ctx, hash)
			if err != nil {
				return err
			}

			return printJSON(tx)
		},
	}
}

func newReceiptCmd(rpcURL *string) *cobra.Command {
	return &cobra.Command{
		Use:   "receipt <hash>",
		Short: "Get transaction receipt by hash",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			hash := common.HexToHash(args[0])
			ctx, cancel := context.WithTimeout(cmd.Context(), 10*time.Second)
			defer cancel()

			client, err := qikr.Dial(*rpcURL)
			if err != nil {
				return err
			}
			defer client.Close()

			receipt, err := client.TransactionReceipt(ctx, hash)
			if err != nil {
				return err
			}

			return printJSON(receipt)
		},
	}
}

func newBalanceCmd(rpcURL *string) *cobra.Command {
	var block string

	cmd := &cobra.Command{
		Use:   "balance <address>",
		Short: "Get address balance",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			address := common.HexToAddress(args[0])
			blockTag, err := qikr.DecimalOrHexToBlockTag(block)
			if err != nil {
				return err
			}

			ctx, cancel := context.WithTimeout(cmd.Context(), 10*time.Second)
			defer cancel()

			client, err := qikr.Dial(*rpcURL)
			if err != nil {
				return err
			}
			defer client.Close()

			bal, err := client.BalanceAt(ctx, address, blockTag)
			if err != nil {
				return err
			}

			result := map[string]string{
				"address": address.Hex(),
				"block":   blockTag,
				"balance": bal.String(),
			}

			return printJSON(result)
		},
	}

	cmd.Flags().StringVar(&block, "block", "latest", "Block tag: latest or block number")
	return cmd
}

func newSendCmd(rpcURL *string) *cobra.Command {
	var to string
	var value string
	var pk string
	var gas uint64
	var maxFee string
	var priorityFee string
	var chainIDFlag int64

	cmd := &cobra.Command{
		Use:   "send --to <address> --value <wei> --pk <hex>",
		Short: "Sign and send transaction",
		RunE: func(cmd *cobra.Command, args []string) error {
			if to == "" || value == "" || pk == "" {
				return fmt.Errorf("--to, --value, and --pk are required")
			}

			toAddr := common.HexToAddress(to)
			valueWei, err := parseBigInt(value)
			if err != nil {
				return fmt.Errorf("invalid --value: %w", err)
			}

			privateKey, err := parsePrivateKey(pk)
			if err != nil {
				return err
			}

			ctx, cancel := context.WithTimeout(cmd.Context(), 20*time.Second)
			defer cancel()

			eclient, err := ethclient.DialContext(ctx, *rpcURL)
			if err != nil {
				return err
			}
			defer eclient.Close()

			from := crypto.PubkeyToAddress(privateKey.PublicKey)

			nonce, err := eclient.PendingNonceAt(ctx, from)
			if err != nil {
				return err
			}

			gasLimit := gas
			if gasLimit == 0 {
				gasLimit, err = eclient.EstimateGas(ctx, ethereum.CallMsg{From: from, To: &toAddr, Value: valueWei})
				if err != nil {
					return err
				}
			}

			chainID := big.NewInt(chainIDFlag)
			if chainIDFlag == 0 {
				chainID, err = eclient.ChainID(ctx)
				if err != nil {
					return err
				}
			}

			header, err := eclient.HeaderByNumber(ctx, nil)
			if err != nil {
				return err
			}

			var signedTx *types.Transaction
			if header.BaseFee == nil && maxFee == "" && priorityFee == "" {
				gasPrice, err := eclient.SuggestGasPrice(ctx)
				if err != nil {
					return err
				}

				tx := types.NewTx(&types.LegacyTx{Nonce: nonce, To: &toAddr, Value: valueWei, Gas: gasLimit, GasPrice: gasPrice})
				signedTx, err = types.SignTx(tx, types.LatestSignerForChainID(chainID), privateKey)
				if err != nil {
					return err
				}
			} else {
				tipCap, err := resolveTipCap(ctx, eclient, priorityFee)
				if err != nil {
					return err
				}

				feeCap, err := resolveFeeCap(ctx, eclient, maxFee, header.BaseFee, tipCap)
				if err != nil {
					return err
				}

				tx := types.NewTx(&types.DynamicFeeTx{
					ChainID:   chainID,
					Nonce:     nonce,
					GasTipCap: tipCap,
					GasFeeCap: feeCap,
					Gas:       gasLimit,
					To:        &toAddr,
					Value:     valueWei,
				})
				signedTx, err = types.SignTx(tx, types.LatestSignerForChainID(chainID), privateKey)
				if err != nil {
					return err
				}
			}

			if err := eclient.SendTransaction(ctx, signedTx); err != nil {
				return err
			}

			return printJSON(map[string]string{
				"from": from.Hex(),
				"to":   toAddr.Hex(),
				"hash": signedTx.Hash().Hex(),
			})
		},
	}

	cmd.Flags().StringVar(&to, "to", "", "Recipient address")
	cmd.Flags().StringVar(&value, "value", "", "Amount in wei (decimal or 0x-hex)")
	cmd.Flags().StringVar(&pk, "pk", "", "Private key (hex)")
	cmd.Flags().Uint64Var(&gas, "gas", 0, "Gas limit (estimated if omitted)")
	cmd.Flags().StringVar(&maxFee, "max-fee", "", "Max fee per gas in wei")
	cmd.Flags().StringVar(&priorityFee, "priority-fee", "", "Priority fee per gas in wei")
	cmd.Flags().Int64Var(&chainIDFlag, "chain-id", 0, "Chain ID (fetched via RPC if omitted)")

	return cmd
}

func parsePrivateKey(raw string) (*ecdsa.PrivateKey, error) {
	clean := strings.TrimPrefix(raw, "0x")
	pk, err := crypto.HexToECDSA(clean)
	if err != nil {
		return nil, fmt.Errorf("invalid --pk: %w", err)
	}
	return pk, nil
}

func resolveTipCap(ctx context.Context, client *ethclient.Client, raw string) (*big.Int, error) {
	if raw != "" {
		return parseBigInt(raw)
	}
	return client.SuggestGasTipCap(ctx)
}

func resolveFeeCap(ctx context.Context, client *ethclient.Client, raw string, baseFee *big.Int, tipCap *big.Int) (*big.Int, error) {
	if raw != "" {
		return parseBigInt(raw)
	}

	if baseFee == nil {
		return client.SuggestGasPrice(ctx)
	}

	fee := new(big.Int).Mul(baseFee, big.NewInt(2))
	return fee.Add(fee, tipCap), nil
}

func parseBigInt(raw string) (*big.Int, error) {
	if strings.HasPrefix(raw, "0x") || strings.HasPrefix(raw, "0X") {
		v, ok := new(big.Int).SetString(raw[2:], 16)
		if !ok {
			return nil, fmt.Errorf("invalid hex value: %s", raw)
		}
		return v, nil
	}

	if isDigits(raw) {
		v, ok := new(big.Int).SetString(raw, 10)
		if !ok {
			return nil, fmt.Errorf("invalid decimal value: %s", raw)
		}
		return v, nil
	}

	if n, err := strconv.ParseInt(raw, 10, 64); err == nil {
		return big.NewInt(n), nil
	}

	return nil, fmt.Errorf("invalid numeric value: %s", raw)
}

func isDigits(v string) bool {
	if v == "" {
		return false
	}
	for _, r := range v {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

func printJSON(v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	fmt.Println(string(b))
	return nil
}
