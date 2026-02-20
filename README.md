# QikChain

QikChain is a Polygon Edge--based EVM chain with a custom Go CLI for
deterministic genesis generation, PoA/PoS switching, and devnet
orchestration.

------------------------------------------------------------------------

# Overview

QikChain provides:

-   Deterministic genesis generation
-   Clean PoA ↔ PoS switching via config
-   Devnet orchestration scripts
-   Structured chain + genesis separation (required for this Polygon
    Edge version)
-   Status + health tooling
-   Fixed-supply native token (QIK)

------------------------------------------------------------------------

# Native Token

  Property              Value
  --------------------- --------------
  Name                  QIK
  Symbol                QIK
  Decimals              18
  Supply                Fixed
  Phase 1 PoS Rewards   0 (disabled)

------------------------------------------------------------------------

# Architecture

This Polygon Edge version requires the chain config to reference the
genesis file by **string path**, not embed it.

The CLI generates two files:

    build/chain.json
    build/genesis-eth.json

------------------------------------------------------------------------

# Build

``` bash
go build -o ./bin/qikchain ./cmd/qikchain
```

Ensure `polygon-edge` binary is available in `./bin/`.

------------------------------------------------------------------------

# Genesis

## Build Genesis

``` bash
./bin/qikchain genesis build   --consensus poa   --env devnet   --chain-id 100   --out-chain build/chain.json   --out-genesis build/genesis-eth.json
```

## Validate

``` bash
./bin/qikchain genesis validate --chain build/chain.json
```

------------------------------------------------------------------------

# Devnet (IBFT 4-Node)

Scripts:

    scripts/devnet-ibft4.sh
    scripts/devnet-ibft4-stop.sh
    scripts/devnet-ibft4-status.sh

## Start Devnet (PoA)

``` bash
INSECURE_SECRETS=1 RESET=1 CONSENSUS=poa ./scripts/devnet-ibft4.sh
```

## Start Devnet (PoS)

``` bash
INSECURE_SECRETS=1 RESET=1 CONSENSUS=pos ./scripts/devnet-ibft4.sh
```

------------------------------------------------------------------------

# Stop Devnet

``` bash
./scripts/devnet-ibft4-stop.sh
```

------------------------------------------------------------------------

# Status Script

## Human Mode

``` bash
./scripts/devnet-ibft4-status.sh
```

## Tail Logs

``` bash
LOGS=1 ./scripts/devnet-ibft4-status.sh
```

## JSON Mode

``` bash
JSON=1 ./scripts/devnet-ibft4-status.sh | jq .
```

------------------------------------------------------------------------

# Metrics

This Polygon Edge build supports:

    --prometheus

Not:

    --metrics

------------------------------------------------------------------------

# Roadmap

See `ROADMAP.md` for phased migration plan.

------------------------------------------------------------------------

# License

TBD
