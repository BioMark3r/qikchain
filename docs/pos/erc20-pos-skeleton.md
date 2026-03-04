# ERC20 PoS Skeleton (Milestone 1)

## Overview & non-goals

This milestone introduces PoS-facing on-chain state and interfaces only. It does **not** switch consensus execution in nodes yet. Contracts and scripts in this PR provide deterministic devnet tooling for validator registration, ERC20 staking, unbonding, and epoch active-set snapshot placeholders.

Non-goals for Milestone 1:
- no consensus-engine changes in `qikchain` / node runtime
- no on-chain active-set derivation from stake weight yet
- no slashing, rewards, delegation accounting, or signature proofs

## Actors

- **Validator operator**: EOA that registers validator metadata, stakes QIK, requests unstake, and withdraws unlocked stake.
- **Delegator (optional future extension)**: not implemented in Milestone 1; design leaves room for it.
- **Admin/governance**: contract owner for devnet operations (token minting + epoch snapshots).

## Token model

- Staking token is ERC20 `QIKToken` (`name=QikChain`, `symbol=QIK`, `decimals=18`).
- Devnet minting strategy: owner mints to test accounts/operators with `mint(address,uint256)`.
- Production note: mint authority must move to governance-controlled issuance policy in later milestones.

## Core contracts and responsibilities

- `QIKToken`
  - ERC20 token used for staking deposits.
  - `mint` is owner-only for devnet.
- `ValidatorRegistry`
  - validator/operator metadata registry
  - stores operator, BLS pubkey blob, node ID, moniker, endpoint, registration block
- `StakeManager`
  - receives ERC20 via `transferFrom`
  - tracks `stakeOf` per operator and `totalStaked`
  - supports unbonding queue via `beginUnstake` + delayed `withdraw`
- `EpochManager`
  - epoch arithmetic helpers
  - stores owner-submitted active validator set snapshots + hashes at epoch boundaries

## State model

- `StakeManager.stakeOf[operator] -> uint256`
- `StakeManager.totalStaked -> uint256`
- `StakeManager.pendingWithdrawals[operator][withdrawalId] -> {amount, unlockBlock, withdrawn}`
- `ValidatorRegistry._validators[operator] -> {operator, blsPubkey, nodeId, moniker, endpoint, registeredAtBlock, exists}`
- `EpochManager._activeSet[epoch] -> address[]`
- `EpochManager.activeSetHash[epoch] -> bytes32`

## Epochs

- `EPOCH_LENGTH_BLOCKS` is constructor-configurable in `EpochManager`.
- Epoch index: `epochAtBlock(blockNum) = blockNum / EPOCH_LENGTH_BLOCKS`.
- Rule in Milestone 1:
  - snapshots only at boundaries (`block.number % EPOCH_LENGTH_BLOCKS == 0`)
  - `snapshotActiveSet(epoch, operators)` requires `epoch == currentEpoch()`

## Validator lifecycle

`register -> stake -> activate (off-chain selection + on-chain snapshot) -> optional exit (beginUnstake) -> withdraw`

Activation is modeled through `EpochManager.snapshotActiveSet` (owner-driven placeholder). Consensus integration later consumes these snapshots.

## Interfaces

### QIKToken
- `mint(address to, uint256 amount)`

### ValidatorRegistry
- `registerValidator(bytes blsPubkey, bytes nodeId, string moniker, string endpoint)`
- `updateValidator(bytes nodeId, string moniker, string endpoint)`
- `isRegistered(address operator) -> bool`
- `getValidator(address operator) -> Validator`

Events:
- `ValidatorRegistered(address operator, bytes nodeId, string moniker, string endpoint)`
- `ValidatorUpdated(address operator, bytes nodeId, string moniker, string endpoint)`

### StakeManager
- `stake(uint256 amount)`
- `beginUnstake(uint256 amount)`
- `withdraw(uint256 withdrawalId)`
- `stakeOf(address operator) -> uint256`
- `totalStaked() -> uint256`
- `pendingWithdrawals(address operator, uint256 withdrawalId) -> (amount, unlockBlock, withdrawn)`

Events:
- `Staked(address operator, uint256 amount, uint256 newStake)`
- `UnstakeStarted(address operator, uint256 amount, uint256 unlockBlock, uint256 withdrawalId)`
- `Withdrawn(address operator, uint256 amount, uint256 withdrawalId)`

### EpochManager
- `currentEpoch() -> uint256`
- `epochAtBlock(uint256 blockNum) -> uint256`
- `isEpochBoundary(uint256 blockNum) -> bool`
- `snapshotActiveSet(uint256 epoch, address[] operators)`
- `getActiveSet(uint256 epoch) -> address[]`
- `activeSetHash(uint256 epoch) -> bytes32`

Events:
- `ActiveSetSnapshotted(uint256 epoch, bytes32 activeSetHash, uint256 operatorCount)`

## Security considerations (dev scope)

- `StakeManager.withdraw` uses `ReentrancyGuard`.
- ERC20 approval flow is explicit (`approve` then `stake`).
- Devnet admin powers are significant:
  - token minting is owner-controlled
  - active set snapshots are owner-submitted
- Rate limits, signature/auth proofs, anti-spam registration controls are deferred to future milestones / off-chain policy.

## Integration points for consensus (future)

- Consensus/client can read:
  - `EpochManager.getActiveSet(epoch)`
  - `EpochManager.activeSetHash(epoch)`
- Off-chain watcher/indexer can stream:
  - staking events (`Staked`, `UnstakeStarted`, `Withdrawn`)
  - registry events (`ValidatorRegistered`, `ValidatorUpdated`)
  - snapshot events (`ActiveSetSnapshotted`)
- Future work can replace owner snapshots with deterministic derivation from `StakeManager` state.

## Testing plan

- Unit tests in `test/pos/`:
  - staking + unstake + withdraw happy path
  - stake registration requirement revert
  - epoch snapshot hash/list persistence checks
- Devnet scripts and `make` targets validate end-to-end operator workflows:
  - deploy -> mint -> register -> stake -> snapshot -> query
