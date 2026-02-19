# QikChain Staking + Validator-Set Interface (Phase 1 MVP)

## 1) Summary

This MVP defines a devnet-friendly PoS interface for IBFT with two logical components:

- **Staking ledger**: operator registration, stake accounting, unbonding queue, and admin params.
- **Validator-set view**: deterministic read-only queries for consensus engine and tooling.

The design intentionally keeps rewards/slashing/commission as placeholders for later phases.

## 2) Actors and roles

- **Staker**: deposits native token stake against an operator.
- **Operator**: validator identity and consensus key owner (1 operator address = 1 validator identity in MVP).
- **Validator**: an operator currently selected in the active set.
- **Admin**: owner/governance authority for jailing and parameter updates.

## 3) Data model

- `OperatorInfo`
  - `operator`, `payout`, `consensusKey`, `totalStake`, `registered`, `jailed`
- Stake balances
  - `stakeOf(operator, staker)` tracked per staker per operator.
  - `totalStakeOf(operator)` tracked on operator.
- Unbonding queue
  - list of `Unbonding { amount, unlockTime }` for each `(operator, staker)` pair.

## 4) Core flows

### Operator registration

1. Operator calls `registerOperator(consensusKey, payout)`.
2. Requires non-empty key, non-zero payout, and not already registered.

### Staking

1. Any staker calls `stake(operator)` (or `stakeFor(operator, staker)`) with native token value.
2. Contract increases `stakeOf` and `totalStakeOf`.

### Activation into validator set

An operator is eligible if:
- registered,
- not jailed,
- `totalStake >= minStake`.

Active set = top `maxValidators` eligible operators ranked by:
1. `totalStake` descending,
2. operator address ascending (tie-break).

### Unstake + unbonding + withdraw

1. Staker calls `requestUnstake(operator, amount)`.
2. Stake is reduced immediately and an unbonding entry is created with unlock time `now + unbondingPeriod`.
3. After unlock, staker calls `withdrawUnstaked(operator)` to receive matured amount.

### Jailing

Admin can call `setJailed(operator, bool)`.
Jailed operators remain registered but are excluded from active set.

## 5) Determinism rules

For consensus-safe queries:
- Filter by fixed eligibility conditions.
- Sort by `totalStake DESC`.
- Resolve ties by `operator address ASC`.
- Truncate to `maxValidators`.

This makes `getActiveOperators()` deterministic across nodes.

## 6) Security considerations (devnet level)

- `withdrawUnstaked` uses a **reentrancy guard**.
- Native token transfer uses checked low-level call (`call{value: amount}("")`).
- `consensusKey` validated as non-empty on registration/update.
- Complexity note: active set query uses on-chain sorting in view logic (acceptable for devnet; optimize later for production scale).

## 7) Future hooks (placeholders)

Future phases can extend interfaces and storage for:
- reward distribution,
- slashing and fault penalties,
- operator commission and delegation policy,
- potentially optimized active-set indexing/caching.
