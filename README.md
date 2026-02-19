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

## PoS devnet (Phase 1 enablement)

QikChain now supports a PoS-oriented IBFT devnet flow using the same network scripts with a consensus/config flip.

### Prerequisites

- `jq`, `curl`
- Foundry (`cast`, `forge`) for contract deployment and bootstrap scripts

### Flow

1. Generate PoS genesis:

```bash
CONSENSUS=pos ./scripts/generate-genesis.sh
```

> If `build/deployments/pos.local.json` does not have deployed addresses yet, genesis generation keeps placeholders and prints a warning.

2. Start network (existing script):

```bash
CONSENSUS=pos ./scripts/devnet-ibft4.sh
```

3. Deploy PoS system contracts:

```bash
export POS_DEPLOYER_PK=0x...
./scripts/deploy-pos-contracts.sh
```

4. Bootstrap validators:

```bash
# example if operator keys are needed:
# export OPERATOR0_PK=0x...
./scripts/bootstrap-pos-validators.sh
```

5. Validate smoke checks:

```bash
./scripts/pos-smoke.sh
```

### Optional convenience wrapper

```bash
export POS_DEPLOYER_PK=0x...
./scripts/pos-devnet-up.sh
```

### Config files

- `config/pos.contracts.json`: PoS system contract deployment + init parameters
- `config/pos.bootstrap.json`: initial operator bootstrap input (operator, payout, consensus key, stake)
- `build/deployments/pos.local.json`: generated deployment record consumed by genesis and bootstrap scripts
