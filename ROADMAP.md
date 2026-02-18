# QikChain Roadmap

## Vision

QikChain is an EVM-compatible blockchain designed for:

-   Pragmatic validator operations
-   Clean operator UX
-   Deterministic infrastructure
-   Config-driven consensus evolution (PoA → PoS)
-   Production-grade hardening without overengineering

Primary architectural principle:

> Switching consensus must be a configuration change, not a rewrite.

------------------------------------------------------------------------

# Phase 0 --- IBFT PoA Devnet (Current)

**Status: In Progress / Functional**

## Goals

-   Stable local multi-validator devnet
-   Deterministic startup scripts
-   Parameterized consensus selection
-   Basic CLI scaffolding
-   RPC + metrics exposed
-   Repeatable genesis generation

## Deliverables

-   [x] IBFT PoA cluster bootstraps cleanly
-   [x] chainId configured
-   [x] Multi-node networking works
-   [ ] CLI scaffold expanded beyond placeholder
-   [ ] Genesis templating system formalized
-   [ ] docs/genesis-policy.md created

------------------------------------------------------------------------

# Phase 1 --- IBFT PoS Devnet

**Status: Design Stage**

## Goal

Run a PoS devnet using the same infrastructure and scripts as PoA.

## Requirements

-   Staking contract enabled in genesis
-   Validator set managed via stake
-   Config flag to toggle PoA vs PoS
-   No changes to directory layout, metrics endpoints, RPC structure, or
    startup commands

## Deliverables

-   [ ] PoS genesis template
-   [ ] Staking contract integration
-   [ ] Validator registration flow
-   [ ] Operator CLI commands:
    -   validator init
    -   validator stake
    -   validator status
-   [ ] Validator funding automation

------------------------------------------------------------------------

# Phase 2 --- Operator UX

## Goal

Make validator operation ergonomic and safe.

## Focus Areas

### Validator Onboarding

-   Key generation
-   Stake registration
-   Status inspection
-   Participation metrics

### Key Management

Abstract backend:

--key-backend=local\
--key-backend=remote\
--key-backend=hsm

Start with: - Local encrypted keystore

### Observability

Expose:

-   Block height
-   Peer count
-   Missed blocks
-   Validator participation
-   Finality metrics

Prometheus-compatible metrics endpoint required.

------------------------------------------------------------------------

# Phase 3 --- Production Hardening

## Goal

Make QikChain production-ready.

## Required Systems

### Operational Safety

-   Snapshot exports
-   Deterministic backup procedure
-   Chain halt process
-   Emergency validator replacement
-   Rolling upgrade documentation

### Governance

-   Upgrade signaling policy
-   Validator quorum requirements
-   Parameter change governance process
-   Emergency override procedure

### Security

-   Key rotation strategy
-   Slashing policy (if PoS)
-   Validator removal process

------------------------------------------------------------------------

# Token & Chain Configuration

## Chain Identity

-   Local: chainId 100
-   Staging: chainId 101
-   Production: TBD (\>10,000 recommended)

## Native Token

-   Name: TBD
-   Symbol: TBD
-   Decimals: 18 (recommended)

## Block Parameters

-   Dev target block time: 2s
-   Production: 2--3s recommended
-   Epoch length: TBD

## Gas Policy

Dev: - minGasPrice = 0

Production: - EIP-1559 recommended

## Genesis Allocations

Must explicitly define:

-   Validator funding
-   Operator funding
-   Treasury
-   Dev faucet (dev only)

All allocations must include rationale documentation.

------------------------------------------------------------------------

# Upgrade Policy (Initial)

Current approach: - Coordinated manual validator upgrade

Future: - Governance-based parameter upgrades - Majority validator
signaling - Defined activation block

------------------------------------------------------------------------

# Engineering Principles

1.  Config over hardcoding
2.  Deterministic bootstrapping
3.  Stable interfaces
4.  Minimal early economic assumptions
5.  Documentation before mutation

------------------------------------------------------------------------

# Milestones Overview

  Milestone   Outcome
  ----------- -----------------------------------------
  M1          Stable PoA devnet
  M2          Parameterized genesis templates
  M3          PoS devnet live
  M4          Operator CLI stable
  M5          Monitoring & metrics complete
  M6          Production hardening checklist complete

------------------------------------------------------------------------

# Immediate Next Actions

1.  Formalize genesis templating
2.  Write genesis-policy.md
3.  Expand CLI scaffold into real command structure
4.  Design PoS genesis diff
5.  Define minimal token metadata
