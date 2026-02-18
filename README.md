# QikChain

QikChain is a lightweight EVM-compatible blockchain built on Polygon Edge.

## Features

- IBFT PoA (4-validator devnet)
- Prometheus metrics
- Dockerized build (Go 1.20)
- JSON-RPC exposed on 8545+
- `qikchain` CLI for Polygon Edge JSON-RPC

## Build

```bash
make all
```

## CLI

Default RPC endpoint is `http://127.0.0.1:8545` (override with `--rpc`).

```bash
qikchain status
qikchain block head
qikchain block latest
qikchain block 100
qikchain tx 0x...
qikchain receipt 0x...
qikchain balance 0x... --block latest
qikchain send --to 0x... --value 1000000000000000000 --pk 0x...
```
