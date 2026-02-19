# QikChain

QikChain is an EVM-compatible blockchain project focused on pragmatic operator UX, deterministic infrastructure, and a clean path from IBFT PoA devnets to IBFT PoS.

Core principle:

> Switching consensus must be a configuration change, not a rewrite.

## Status

- Phase 0: IBFT PoA devnet ✅ (working / in active iteration)
- Phase 1: IBFT PoS devnet 🚧 (contracts + genesis wiring in progress)
- Phase 2: Operator UX (onboarding / key mgmt / metrics) ⏳
- Phase 3: Production hardening (backups / monitoring / upgrades) ⏳

See: `ROADMAP.md`

---

## Requirements

- Go (matching repo toolchain)
- A local environment capable of running your nodes (Linux/WSL recommended)

Optional (only needed for PoS contract deployment tooling if you use Foundry):
- Foundry (`cast`)

---

## Quick Start (PoA Devnet)

### 1) Build the CLI

If you have a Makefile target, use it. Otherwise:

```bash
go build -o ./bin/qikchain ./cmd/qikchain

## Startup: 4-node IBFT Devnet (PoA or PoS)

We provide a single startup script for a 4-node local devnet. It is parameterized so switching consensus is a config change:

- `CONSENSUS=poa` → IBFT PoA
- `CONSENSUS=pos` → IBFT PoS (Phase 1)

### Prereqs

Build the CLI and ensure the Polygon Edge binary exists:

```bash
go build -o ./bin/qikchain ./cmd/qikchain
# ensure ./bin/polygon-edge exists (repo-managed or built separately)

