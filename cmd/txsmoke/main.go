package main

import (
	"context"
	"crypto/ecdsa"
	"encoding/hex"
	"flag"
	"fmt"
	"log"
	"math/big"
	"os"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
)

const defaultPrivKey = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

func main() {
	rpcURL := flag.String("rpc", "http://127.0.0.1:8545", "JSON-RPC endpoint")
	toArg := flag.String("to", "0x000000000000000000000000000000000000dEaD", "destination address")
	valueWeiArg := flag.String("valueWei", "1", "value to transfer in wei")
	timeout := flag.Duration("timeout", 45*time.Second, "overall timeout")
	flag.Parse()

	privHex := strings.TrimSpace(os.Getenv("CI_FUNDER_PRIVKEY"))
	if privHex == "" {
		privHex = defaultPrivKey
		log.Printf("CI_FUNDER_PRIVKEY not set, using default dev key")
	}

	privKey, err := parsePrivateKey(privHex)
	if err != nil {
		log.Fatalf("invalid CI_FUNDER_PRIVKEY: %v", err)
	}

	to := common.HexToAddress(*toArg)
	if to == (common.Address{}) && !strings.EqualFold(*toArg, "0x0000000000000000000000000000000000000000") {
		log.Fatalf("invalid --to address: %s", *toArg)
	}

	valueWei, ok := new(big.Int).SetString(*valueWeiArg, 10)
	if !ok || valueWei.Sign() < 0 {
		log.Fatalf("invalid --valueWei value: %s", *valueWeiArg)
	}

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()

	client, err := ethclient.DialContext(ctx, *rpcURL)
	if err != nil {
		log.Fatalf("dial rpc: %v", err)
	}
	defer client.Close()

	from := crypto.PubkeyToAddress(privKey.PublicKey)

	chainID, err := client.ChainID(ctx)
	if err != nil {
		log.Fatalf("fetch chain id: %v", err)
	}

	nonce, err := client.PendingNonceAt(ctx, from)
	if err != nil {
		log.Fatalf("fetch pending nonce: %v", err)
	}

	tipCap, err := client.SuggestGasTipCap(ctx)
	if err != nil {
		log.Fatalf("suggest gas tip cap: %v", err)
	}

	head, err := client.HeaderByNumber(ctx, nil)
	if err != nil {
		log.Fatalf("fetch latest header: %v", err)
	}
	if head.BaseFee == nil {
		log.Fatalf("latest header has no baseFee; EIP-1559 unavailable")
	}

	feeCap := new(big.Int).Mul(head.BaseFee, big.NewInt(2))
	feeCap.Add(feeCap, tipCap)

	callMsg := ethereum.CallMsg{
		From:      from,
		To:        &to,
		Value:     valueWei,
		GasFeeCap: feeCap,
		GasTipCap: tipCap,
		Data:      nil,
	}
	gasLimit, err := client.EstimateGas(ctx, callMsg)
	if err != nil {
		log.Fatalf("estimate gas: %v", err)
	}

	tx := types.NewTx(&types.DynamicFeeTx{
		ChainID:   chainID,
		Nonce:     nonce,
		GasTipCap: tipCap,
		GasFeeCap: feeCap,
		Gas:       gasLimit,
		To:        &to,
		Value:     valueWei,
		Data:      nil,
	})

	signedTx, err := types.SignTx(tx, types.NewLondonSigner(chainID), privKey)
	if err != nil {
		log.Fatalf("sign tx: %v", err)
	}

	if err := client.SendTransaction(ctx, signedTx); err != nil {
		log.Fatalf("send tx: %v", err)
	}

	fmt.Printf("tx_hash=%s from=%s to=%s\n", signedTx.Hash().Hex(), from.Hex(), to.Hex())

	receipt, err := waitForReceipt(ctx, client, signedTx.Hash())
	if err != nil {
		log.Fatalf("wait for receipt: %v", err)
	}

	fmt.Printf("receipt_status=%d block=%d gas_used=%d\n", receipt.Status, receipt.BlockNumber.Uint64(), receipt.GasUsed)
	if receipt.Status != types.ReceiptStatusSuccessful {
		log.Fatalf("transaction failed: receipt.status=%d", receipt.Status)
	}
}

func parsePrivateKey(raw string) (*ecdsa.PrivateKey, error) {
	trimmed := strings.TrimPrefix(strings.TrimSpace(raw), "0x")
	if len(trimmed) != 64 {
		return nil, fmt.Errorf("expected 32-byte hex key, got %d hex chars", len(trimmed))
	}
	if _, err := hex.DecodeString(trimmed); err != nil {
		return nil, fmt.Errorf("decode hex: %w", err)
	}
	return crypto.HexToECDSA(trimmed)
}

func waitForReceipt(ctx context.Context, client *ethclient.Client, hash common.Hash) (*types.Receipt, error) {
	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()

	for {
		receipt, err := client.TransactionReceipt(ctx, hash)
		if err == nil {
			return receipt, nil
		}

		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-ticker.C:
		}
	}
}
