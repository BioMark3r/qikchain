package main

import (
	"context"
	"crypto/ecdsa"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"math/big"
	"os"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/ethereum/go-ethereum/rpc"
)

const defaultPrivKey = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
const testDeployBytecode = "0x6001600c60003960016000f300"

type output struct {
	OK              bool    `json:"ok"`
	RPC             string  `json:"rpc"`
	TxHash          string  `json:"txHash"`
	ReceiptStatus   *uint64 `json:"receiptStatus"`
	Mined           bool    `json:"mined"`
	ContractAddress *string `json:"contractAddress,omitempty"`
}

func main() {
	action := flag.String("action", "", "burn|deploy|submit-raw")
	rpcURL := flag.String("rpc", "http://127.0.0.1:8545", "JSON-RPC endpoint")
	toArg := flag.String("to", "0x000000000000000000000000000000000000dEaD", "destination address")
	valueWeiArg := flag.String("valueWei", "1", "value to transfer in wei")
	rawTx := flag.String("rawTx", "", "hex encoded signed tx")
	deployGasCap := flag.Uint64("deployGasCap", 2000000, "max gas for deploy")
	waitReceipt := flag.Bool("waitReceipt", false, "wait for receipt")
	waitTimeoutSec := flag.Int("waitTimeoutSec", 10, "wait timeout in seconds")
	timeoutSec := flag.Int("timeoutSec", 20, "overall timeout in seconds")
	flag.Parse()

	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(*timeoutSec)*time.Second)
	defer cancel()

	var out output
	var err error
	switch *action {
	case "burn":
		out, err = sendNative(ctx, *rpcURL, *toArg, *valueWeiArg, *waitReceipt, *waitTimeoutSec)
	case "deploy":
		out, err = deployTest(ctx, *rpcURL, *deployGasCap, *waitReceipt, *waitTimeoutSec)
	case "submit-raw":
		out, err = submitRaw(ctx, *rpcURL, *rawTx, *waitReceipt, *waitTimeoutSec)
	default:
		err = errors.New("invalid action")
	}

	if err != nil {
		fmt.Fprintf(os.Stderr, "txhelper error: %v\n", err)
		os.Exit(1)
	}

	if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
		fmt.Fprintf(os.Stderr, "encode output: %v\n", err)
		os.Exit(1)
	}
}

func submitRaw(ctx context.Context, rpcURL, rawTx string, wait bool, waitTimeoutSec int) (output, error) {
	trimmed := strings.TrimSpace(rawTx)
	if !strings.HasPrefix(trimmed, "0x") {
		return output{}, errors.New("rawTx must start with 0x")
	}

	rpcClient, err := rpc.DialContext(ctx, rpcURL)
	if err != nil {
		return output{}, fmt.Errorf("dial rpc: %w", err)
	}
	defer rpcClient.Close()

	var hash common.Hash
	if err := rpcClient.CallContext(ctx, &hash, "eth_sendRawTransaction", trimmed); err != nil {
		return output{}, fmt.Errorf("send raw tx: %w", err)
	}

	out := output{OK: true, RPC: rpcURL, TxHash: hash.Hex(), Mined: false, ReceiptStatus: nil}
	if !wait {
		return out, nil
	}

	client := ethclient.NewClient(rpcClient)
	rctx, cancel := context.WithTimeout(ctx, time.Duration(waitTimeoutSec)*time.Second)
	defer cancel()
	receipt, err := waitForReceipt(rctx, client, hash)
	if err != nil {
		return out, nil
	}
	out.Mined = true
	out.ReceiptStatus = &receipt.Status
	return out, nil
}

func deployTest(ctx context.Context, rpcURL string, deployGasCap uint64, wait bool, waitTimeoutSec int) (output, error) {
	privKey, err := loadPrivateKey()
	if err != nil {
		return output{}, err
	}
	client, err := ethclient.DialContext(ctx, rpcURL)
	if err != nil {
		return output{}, fmt.Errorf("dial rpc: %w", err)
	}
	defer client.Close()

	from := crypto.PubkeyToAddress(privKey.PublicKey)
	chainID, nonce, tipCap, feeCap, err := txParams(ctx, client, from)
	if err != nil {
		return output{}, err
	}

	data := common.FromHex(testDeployBytecode)
	gasEstimate, err := client.EstimateGas(ctx, ethereum.CallMsg{From: from, Data: data, GasTipCap: tipCap, GasFeeCap: feeCap})
	if err != nil {
		return output{}, fmt.Errorf("estimate gas: %w", err)
	}
	if gasEstimate > deployGasCap {
		gasEstimate = deployGasCap
	}

	tx := types.NewTx(&types.DynamicFeeTx{ChainID: chainID, Nonce: nonce, GasTipCap: tipCap, GasFeeCap: feeCap, Gas: gasEstimate, Data: data})
	signedTx, err := types.SignTx(tx, types.NewLondonSigner(chainID), privKey)
	if err != nil {
		return output{}, fmt.Errorf("sign tx: %w", err)
	}
	if err := client.SendTransaction(ctx, signedTx); err != nil {
		return output{}, fmt.Errorf("send tx: %w", err)
	}

	out := output{OK: true, RPC: rpcURL, TxHash: signedTx.Hash().Hex(), Mined: false, ReceiptStatus: nil, ContractAddress: nil}
	if !wait {
		return out, nil
	}

	rctx, cancel := context.WithTimeout(ctx, time.Duration(waitTimeoutSec)*time.Second)
	defer cancel()
	receipt, err := waitForReceipt(rctx, client, signedTx.Hash())
	if err != nil {
		return out, nil
	}
	out.Mined = true
	out.ReceiptStatus = &receipt.Status
	if receipt.ContractAddress != (common.Address{}) {
		addr := receipt.ContractAddress.Hex()
		out.ContractAddress = &addr
	}
	return out, nil
}

