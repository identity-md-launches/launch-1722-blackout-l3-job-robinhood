# BLACKOUT L3 / job A adaptation

This submission prepares the existing v3.18 project for one `evm_contracts` launch on Robinhood Chain
(4663). All production Solidity sources, embedded pins, build configuration and dependencies remain
unchanged. The eight creation hashes match the brief. No constructor or gameplay change is needed.

## Changes and reasons

| File | Change | Requirement or finding |
| --- | --- | --- |
| `docs/design.md` | Correct the stale commitment-time Mythic eligibility statement to describe the current level check at each `resolve`, including partial receipts and already captured entropy. | Imported finding `35715a98e1588a983ab4b6c1ec5d774284a57e25c2ec9823cfa3a04d92870a41`; the intended reveal-time behavior is recorded in `docs/report-v34.md`, L-5. Source is pinned. |
| `test/PackMythicTiming.t.sol` | Add two behavioral regressions: compare Common versus Mythic from the same captured seed before/after level 10, and verify that a partial receipt rechecks level while preserving its seed. | Reproduce the imported documentation finding and test the corrected specification without altering gameplay. |
| `test/JobALaunch.t.sol` | Add exact creation-pin/configuration checks and a single-call CREATE2 batch rehearsal with the supplied constructor words, dependency resolution, runtime checks and role registration coordinates. | The launch must contain exactly eight named contracts in order, with factory-callable constructors and no changes to pinned code. |
| `ADAPTATION.md` | Record changes, audit disposition, exact launch inputs and the post-launch handoff. | Required adaptation notes; deployment and manifest creation are subsequent platform steps. |

The test-only batch probe is not a launch target. Its local salt namespace and locally deployed
addresses are fixtures, not production launch coordinates. No `launch.json`, token, pool, dependency,
private key, transaction signature or broadcast is added.

## Exact launch handoff

Deploy these eight names in this order in **one** launch. `$contract:Params` and
`$contract:GameRegistry` resolve by name to earlier contracts in that same launch. Each hash below
is `keccak256(creationCode)`, before appending constructor words, not an init-code or runtime hash.

| Index | Contract | Constructor words, in order | Registry role | Creation hash | Runtime bytes |
| --- | --- | --- | --- | --- | --- |
| 0 | Params | `["0x5cb0686a4475d1f8a6c6e5240579080a4a05b609","200","1000000000000000000"]` | — | `0x26c9f36af040b02eba9644f52daeed84fae4e42eab9bdb23277d0bb28c6dc6c0` | 3118 |
| 1 | GameRegistry | `["0x38b05971c79e738f64452be83c78ec3d66535b7a","$contract:Params","0x3c9599670893546a3def98608259a8e6582790cc","0xb7d282d1c46f6062963bf2d134d058aa4de3af4cb7b092c5a0fd12ed74dc0f2c","0xdc0842e9fd0017b08be09e787e877c53cfb446ca52aabdb9770e5c33b49d1325","26182375","200000000000000000000000000"]` | — | `0xe41104da4edfb9a746e9080ce7b1885b5fe7609674a3a68fc5addbfd5a871531` | 2864 |
| 2 | RewardPool | `["$contract:GameRegistry"]` | 0 | `0xecf3ae5ebb791318703b5e79960cfd243b7d89bdffa0e0501bee5146623764de` | 4234 |
| 3 | FarmRewards | `["$contract:GameRegistry"]` | 1 | `0xfa1a4087722916aeefae66aaf3400299a5e4cb8f4fc8e516a17cec7754e07506` | 17002 |
| 4 | FarmCore | `["$contract:GameRegistry"]` | 2 | `0xc390b07ef7a9ab65bef3a1ec3b39c1a16e117543c9565fedc9342526aa57aa47` | 22361 |
| 5 | FarmItems | `["$contract:GameRegistry"]` | 3 | `0x98f7224201d9e7e3d16bd8996c29a522cac5bd1b375181de8cfdc2c6b9639e76` | 13861 |
| 6 | PackSale | `["$contract:GameRegistry"]` | 4 | `0x7ecf36d55a73c01094e4434de085dfb39f17a1deda39a52ee38954f3a8e8737a` | 12538 |
| 7 | StarterClaim | `["$contract:GameRegistry"]` | 5 | `0x960e2782608b572a1385ec22ed3e1fb49cd0cccd9b3455ce7bf7f22e990dbd90` | 5477 |

The unchanged `foundry.toml` uses solc 0.8.26, optimizer enabled with 200 runs, Cancun,
`via_ir = false`, `bytecode_hash = "none"`. Constructors are nonpayable, take 3/7/1/1/1/1/1/1 static
words respectively, and need no external call or deployed dependency at construction. There are no
external library links. All runtimes are below 24,576 bytes. The batch regression scans deployed
runtime instructions, skipping PUSH data, for DELEGATECALL, CALLCODE and SELFDESTRUCT as the supplied
protected floor does. No ownership is assigned to the deploying factory: `Params.swarmWallet` is the
recorded SwarmDesk, and modules refer to the immutable deployment graph.

Recorded earlier launches, as supplied in the brief (not newly queried chain observations):

- L1 launch **1628**: SwarmDesk `0x5cb0686a4475d1f8a6c6e5240579080a4a05b609`,
  EndowmentEscrow `0x11947494c0ba91508eb7409648193818c36521fb`.
