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
- [Releases](#releases)
- [Genesis Pipeline](#genesis-pipeline)
- [Devnet: IBFT 4-node](#devnet-ibft-4-node)
- [Metrics](#metrics)
- [Network Status UI](#network-status-ui)
- [TX Lab (Dev-only Transaction Testing UI)](#tx-lab-dev-only-transaction-testing-ui)
- [Wallet + Faucet (Devnet)](#wallet--faucet-devnet)
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


## Releases

Artifacts are published automatically to GitHub Releases when you push a semantic version tag (`vX.Y.Z`).

Cut a release:

```bash
git tag vX.Y.Z
git push --tags
```

The release workflow builds deterministic-leaning archives for:

- `linux/amd64`
- `linux/arm64`

Each archive is uploaded as `qikchain_<os>_<arch>.tar.gz` and a `SHA256SUMS` file is attached to the release.

Artifacts are created under `dist/` in CI and for local builds. To produce the same output locally:

```bash
make release-local
```

Verify checksums after downloading release assets:

```bash
sha256sum -c SHA256SUMS
```

Reproducible build settings used by release builds:

- `-trimpath`
- `-buildvcs=false`
- `-ldflags` with `main.version`, `main.commit`, and `main.date`

`main.date` is derived from the tagged commit timestamp (`SOURCE_DATE_EPOCH` in CI) for stable metadata across reruns of the same commit.

---

## Edge capability detection

Use `qikchain edge caps` to detect Polygon Edge CLI capabilities for scripts and genesis builders.

Human-readable report:

```bash
./bin/qikchain edge caps
```

Machine-readable JSON:

```bash
./bin/qikchain edge caps --json
./bin/qikchain edge caps --json --pretty
```

Optional flags:

- `--edge-bin` path to the edge binary (default `./bin/polygon-edge`)
- `--timeout` command timeout for external edge calls (default `3s`)

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

## Devnet Management

Use Make targets as a state-aware devnet manager:

```bash
make up
make down
make reset
make status
make logs
```

Notes:

- `make up` is idempotent: it reuses existing `build/genesis.json` and skips regeneration when present.
- `make up RESET=1` behaves like reset and wipes prior chain state + genesis before starting.
- `make reset` stops devnet, removes `build/genesis.json` and `.data/`, then starts fresh.
- `make status` returns success only when PID is alive *and* RPC health checks (`eth_blockNumber`) succeed.
- `make logs` tails `.logs/devnet.log` (use `make logs-follow` to stream).

## Devnet: IBFT 4-node

Scripts:

- `scripts/devnet-ibft4.sh` — start (PoA or PoS)
- `scripts/devnet-ibft4-stop.sh` — stop
- `scripts/devnet-ibft4-status.sh` — status (human/JSON/logs)

### Start PoA

```bash
make up
```

### Devnet Startup

Normal start:

```bash
make up
```

If `build/genesis.json` already exists, startup now reuses it and prints:

```text
Genesis already exists — skipping generation.
```

Reset chain:

```bash
make up RESET=1
```

When `RESET=1`, startup wipes prior chain state (`.data/`) and removes `build/genesis.json` before regenerating genesis artifacts.

`make up` is idempotent when `build/genesis.json` is unchanged. If existing node data was initialized with a different genesis, startup fails fast with:

```text
Genesis changed since this data dir was initialized.
Run: make up RESET=1
```

Reset and rebuild devnet state when genesis inputs change:

```bash
make up RESET=1
```

### Docker Compose devnet (4-node IBFT)

Use the containerized devnet when you want a reproducible 4-node network with persistent named volumes:

```bash
docker compose up --build
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
docker compose down -v
```

You can also use Make targets:

```bash
make docker-devnet-up
make docker-devnet-logs
make docker-devnet-down        # stop containers
make docker-devnet-down RESET=1 # stop + remove volumes
```

### Start PoS

```bash
make up RESET=1 CONSENSUS=pos
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
make down
```

Options:

```bash
make down
```

### Status

Human mode:

```bash
make status
```

Tail logs:

```bash
make logs
make logs-follow
```

JSON mode (CI-friendly):

```bash
JSON=1 ./scripts/devnet-ibft4-status.sh | jq .
JSON=1 LOGS=1 LOG_LINES=40 ./scripts/devnet-ibft4-status.sh | jq .
```

---

## Network Status UI

The repository includes a tiny status dashboard backed by the existing `qikchain` CLI.

Start the UI (background/nohup):

```bash
make status-ui
```

`make status-ui` now:

- Installs dependencies (`npm ci` when `package-lock.json` exists, otherwise `npm install`)
- Runs the server in the background with `nohup`
- Writes process state to `.data/status-ui/status-ui.pid`
- Writes logs to `.data/status-ui/status-ui.log`
- Defaults to `STATUS_UI_HOST=0.0.0.0`, `STATUS_UI_PORT=8788`, and
  `RPC_URLS=http://127.0.0.1:8545,http://127.0.0.1:8546,http://127.0.0.1:8547,http://127.0.0.1:8548`
- Calls `http://127.0.0.1:<STATUS_UI_PORT>/api/status` for readiness checks
- Is idempotent (if already running, it reports the existing process and exits)

Examples:

```bash
# custom RPC endpoints
RPC_URLS="http://127.0.0.1:8545,http://127.0.0.1:8546" make status-ui

# bind loopback only
STATUS_UI_HOST=127.0.0.1 STATUS_UI_PORT=8788 make status-ui

# hardened mode
READONLY_PROD=1 \
AUTH_USER=admin \
AUTH_PASS=strongpassword \
CACHE_MS=2000 \
STATUS_UI_HOST=127.0.0.1 \
STATUS_UI_PORT=8788 \
make status-ui
```

Stop and logs:

```bash
make stop-ui
make status-ui-logs
make status-ui-status
```

Environment overrides:

- `RPC_URLS` (comma-separated list)
- `RPC_URL` (single-endpoint fallback when `RPC_URLS` is unset)
- `CACHE_MS` (default: `1000`)
- `READONLY_PROD` (`1` enables hardening mode)
- `AUTH_USER` and `AUTH_PASS` (enable basic auth only when both are set)
- `STATUS_UI_HOST` (default: `0.0.0.0`)
- `STATUS_UI_PORT` (default: `8788`)
- `RPC_TIMEOUT_MS` (default: `2000`, per-RPC request timeout)

Security note:

- Binding to `0.0.0.0` exposes the UI on all network interfaces. On shared/public hosts, protect access with `AUTH_USER` + `AUTH_PASS`, firewall/VPN rules, and consider `READONLY_PROD=1`.

Status API highlights:

- `GET /api/status` returns cached status with summary fields including `minBlockHead`, `maxBlockHead`, and `headDivergence`.
- `DIVERGENCE_WARN` (default: `3`) marks status degraded when at least 2 nodes are up and divergence exceeds the threshold.
- `GET /healthz` reuses the same cache and returns `200` when healthy, otherwise `503`.

Security and auth:

- `AUTH_USER` + `AUTH_PASS` enables Basic Auth globally for `/`, `/api/status`, `/healthz`, and tx endpoints.
- `READONLY_PROD=1` hardens output and defaults host to `127.0.0.1`.

Transaction features (disabled by default):

- Tx API routes are available under `/api/tx/*` and are always token-gated.
- Server-side gate behavior:
  - `READONLY=1` → tx routes return `403 {"error":"readonly"}`.
  - Missing `TX_TOKEN` → tx routes return `503 {"error":"tx_disabled"}`.
  - Wrong `X-TX-TOKEN` header → tx routes return `401 {"error":"unauthorized"}`.
- UI config endpoint:
  - `GET /api/config` returns `{ readonly: boolean, txEnabled: boolean }`.

Enable tx actions for dev/testing:

```bash
export TX_TOKEN=replace-with-strong-shared-secret
export TX_FROM_PRIVATE_KEY=0x<dev-only-private-key>
export RPC_URL=http://127.0.0.1:8545
# optional
export BURN_ADDRESS=0x000000000000000000000000000000000000dEaD
export CHAIN_ID=1101
```

Run in safe readonly prod mode:

```bash
export READONLY=1
unset TX_TOKEN
unset TX_FROM_PRIVATE_KEY
```

⚠️ Warning: `TX_FROM_PRIVATE_KEY` is for dev-only flows. Never use funded mainnet/private production keys.

Safety limits:

- JSON request body is limited to 16kb.
- `TX_RATE_LIMIT_PER_MIN` (default: `10`) per IP across tx endpoints.
- `RAW_TX_MAX_BYTES` (default: `8192`) for `/api/tx/send-raw`.
- `DEPLOY_GAS_CAP` (default: `2000000`) for test deploy.

Write endpoints:

- `POST /api/tx/send-wei` sends 1 wei to burn address.
- `POST /api/tx/deploy-test-contract` deploys an embedded minimal test contract bytecode.
- `POST /api/tx/send-raw` forwards a pre-signed raw transaction.

Examples:

Send 1 wei:

```bash
curl -u user:pass -H "X-TX-TOKEN: $TX_TOKEN" -H "content-type: application/json"   -d '{"rpcUrl":"http://127.0.0.1:8545"}' http://127.0.0.1:8788/api/tx/send-wei
```

Deploy test contract:

```bash
curl -u user:pass -H "X-TX-TOKEN: $TX_TOKEN" -H "content-type: application/json"   -d '{"rpcUrl":"http://127.0.0.1:8545"}' http://127.0.0.1:8788/api/tx/deploy-test-contract
```

Submit raw transaction:

```bash
curl -u user:pass -H "X-TX-TOKEN: $TX_TOKEN" -H "content-type: application/json"   -d '{"rawTxHex":"0x...","rpcUrl":"http://127.0.0.1:8545"}' http://127.0.0.1:8788/api/tx/send-raw
```



## TX Lab (Dev-only Transaction Testing UI)

> ⚠️ **Dev/test environments only. Disabled by default.**

TX Lab adds a guarded transaction testing backend + UI at `/` (status UI) with tabs for Accounts, Scenarios, Runner, Live Monitor, and Results.

### Guardrails

- `TX_LAB_ENABLE=1` is required to enable any TX Lab API/UX.
- Raw private-key loading is blocked unless `TX_LAB_INSECURE_KEYS=1`.
- All mutating endpoints require `X-TX-LAB-TOKEN`.
- Default bind is loopback (`TX_LAB_HOST=127.0.0.1`).
- Private keys are never returned by API responses.

### Environment variables

```bash
TX_LAB_ENABLE=0
TX_LAB_INSECURE_KEYS=0
TX_LAB_HOST=127.0.0.1
TX_LAB_PORT=8799
TX_LAB_TOKEN=
TX_LAB_RPC_URL=http://127.0.0.1:8545
TX_LAB_DB_PATH=.data/txlab/txlab-runs.jsonl
TX_LAB_ACCOUNTS_FILE=.data/txlab/accounts.json
TX_LAB_MAX_CONCURRENCY=100
TX_LAB_MAX_TX_PER_RUN=10000
```

### Account file example

```json
{
  "chainId": 100,
  "accounts": [
    { "label": "sender-01", "privateKey": "0xabc...", "address": "0x..." },
    { "label": "receiver-01", "privateKey": "0xdef..." }
  ]
}
```

If `address` is omitted, TX Lab derives it from the private key and validates key/address pairing.

### Scenario example

```json
{
  "name": "burst-native-transfers",
  "mode": "native-transfer",
  "txType": "legacy",
  "senderSelection": ["sender-01", "sender-02"],
  "receiverSelection": ["receiver-01", "receiver-02", "receiver-03"],
  "valueWei": "1000000000000000",
  "txCount": 500,
  "concurrency": 25,
  "rateLimitTps": 50,
  "waitMode": "wait-receipt",
  "timeoutSeconds": 30,
  "randomizeReceivers": true
}
```

Supported modes (MVP):

- `native-transfer`
- `raw-tx` (`rawTxHex`)
- `contract-deploy` (`bytecode`)
- `contract-call` (`contractAddress` + `data`, or `abi` + `method` + `args`)

### Start / stop

```bash
# starts status-ui server with TX Lab enabled, on TX_LAB_PORT
make tx-lab-up
make tx-lab-status
make tx-lab-logs
make tx-lab-stop
```

### REST API

Read-only:

- `GET /api/txlab/health`
- `GET /api/txlab/config`
- `GET /api/txlab/accounts`
- `POST /api/txlab/accounts/refresh`
- `GET /api/txlab/scenarios`
- `GET /api/txlab/runs`
- `GET /api/txlab/runs/:id`
- `GET /api/txlab/runs/:id/results`

Mutating (`X-TX-LAB-TOKEN` required):

- `POST /api/txlab/accounts/load`
- `POST /api/txlab/accounts/group`
- `POST /api/txlab/scenarios`
- `POST /api/txlab/runs/start`
- `POST /api/txlab/runs/:id/stop`

### cURL examples

```bash
export TX_LAB_TOKEN=dev-only-strong-token

# load accounts from local file
curl -H "X-TX-LAB-TOKEN: $TX_LAB_TOKEN" -H "content-type: application/json" \
  -d '{"path":".data/txlab/accounts.json"}' \
  http://127.0.0.1:8799/api/txlab/accounts/load

# list account summaries
curl http://127.0.0.1:8799/api/txlab/accounts

# save scenario
curl -H "X-TX-LAB-TOKEN: $TX_LAB_TOKEN" -H "content-type: application/json" \
  -d @scenario.json \
  http://127.0.0.1:8799/api/txlab/scenarios

# start run
curl -H "X-TX-LAB-TOKEN: $TX_LAB_TOKEN" -H "content-type: application/json" \
  -d '{"scenarioName":"burst-native-transfers"}' \
  http://127.0.0.1:8799/api/txlab/runs/start

# stop run
curl -H "X-TX-LAB-TOKEN: $TX_LAB_TOKEN" -H "content-type: application/json" \
  -d '{}' \
  http://127.0.0.1:8799/api/txlab/runs/<run-id>/stop

# fetch results
curl http://127.0.0.1:8799/api/txlab/runs/<run-id>/results
```

### Notes

- Nonces are reserved per sender during parallel runs to reduce collision risk.
- Runs support fixed-count bursts and optional TPS limiting.
- Run summaries and per-tx outcomes persist in `.data/txlab/runs/*.json` and summary JSONL (`TX_LAB_DB_PATH`).
- Error classes include nonce, underpriced replacement, insufficient funds, intrinsic gas, execution reverted, invalid sender/raw tx, timeout, rpc/network, unknown.

### Troubleshooting

- `tx_lab_disabled`: set `TX_LAB_ENABLE=1`.
- `unauthorized`: set `TX_LAB_TOKEN` and send `X-TX-LAB-TOKEN`.
- `insecure_keys_disabled`: set `TX_LAB_INSECURE_KEYS=1` for local-only key loading.
- account file missing: verify `TX_LAB_ACCOUNTS_FILE` / request path.
- invalid private key mismatch: fix address/private key pairing.
- `insufficient_funds`: fund senders.
- `nonce_too_low`: refresh account nonces / avoid stale concurrent runs.
- RPC errors: verify `TX_LAB_RPC_URL` and node availability.


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

---

## Wallet + Faucet (Devnet)

Use the standalone faucet and wallet CLI helpers to speed up devnet testing.

> The faucet listens on its own port (`8787` by default), separate from the status UI (`8788` default).

Defaults used by the faucet workflow:

- `FAUCET_HOST=0.0.0.0`
- `FAUCET_PORT=8787`
- `FAUCET_RPC_URL=http://127.0.0.1:8545`
- `FAUCET_AMOUNT_WEI=100000000000000000` (0.1 ETH)
- `FAUCET_TOKEN=devtoken-change-me`

For safety, **override `FAUCET_TOKEN`** instead of using the default value.

Start chain (existing flow):

```bash
make up
```

First-time faucet setup:

```bash
make faucet-init
# edit .env.faucet and set FAUCET_PRIVATE_KEY + FAUCET_TOKEN
make faucet-up
```

Open the faucet UI:

```bash
make faucet-ui
```

Then open one of the printed URLs in your browser (for example `http://127.0.0.1:8787/`).

UI notes:

- Put `FAUCET_TOKEN` in `.env.faucet`, start faucet, then paste the token into the UI.
- The token is required on every request (`X-FAUCET-TOKEN`) and is stored in browser `localStorage` as `qik_faucet_token`.
- Click **Connect MetaMask** to auto-fill the destination address.
- You can create additional recipient addresses inside MetaMask and paste/select them in the UI.

Common faucet commands:

```bash
make faucet-status
make faucet-url
make faucet-logs
make faucet-stop
make faucet-restart
```

Create wallet:

```bash
make wallet-new
```

Fund wallet:

```bash
make faucet-send TO=0x...
```

Check balance:

```bash
make wallet-balance ADDRESS=0x...
```

Send transaction:

```bash
make wallet-send FROM_PK=... TO=0x... VALUE_WEI=1
```

Prefunding note:

If faucet tx fails with insufficient funds, prefund the faucet address in genesis or transfer funds to it after chain start.

Additional helper:

- `make wallet-new OUT=.secrets/another-wallet.json`


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

### Transaction path integration (local + CI)

Use `make test-tx` to run end-to-end transaction-path checks against devnet.

The tx suite (`scripts/tests/tx_integration.sh`) validates:

1) send 1 wei to burn address,
2) deploy embedded test contract bytecode,
3) sign and submit a raw transaction.

Run locally:

```bash
make test-tx
```

Optional environment variables:

- `RPC_URL` (default `http://127.0.0.1:8545`)
- `SENDER_PRIVATE_KEY` (preferred key source)
- `FAUCET_PRIVATE_KEY` (fallback key source)
- `CI_TX=1` (include tx suite inside `make test` / CI entrypoint)
- `TX_HTTP_URL` (optional tx HTTP endpoint, e.g. `http://127.0.0.1:8788/api/tx/send-wei`)
- `TX_TOKEN` (required when `TX_HTTP_URL` is set)
- `GAS_MULTIPLIER` (default `1.2`)

Skip/fail behavior:

- If no sender key can be resolved (`SENDER_PRIVATE_KEY`, `FAUCET_PRIVATE_KEY`, or dev-only key discovery under `.data`), tx tests print `tx tests skipped: no key` and exit `0`.
- If `TX_HTTP_URL` is explicitly set but `TX_TOKEN` is missing, tx tests fail with a clear error.
- If tx HTTP mode is not enabled/available, the suite falls back to raw JSON-RPC.

CI notes:

- `scripts/ci/run.sh` runs tx tests only when `CI_TX=1`.
- GitHub Actions sets `CI_TX=1` and passes optional secrets:
  - `SENDER_PRIVATE_KEY` or `FAUCET_PRIVATE_KEY`
  - `TX_HTTP_URL` and `TX_TOKEN` (only needed for UI tx endpoint mode)

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
make down
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

## PoS (ERC20 Staking) – Milestone 1

Milestone 1 adds PoS staking state/contracts/tooling for devnet workflows. It **does not** change runtime consensus behavior yet.

### Quickstart

Deploy contracts:

```bash
make pos-deploy RPC_URL=http://127.0.0.1:8545 PRIVATE_KEY=0x...
```

Mint devnet QIK:

```bash
make pos-mint TO=0x... AMOUNT=100000000000000000000000 PRIVATE_KEY=0x...
```

Register validator metadata:

```bash
make pos-register OPERATOR_PK=0x... MONIKER=validator-1 ENDPOINT=http://127.0.0.1:30303 NODE_ID_HEX=0x1234 BLS_PUBKEY_HEX=0xabcd
```

Stake tokens:

```bash
make pos-stake OPERATOR_PK=0x... AMOUNT=1000000000000000000000
```

Snapshot active set:

```bash
make pos-snapshot EPOCH=1 OPERATORS=0xabc...,0xdef... OWNER_PK=0x...
```

Query deployment + staking info:

```bash
make pos-info
```

### Notes

- Snapshot submission is owner-driven in this milestone (placeholder for future deterministic derivation from stake state).
- Keep private keys in env vars or secret files; avoid shell history leaks.
- Use `docs/pos/erc20-pos-skeleton.md` for the current on-chain interface/state spec.
