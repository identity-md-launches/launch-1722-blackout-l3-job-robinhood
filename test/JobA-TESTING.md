# BLACKOUT L3 job A test additions

All changes are in `test/`. Production sources, creation-code pins, compiler settings,
dependencies and the existing contributors' tests are unchanged.

## Coverage

| File | Properties and failure paths |
| --- | --- |
| `JobARewardPoolInvariant.t.sol` | Two campaigns, starting unfunded and funded, with the recorded 200 million-token principal. Three actors interleave donations, principal transfers, core/router notifications, funding, time, future drip governance, reservations, recycling and payments. Independent cumulative flows constrain cash, reservations, each actor's balance and total supply. Frozen schedules and locked principal stay protected. Every sequence ends by vesting and paying out the entire remaining balance to check liveness. |
| `JobAItemsInvariant.t.sol` | Random mint/equip/unequip/burn/maintenance/expansion sequences. Every live ID has exactly one ERC-1155 unit in the correct custody; burned IDs have none. Owner enumeration is complete and unique after swap-and-pop deletion. Inventory matches unequipped items and stays within capacity. Unauthorized mutations and single/batch transfers must revert. |
| `JobAFailurePaths.t.sol` | Max-cost rejection, missing allowance, failed payments, readiness gates, ETH swap rollback and refund ownership, token/receiver callbacks, rejected item delivery and retry, invalid resolution counts, full-inventory custody rollback, privileged entry points, and invalid reward withdrawals. |
| `JobAStarterBoundaries.t.sol` | Real starter and pack contracts on chain ID 4663 with mocked ArbSys responses. Proofs bind caller and index; duplicate wallets and indices are rejected. Tests pin the exact claim deadlines, disjoint receipt namespaces, future-block and 256-block boundaries, missing-hash refusal, rearming, and persistence of captured entropy. |
| `JobAParamsBoundaries.t.sol` | All 45 keys reject unauthorized writes. Fuzzing covers each mutable key's exact cooldown, step and range restrictions. Boundary tests cover constructor arguments, immutable heartbeat cap, no-op changes, and letter lengths. |
| `JobAPoolFailurePaths.t.sol` | Zero/short donations, false-returning and paused tokens, optional ERC-20 return data, invalid payment destinations, overdraw, reservation rollback, and the documented plain-transfer funding-shortfall repair. |

The existing `JobALaunch.t.sol` remains the deployment rehearsal: all eight creation
hashes, exact constructor words, a single-transaction batch, runtime checks, and
permissionless registration of roles 0–5. Existing registry, binder, escrow and
full-game tests remain part of the default run.

The three new invariant campaigns use inline settings of 256 runs and depth 64,
with `fail-on-revert = true`. Their explicit target selectors exclude configuration,
getters and final-drain helpers. Expected rejected calls use exact revert selectors;
unexpected reverts fail the campaign. There are eight new global invariant properties.
Stateless fuzz tests use 512 or 1,000 runs as specified beside each test.

## Fixtures and limits

- Pool and item ledger campaigns isolate the real contracts with the existing
  `MockGameRegistry`. Authorized module identities represent their caller interfaces;
  these campaigns do not prove registration or gameplay eligibility. Those are covered
  by the canonical deployment tests and real-graph integration tests.
- Purchase and starter tests reuse `BaseTest` and its real pinned module graph. That
  fixture has zero endowment and mocks only the purchase `endowed()` flag. Actual
  200 million-token funding and vesting run independently without that mock in the
  pool suites. Launch-disabled Civic features remain disabled in the new integration
  tests; the accepted lock/unlock resync issue is not asserted to be correct.
- `JobATokenBehavior` tests defensive token handling. It does not claim that the
  recorded L2 token charges fees, pauses or omits return values.
- ArbSys responses are offline test inputs. Live Robinhood state, production Merkle
  proofs, deployment records and the binder's transaction are not verified here.
  The existing guarded fork suites still need a configured live RPC for those checks.
- No production launch is broadcast, and no local test address or salt is represented
  as a production address or launch number. Accepted findings from the brief are not
  changed or treated as fixes by these tests.

## Reproduction

```sh
forge build
FOUNDRY_FUZZ_SEED=0xe011b230a0a9c8f52bb7e349c6b7ce147f04b096d4148fab6c7dec1624cb865c forge test
```

For this workspace's path restrictions, local checks direct generated artifacts and
cache into disposable scratch space using `FOUNDRY_OUT=test/scratch/out` and
`FOUNDRY_CACHE_PATH=test/scratch/cache`. These affect output locations only; tests
have no imports or other dependencies on `test/scratch/` and run with the unchanged
repository configuration after it is removed.