func sendNative(ctx context.Context, rpcURL, toArg, valueWeiArg string, wait bool, waitTimeoutSec int) (output, error) {
	privKey, err := loadPrivateKey()
	if err != nil {
		return output{}, err
	}
	to := common.HexToAddress(toArg)
	if to == (common.Address{}) && !strings.EqualFold(toArg, "0x0000000000000000000000000000000000000000") {
		return output{}, errors.New("invalid to address")
	}
	valueWei, ok := new(big.Int).SetString(valueWeiArg, 10)
	if !ok || valueWei.Sign() < 0 {
		return output{}, errors.New("invalid valueWei")
	}

	client, err := ethclient.DialContext(ctx, rpcURL)
	if err != nil {
		return output{}, fmt.Errorf("dial rpc: %w", err)
	}
	defer client.Close()

	from := crypto.PubkeyToAddress(privKey.PublicKey)
	chainID, nonce, tipCap, feeCap, err := txParams(ctx, client, from)
	if err != nil {
		return output{}, err
	}
	gasLimit, err := client.EstimateGas(ctx, ethereum.CallMsg{From: from, To: &to, Value: valueWei, GasTipCap: tipCap, GasFeeCap: feeCap})
	if err != nil {
		return output{}, fmt.Errorf("estimate gas: %w", err)
	}

	tx := types.NewTx(&types.DynamicFeeTx{ChainID: chainID, Nonce: nonce, GasTipCap: tipCap, GasFeeCap: feeCap, Gas: gasLimit, To: &to, Value: valueWei})
	signedTx, err := types.SignTx(tx, types.NewLondonSigner(chainID), privKey)
	if err != nil {
		return output{}, fmt.Errorf("sign tx: %w", err)
	}
	if err := client.SendTransaction(ctx, signedTx); err != nil {
		return output{}, fmt.Errorf("send tx: %w", err)
	}

	out := output{OK: true, RPC: rpcURL, TxHash: signedTx.Hash().Hex(), Mined: false, ReceiptStatus: nil}
	if !wait {
		return out, nil
	}

	rctx, cancel := context.WithTimeout(ctx, time.Duration(waitTimeoutSec)*time.Second)
	defer cancel()
	receipt, err := waitForReceipt(rctx, client, signedTx.Hash())
	if err != nil {
		return out, nil
	}
	out.Mined = true
	out.ReceiptStatus = &receipt.Status
	return out, nil
}

func txParams(ctx context.Context, client *ethclient.Client, from common.Address) (*big.Int, uint64, *big.Int, *big.Int, error) {
	chainID, err := client.ChainID(ctx)
	if err != nil {
		return nil, 0, nil, nil, fmt.Errorf("fetch chain id: %w", err)
	}
	nonce, err := client.PendingNonceAt(ctx, from)
	if err != nil {
		return nil, 0, nil, nil, fmt.Errorf("fetch pending nonce: %w", err)
	}
	tipCap, err := client.SuggestGasTipCap(ctx)
	if err != nil {
		return nil, 0, nil, nil, fmt.Errorf("suggest gas tip cap: %w", err)
	}
	head, err := client.HeaderByNumber(ctx, nil)
	if err != nil {
		return nil, 0, nil, nil, fmt.Errorf("fetch latest header: %w", err)
	}
	if head.BaseFee == nil {
		return nil, 0, nil, nil, errors.New("latest header has no baseFee")
	}
	feeCap := new(big.Int).Mul(head.BaseFee, big.NewInt(2))
	feeCap.Add(feeCap, tipCap)
	return chainID, nonce, tipCap, feeCap, nil
}

func loadPrivateKey() (*ecdsa.PrivateKey, error) {
	privHex := strings.TrimSpace(os.Getenv("CI_FUNDER_PRIVKEY"))
	if privHex == "" {
		privHex = defaultPrivKey
	}
	return parsePrivateKey(privHex)
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
