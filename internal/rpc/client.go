package rpc

import (
	"context"
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	gethrpc "github.com/ethereum/go-ethereum/rpc"
)

// Client wraps Ethereum JSON-RPC calls used by qikchain.
type Client struct {
	rpc *gethrpc.Client
}

func Dial(rawURL string) (*Client, error) {
	c, err := gethrpc.Dial(rawURL)
	if err != nil {
		return nil, err
	}

	return &Client{rpc: c}, nil
}

func (c *Client) Close() {
	c.rpc.Close()
}

type Status struct {
	ChainID       string `json:"chainId"`
	BlockNumber   uint64 `json:"blockNumber"`
	ClientVersion string `json:"clientVersion"`
}

func (c *Client) Status(ctx context.Context) (*Status, error) {
	chainID, err := c.ChainID(ctx)
	if err != nil {
		return nil, err
	}

	blockNumber, err := c.BlockNumber(ctx)
	if err != nil {
		return nil, err
	}

	clientVersion, err := c.ClientVersion(ctx)
	if err != nil {
		return nil, err
	}

	return &Status{ChainID: chainID.String(), BlockNumber: blockNumber, ClientVersion: clientVersion}, nil
}

func (c *Client) ChainID(ctx context.Context) (*big.Int, error) {
	var out hexutil.Big
	if err := c.rpc.CallContext(ctx, &out, "eth_chainId"); err != nil {
		return nil, err
	}

	chainID := big.Int(out)
	return &chainID, nil
}

func (c *Client) BlockNumber(ctx context.Context) (uint64, error) {
	var out hexutil.Uint64
	if err := c.rpc.CallContext(ctx, &out, "eth_blockNumber"); err != nil {
		return 0, err
	}

	return uint64(out), nil
}

func (c *Client) ClientVersion(ctx context.Context) (string, error) {
	var out string
	if err := c.rpc.CallContext(ctx, &out, "web3_clientVersion"); err != nil {
		return "", err
	}

	return out, nil
}

type Block struct {
	Number           *hexutil.Big   `json:"number"`
	Hash             common.Hash    `json:"hash"`
	ParentHash       common.Hash    `json:"parentHash"`
	Timestamp        hexutil.Uint64 `json:"timestamp"`
	TransactionsRoot common.Hash    `json:"transactionsRoot"`
	StateRoot        common.Hash    `json:"stateRoot"`
	Miner            common.Address `json:"miner"`
	GasLimit         hexutil.Uint64 `json:"gasLimit"`
	GasUsed          hexutil.Uint64 `json:"gasUsed"`
}

func (c *Client) BlockByNumber(ctx context.Context, numberTag string) (*Block, error) {
	var out *Block
	if err := c.rpc.CallContext(ctx, &out, "eth_getBlockByNumber", numberTag, false); err != nil {
		return nil, err
	}
	if out == nil {
		return nil, fmt.Errorf("block not found")
	}

	return out, nil
}

func (c *Client) TransactionByHash(ctx context.Context, hash common.Hash) (map[string]any, error) {
	var out map[string]any
	if err := c.rpc.CallContext(ctx, &out, "eth_getTransactionByHash", hash); err != nil {
		return nil, err
	}
	if out == nil {
		return nil, fmt.Errorf("transaction not found")
	}

	return out, nil
}

func (c *Client) TransactionReceipt(ctx context.Context, hash common.Hash) (map[string]any, error) {
	var out map[string]any
	if err := c.rpc.CallContext(ctx, &out, "eth_getTransactionReceipt", hash); err != nil {
		return nil, err
	}
	if out == nil {
		return nil, fmt.Errorf("receipt not found")
	}

	return out, nil
}

func (c *Client) BalanceAt(ctx context.Context, address common.Address, blockTag string) (*big.Int, error) {
	var out hexutil.Big
	if err := c.rpc.CallContext(ctx, &out, "eth_getBalance", address, blockTag); err != nil {
		return nil, err
	}

	balance := big.Int(out)
	return &balance, nil
}

func DecimalOrHexToBlockTag(v string) (string, error) {
	if v == "latest" {
		return "latest", nil
	}

	base := 10
	raw := v
	if len(v) > 2 && (v[:2] == "0x" || v[:2] == "0X") {
		base = 16
		raw = v[2:]
	}

	n, ok := new(big.Int).SetString(raw, base)
	if !ok {
		return "", fmt.Errorf("invalid block number: %s", v)
	}
	if n.Sign() < 0 {
		return "", fmt.Errorf("block number must be >= 0")
	}

	return hexutil.EncodeBig(n), nil
}
