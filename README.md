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

### Important: combined genesis is the default for this Polygon Edge build

This repo’s Polygon Edge build expects `--chain` to point to a **combined genesis** document where `.genesis` is an embedded object.

Default output:

- `build/genesis.json` — combined chain config + embedded Ethereum genesis (used by devnet scripts)

Optional split outputs are still supported for alternate tooling/builds:

- `build/chain.json` — chain config with `genesis` as a string path
- `build/genesis-eth.json` — Ethereum-style genesis file

**combined genesis.json (example)**

```json
{
  "name": "qikchain",
  "bootnodes": [],
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
  },
  "genesis": {
    "alloc": {
      "0x1000000000000000000000000000000000000001": { "balance": "1000000000000000000000000" }
    },
    "gasLimit": "0x1c9c380",
    "difficulty": "0x1",
    "extraData": "0x",
    "baseFeeEnabled": false
  }
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
./bin/qikchain genesis build   --consensus poa   --env devnet   --chain-id 100   --allocations config/allocations/devnet.json   --token config/token.json   --out-combined build/genesis.json   --out-chain build/chain.json   --out-genesis build/genesis-eth.json
```

Validate:

```bash
./bin/qikchain genesis validate --chain build/genesis.json
```

### PoS devnet notes

For Phase 1 PoS:

- Staking enabled
- Validator set contract used
- Rewards disabled (`rewardPerBlock = 0`)

PoS build example:

```bash
./bin/qikchain genesis build   --consensus pos   --env devnet   --chain-id 100   --pos-deployments build/deployments/pos.local.json   --out-combined build/genesis.json   --out-chain build/chain.json   --out-genesis build/genesis-eth.json
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

### Docker Compose devnet (4-node IBFT)

Use the containerized devnet when you want a reproducible 4-node network with persistent named volumes:

```bash
docker compose -f docker-compose.devnet.yml up --build
```

RPC endpoints from host:

- node1: `http://localhost:8545`
- node2: `http://localhost:8546`
- node3: `http://localhost:8547`
- node4: `http://localhost:8548`

Quick check peer connectivity:

```bash
curl -s -X POST http://localhost:8545 \
  -H "content-type: application/json" \
  --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"net_peerCount\",\"params\":[]}"
```

Reset the docker devnet (removes named volumes and chain state):

```bash
docker compose -f docker-compose.devnet.yml down -v
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
| `GENESIS_OUT` | `build/genesis.json` | combined chain config + embedded genesis (used by devnet) |
| `CHAIN_OUT` | `build/chain.json` | split chain config output (optional) |
| `GENESIS_ETH_OUT` | `build/genesis-eth.json` | split ethereum genesis output (optional) |

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

Run the dedicated CI healthcheck locally:

```bash
bash scripts/ci/healthcheck-devnet.sh
```

What it validates:

1) Starts a fresh PoA IBFT devnet (`INSECURE_SECRETS=1 RESET=1 CONSENSUS=poa`)
2) Waits for node1 RPC readiness
3) Polls `JSON=1 ./scripts/devnet-ibft4-status.sh` until:
   - `.ok == true`
   - `.sealing == true`
   - `node1.rpc.peerCountHex >= 0x1` when available
4) Prints diagnostics on failure (status JSON, node1 log tail, listener ports)
5) Always stops devnet on exit (success or failure)

---

## Troubleshooting

### `unknown flag: --metrics`

Your Edge version uses `--prometheus`. Ensure your startup script passes `--prometheus` instead.

### `json: cannot unmarshal string into Go struct field Chain.genesis of type chain.Genesis`

Your Edge build expects an embedded genesis object in the file passed to `--chain`.
Use the combined output:

```bash
./bin/qikchain genesis build --out-combined build/genesis.json
./bin/polygon-edge server --chain build/genesis.json ...
```

Use split outputs (`build/chain.json` + `build/genesis-eth.json`) only for alternate tooling/builds that require a string genesis path.

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
  genesis.json
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
