# QikChain (v2)

QikChain is a Polygon Edge–based EVM chain with a custom Go CLI for deterministic genesis generation, PoA/PoS switching, and devnet orchestration.

> Design principle: **switching consensus is a configuration change, not a rewrite.**

---

## Contents

- [Overview](#overview)
- [Native Token](#native-token)
- [Architecture](#architecture)
- [Requirements](#requirements)
- [Build](#build)
- [Genesis Pipeline](#genesis-pipeline)
- [Devnet: IBFT 4-node](#devnet-ibft-4-node)
- [Metrics](#metrics)
- [CI / Health Checks](#ci--health-checks)
- [Troubleshooting](#troubleshooting)
- [Repo Layout](#repo-layout)
- [Roadmap](#roadmap)
- [License](#license)

---

## Overview

QikChain provides:

- Deterministic genesis generation (stable outputs for identical inputs)
- Clean PoA ↔ PoS switching via config/flags
- Environment-scoped allocations (devnet/staging/mainnet)
- Devnet scripts: start / stop / status
- Operator-friendly status output (human + JSON, plus tail logs)
- Fixed-supply native token policy (QIK)

---

## Native Token

| Property | Value |
|----------|------|
| Name | QIK |
| Symbol | QIK |
| Decimals | 18 |
| Supply posture | Fixed supply |
| Phase 1 PoS rewards | 0 (disabled) |

Token metadata lives in: `config/token.json`

---

## Architecture

### Important: chain.json vs genesis-eth.json

This Polygon Edge build expects the **chain config** (`--chain`) to reference the **genesis** via a **string path**.

So we generate two artifacts:

- `build/chain.json` — Polygon Edge chain config
- `build/genesis-eth.json` — Ethereum-style genesis

**chain.json (example)**

```json
{
  "name": "qikchain",
  "bootnodes": [],
  "genesis": "/abs/path/to/build/genesis-eth.json",
  "params": {
    "chainID": 100,
    "minGasPrice": "0",
    "engine": {
      "ibft": {
        "type": "PoA",
        "validatorType": "ecdsa",
        "blockTime": "2s"
      }
    }
  }
}
```

**genesis-eth.json (example)**

```json
{
  "alloc": {
    "0x1000000000000000000000000000000000000001": { "balance": "1000000000000000000000000" }
  },
  "gasLimit": "0x1c9c380",
  "difficulty": "0x1",
  "extraData": "0x",
  "baseFeeEnabled": false
}
```

---

## Requirements

- Go (matching repo toolchain)
- `./bin/polygon-edge` available (repo-managed or built separately)
- `curl` recommended (RPC/metrics checks)
- `jq` recommended (status JSON mode & debugging)

---

## Build

Build the CLI:

```bash
go build -o ./bin/qikchain ./cmd/qikchain
```

Verify binaries:

```bash
./bin/qikchain --help
./bin/polygon-edge version || true
```

---

## Genesis Pipeline

### Allocations

Environment allocations live under:

- `config/allocations/devnet.json`
- `config/allocations/staging.json`
- `config/allocations/mainnet.json`

Commands:

```bash
./bin/qikchain allocations verify --file config/allocations/devnet.json
./bin/qikchain allocations report --file config/allocations/devnet.json
./bin/qikchain allocations render --file config/allocations/devnet.json
```

### Build genesis artifacts

PoA devnet example:

```bash
./bin/qikchain genesis build   --consensus poa   --env devnet   --chain-id 100   --allocations config/allocations/devnet.json   --token config/token.json   --out-chain build/chain.json   --out-genesis build/genesis-eth.json
```

Validate:

```bash
./bin/qikchain genesis validate --chain build/chain.json
```

### PoS devnet notes

For Phase 1 PoS:

- Staking enabled
- Validator set contract used
- Rewards disabled (`rewardPerBlock = 0`)

PoS build example:

```bash
./bin/qikchain genesis build   --consensus pos   --env devnet   --chain-id 100   --pos-deployments build/deployments/pos.local.json   --out-chain build/chain.json   --out-genesis build/genesis-eth.json
```

---

## Devnet: IBFT 4-node

Scripts:

- `scripts/devnet-ibft4.sh` — start (PoA or PoS)
- `scripts/devnet-ibft4-stop.sh` — stop
- `scripts/devnet-ibft4-status.sh` — status (human/JSON/logs)

### Start PoA

```bash
INSECURE_SECRETS=1 RESET=1 CONSENSUS=poa ./scripts/devnet-ibft4.sh
```

### Start PoS

```bash
INSECURE_SECRETS=1 RESET=1 CONSENSUS=pos ./scripts/devnet-ibft4.sh
```

### Script configuration knobs

| Variable | Default | Meaning |
|----------|---------|---------|
| `CONSENSUS` | `poa` | `poa` or `pos` |
| `RESET` | `0` | `1` wipes `.data/ibft4` |
| `INSECURE_SECRETS` | `1` | dev-only local key storage |
| `CHAIN_ID` | `100` | chain ID |
| `BLOCK_GAS_LIMIT` | `15000000` | target gas limit |
| `MIN_GAS_PRICE` | `0` | min gas price |
| `BASE_FEE_ENABLED` | `false` | EIP-1559 style base fee toggle |
| `CHAIN_OUT` | `build/chain.json` | chain config output |
| `GENESIS_ETH_OUT` | `build/genesis-eth.json` | ethereum genesis output |

⚠️ **INSECURE_SECRETS=1 is dev-only** (never for production).

### Stop

```bash
./scripts/devnet-ibft4-stop.sh
```

Options:

```bash
FORCE=1 ./scripts/devnet-ibft4-stop.sh
CLEAN_PORTS=1 ./scripts/devnet-ibft4-stop.sh
```

### Status

Human mode:

```bash
./scripts/devnet-ibft4-status.sh
```

Tail logs:

```bash
LOGS=1 LOG_LINES=80 ./scripts/devnet-ibft4-status.sh
LOGS=1 FOLLOW=1 ./scripts/devnet-ibft4-status.sh
```

JSON mode (CI-friendly):

```bash
JSON=1 ./scripts/devnet-ibft4-status.sh | jq .
JSON=1 LOGS=1 LOG_LINES=40 ./scripts/devnet-ibft4-status.sh | jq .
```

---

## Metrics

This Polygon Edge build exposes metrics via:

- `--prometheus <addr:port>`

Not `--metrics`.

Devnet ports:

- node1: http://127.0.0.1:9090/metrics
- node2: http://127.0.0.1:9091/metrics
- node3: http://127.0.0.1:9092/metrics
- node4: http://127.0.0.1:9093/metrics

---

## CI / Health Checks

A simple CI-style check can run:

1) Start devnet
2) Run status in JSON mode
3) Assert `.ok == true` and `.sealing == true`
4) Stop devnet

Example (local):

```bash
set -euo pipefail

INSECURE_SECRETS=1 RESET=1 CONSENSUS=poa ./scripts/devnet-ibft4.sh
sleep 3

JSON=1 ./scripts/devnet-ibft4-status.sh | jq -e '.ok == true and .sealing == true'

./scripts/devnet-ibft4-stop.sh
```

---

## Troubleshooting

### `unknown flag: --metrics`

Your Edge version uses `--prometheus`. Ensure your startup script passes `--prometheus` instead.

### `json: cannot unmarshal number into Go struct field Chain.genesis of type string`

Your chain config must contain:

```json
"genesis": "/path/to/genesis-eth.json"
```

Not an embedded object. Use `build/chain.json` + `build/genesis-eth.json`.

### `consensus object is required`

This usually means you’re running a stale `./bin/qikchain` binary with legacy validation rules.
Rebuild:

```bash
go build -o ./bin/qikchain ./cmd/qikchain
```

### Chain is up but not sealing

- Check node logs for validator/IBFT messages:
  ```bash
  LOGS=1 ./scripts/devnet-ibft4-status.sh
  ```
- Confirm block number advances on node1:
  ```bash
  curl -s -X POST http://127.0.0.1:8545 -H 'content-type: application/json'     --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' | jq .
  ```
- Ensure validators are configured correctly for PoA.

### Ports already in use

Stop the devnet:

```bash
./scripts/devnet-ibft4-stop.sh
```

If something is still holding ports:

```bash
CLEAN_PORTS=1 FORCE=1 ./scripts/devnet-ibft4-stop.sh
```

---

## Repo Layout

```text
bin/
  qikchain
  polygon-edge

build/
  chain.json
  genesis-eth.json
  deployments/        # PoS deployments (devnet)

config/
  token.json
  allocations/
    devnet.json
    staging.json
    mainnet.json
  consensus/
    poa.json
    pos.json
  genesis.template.json

scripts/
  devnet-ibft4.sh
  devnet-ibft4-stop.sh
  devnet-ibft4-status.sh

.data/
  ibft4/
    node1/
    node2/
    node3/
    node4/
```

---

## Roadmap

See `ROADMAP.md`:

- Phase 0: IBFT PoA devnets (current)
- Phase 1: IBFT PoS devnet (same scripts; different overlay + staking management)
- Phase 2: Operator UX (validator onboarding, key management, metrics)
- Phase 3: Production hardening (key backend, snapshots/backups, monitoring/upgrades)

---

## License

TBD
