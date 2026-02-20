# QikChain

QikChain is an EVM-compatible blockchain project focused on pragmatic operator UX, deterministic infrastructure, and a clean path from IBFT PoA devnets to IBFT PoS.

Core principle:

> Switching consensus must be a configuration change, not a rewrite.

## Startup: 4-node IBFT Devnet (PoA or PoS)

Build the CLI first:

```bash
go build -o ./bin/qikchain ./cmd/qikchain
```

Then run devnet:

```bash
INSECURE_SECRETS=1 RESET=1 CONSENSUS=poa ./scripts/devnet-ibft4.sh
```

Notes:

- `qikchain genesis build` now produces split outputs:
  - `build/chain.json` (Polygon Edge chain config)
  - `build/genesis-eth.json` (Ethereum-style genesis)
- `build/chain.json` contains `"genesis"` as a string path to `build/genesis-eth.json`.
- This Polygon Edge build exposes metrics with `--prometheus` (not `--metrics`).
- `INSECURE_SECRETS=1` is **dev-only** and should not be used in production.

PoS config remains a parameter flip:

- `CONSENSUS=poa` → IBFT PoA
- `CONSENSUS=pos` → IBFT PoS
