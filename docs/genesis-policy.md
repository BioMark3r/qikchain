# Genesis policy

## Token metadata
- Name/Symbol: **QIK**
- Decimals: **18**
- Supply policy: **fixed supply**
- Phase 1 PoS rewards: **0**

## Allocation buckets (devnet)
Devnet premines are environment-scoped in `config/allocations/devnet.json` and are rendered into genesis by `qikchain allocations render`.

- Treasury: 1,000,000 QIK (network operations and future governance budgets)
- Faucet: 100,000 QIK (developer onboarding and testing)
- Operators: 10,000 QIK each (validator/operator bootstrap)
- Deployer: 1,000 QIK (deployment and migration operations)

## Change management
- Allocation file changes require a PR review.
- Mainnet allocation changes should be executed through explicit network upgrades rather than ad-hoc genesis rewrites.
- PoA ↔ PoS remains an environment/config flip (`CONSENSUS=poa|pos`).