- L2 launch **1710**: token `0x38b05971c79e738f64452be83c78ec3d66535b7a`,
  V4Market `0x3c9599670893546a3def98608259a8e6582790cc`; ETH/token pool, fee 12500, tick spacing 60.
- Binder: `0x6d51cBE774aeAe4dd40bCA2560E9bc2695A0d007`. This is not the Params constructor's swarm
  address; that argument must remain the Desk.
- The roots, snapshot block and endowment above reproduce
  `GAME_CONFIG_HASH = 0x11ed7438974e96ecc962201e9c46422c7bf239d725876863fa25a56c734b20d3`
  as `keccak256(abi.encode(STARTER_ROOT, FREE_ROOT, uint256(26182375), uint256(200000000000000000000000000)))`.
  The test verifies this independently of the creation pins.

There are no literal IMD protocol addresses among these constructor words. Protocol endpoints remain
compiled into the unchanged contracts. This launch does not deploy the already recorded hook or token.

## After the platform records job A

The platform's final launch receipt must supply **all eight addresses, indices 0–7, and the actual
launch number `N_A`**. These are not yet issued by this source-adaptation task; no production address
or launch number is inferred from the offline rehearsal.

Only the pinned binder signs the following call to the recorded SwarmDesk after checking that receipt:

```text
SwarmDesk.bind(REGISTRY, registryCode, paramsCode, N_A, 1, N_A, 0, 1710)
```

`REGISTRY` is the receipt's index-1 address; `registryCode` and `paramsCode` are the raw creation
bytecode from the matching build, without constructor arguments. They must hash to the table above.
The binder cannot bypass the Desk's proofs. Losing that key before binding leaves the Desk unbound
and the endowment in escrow, as already accepted.

Then register roles 0–5 permissionlessly and immediately, using
`GameRegistry.register(role, N_A, role + 2, creationCodeForRole)`. Verify each `module(role)` against
the receipt. Registration is a post-launch action, not a factory initialization call. The Desk can
store authenticated answers after L3, but execution waits for all job B/L4 modules to be registered.
The existing post-L4 wiring and escrow-forwarding checks still apply.

## Imported audit disposition

- **35715a98… — reproduced; documentation corrected.** A level-1 buyer commits a receipt with
  `mythic == false`. The test captures a seed whose selected item roll is at least 9970. Resolving
  immediately produces rarity 0 with base hash 10000. Restoring the same captured state and giving
  the farm five days of age and 2800 XP through the existing fixture produces rarity 4 with base hash
  800000, retaining the seed and item kind. Alice's and RewardPool's token balances do not change
  during that resolution. A second test verifies the rule across partial openings. No PackSale fix
  is appropriate: reveal-time eligibility is intentional since v3.4, and this launch pins its code.
- **47b0e88d… — coverage report, not a reproducible defect.** Independently corroborated the eight
  creation hashes, runtime sizes, constructor deployment, dependency wiring and registration
  indices. The report's broader audit conclusions are not represented as a fresh full audit here.
  No source fix follows from this informational entry.

All findings accepted in the brief and [docs/accepted-v318.md](docs/accepted-v318.md) remain accepted
and unchanged. In particular, the c0e1b0b6 stored-weight issue is gated by `Economy.lock` and Civic
feature 4, disabled at launch and requiring an announcement plus 48-hour notice before enabling;
the accepted boost bound is 20% of that farm's weight. The Season prize starter flag and the bounded
72-of-144-hour pack pause also remain unchanged. This task does not enable features, regenerate
pins, alter oracle endpoints, repair RewardPool via `donate`, or change the accepted exact-input
swap rules. [docs/m2-trust-assumption.md](docs/m2-trust-assumption.md) remains the binder trust reference.

## Verification

Verification uses the repository's own compiler settings and this supplied seed:

```sh
forge build
FOUNDRY_FUZZ_SEED=0xe011b230a0a9c8f52bb7e349c6b7ce147f04b096d4148fab6c7dec1624cb865c forge test
```

- `forge build`: passed with the unchanged project configuration; existing compiler/lint warnings remain.
- Full `forge test` with the seed above: **331 passed, 0 failed, 6 skipped** across 58 suites
  (337 total). The six skipped cases are the existing opt-in RPC/fork tests, including the live
  platform gas-ceiling rehearsal. No fork RPC was supplied for this offline run.
- The invariant campaign passed all seven invariants over 128 runs / 8,192 handler calls, with no
  handler reverts. The repository's fuzz tests used its configured 256 runs and the supplied seed.
- All four added tests passed both the focused run and full suite. Artifact ABI inspection confirmed
  nonpayable static constructors and no library links for each of the eight launch contracts.
- Independently checked the launch table in this document against the built artifacts: ordered
  names, argument types/counts, backward references, role indices, creation hashes, runtime sizes
  and configuration hash all match.
- Formatting checks passed for both added test files, and `git diff --check` passed. The diff has no
  production source, build configuration or dependency changes.

These are local checks, not a live deployment, factory attestation, live-chain gas-ceiling simulation
or independent audit. The supplied Owners protected test imports a platform-only `OwnerChecks.sol`
that is not included in the read set; its actual execution remains with the platform verifier.
