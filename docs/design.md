> v3.2: the epoch/season rules below are historical. See [lazy-accounting-v32.md](lazy-accounting-v32.md) for the current specification.

> v3.1 changes override historical v3 wiring and operational details below: modules use the write-once authenticated GameRegistry, the hook has a one-time team binding and fee escrow, RewardPool has a frozen linear token endowment, real keeper work earns bounded gas-based bounties, initial heartbeat share is constructor-configurable, and only PackSale new paid purchases can be paused for at most72hours. See [launch-v31](launch-v31.md), [report](../report.md), and [regulator](../regulator.md). Gameplay, items, reward vintages, event caps and season rules otherwise remain v3.

# BLACKOUT v3 design and accounting

## Epochs and bounded work

An epoch is six hours from the successful `advanceEpoch()` call. The first call is allowed at launch. Early/repeated calls revert; a late call does not accrue omitted hours. Each successful call credits at most one bounty, limited by the heartbeat balance. It snapshots numeric emission/tariff/combo parameters and starts a future-block event commitment.

Closing freezes the previous epoch's roster length and budget. `processEpoch(1..8)` measures farm snapshots, selects the exact top `ceil(active/10)` farms for an audit when required, then credits rewards. The audit uses a heap with logarithmic operations; each call handles at most eight entries. Farm item work is capped at four rooms × six slots. The next shift and gameplay mutations wait for complete settlement, avoiding partially updated allocation. Claims of existing credits remain available. Advance itself does not iterate farms. Registered accounts without equipment never enter the roster; anyone may retire a farm whose current and queued layouts are empty. Seasonal tickets/referral identity survive retirement.

The first action of an epoch freezes the account's layout, item health, overclock, paid status and theft state before changing queued state. If no action occurs, settlement freezes them. This prevents repair, purchase or Params updates from rewriting completed mining. Damage and 0.5 durability-point wear are then persisted. Unequipped items still referenced by that epoch cannot be merged or scrapped until released. Cable repair is the deliberate exception: Router stats, including affected combinations, are restored in proportion to seconds remaining in the epoch. A fresh theft cancels that restoration. Interpolation handles either increasing or decreasing combinations under valid Params.

## Token conservation

The project never mints or burns ERC-20 tokens. Token spends transfer to `RewardPool`, or release existing internal reward reserves back into available pool balance. ERC-1155 item destruction for scrap/merge/surge is separate from token supply.

`available = ERC20.balanceOf(pool) - reserved`. An epoch's nominal mining is available × daily emission / 4. A 116% budget reserves mining, maximum 5% referral, 1% season and 10% Green headroom before allocation. Default daily nominal emission is 3.5%; bounds are 2–6%. At 6%, conservative gross commitments are 6.96% of available per day: 14.37 days by available/current-outflow runway, before recycling or inflows. This ratio is not a promise of constant ETH yield or 14 days of fixed-size payouts.

Each farm receives nominal mining × productive hash / total raw hash, less electricity and audit. Raw hash is measured before the current event damage; productive hash includes durability, theft and events. This ensures destroyed equipment/fire actually reduce emission rather than simply changing every other farm's denominator during processing. Referrals receive 5% of invitee gross mining on top, one level only. Tariff, audit and unused budget recycle, with no transfer to the team. No whale soft cap exists.

Withdrawal retains the tax as a reserved liability for active farms in the next epoch. That epoch allocates 100% by raw hash; the final active farm receives rounding dust. If no farm is active, all tax carries forward. Internal spending consumes `ceil(nominal / 1.05)` with no withdrawal tax and recycles exactly the consumed amount. It does not mint a 5% token bonus.

Credits have a 32-epoch bounded vintage ring. Tax is `max(500, 2000 - 1500*age/7days)` basis points, aging from epoch end for mining. Old overwritten generations have already matured to 5%. Scrap and season credits age from their award time. Claims consume old credits first, update liabilities before transfer, and revert atomically on token failure. Plain, 18-decimal, non-rebasing/non-taxed ERC-20 behavior is required and checked on first wallet spend.

Scrap quotes about one hour of standalone item yield using last settled nominal reward/hash, durability and paid-account status. All scrap payouts share a pre-reserved epoch allowance bounded by both nominal mining/6 and unused fresh budget. Unused prior allowance recycles, and an empty epoch clears the rate/allowance. `minimum` protects a player from an exhausted allowance; zero permits discarding an item without payment. This bounds the unlimited-pack → scrap drain found in review. Scrapping does not open a new reservation against arbitrary available capital.

## ETH conservation

Packs, ETH lobby and custom progressive sell surcharge route 85% to future pool buys, 13% to fixed team pull credit and 2% to heartbeat. Heartbeat is capped at 1 ETH; overflow goes to pool-buy credit. Project swap fees route 50/50 team/pool-buy, independently of the above split. Network fees are accounted separately by the hook. Bounty debits heartbeat and creates a caller pull credit; it never pushes ETH during epoch advancement.

Anyone can execute a positive buy up to `BuyBatch` and available reward ETH. Minimum output must satisfy the 30-minute TWAP and bounded slippage; actual pool token balance gain is checked. There is no shared global buy cooldown that a dust transaction could grief. Team, bounty and pool-buy ledgers sum to ordinary router receipts; forcibly sent ETH is outside these ledgers and cannot create spending authority.

## Packs, items and levels

The marginal ETH curve is `start*(1+step)^ahead` above scheduled sales and `start*(1-decay)^(-ahead/target)` below it, clamped to floor/ceiling. `ahead = packsSold - elapsedHours*target`. At launch defaults are 0.010 ETH, floor 0.006, ceiling 0.030, target 20/hour, +1% per pack ahead and about 2% decay per hour behind. Every pack in a multiple-pack purchase pays its own marginal price. Token packs use current ETH price × thirty-minute token/ETH TWAP ×90%; internal spending additionally has 1.05 purchasing power. Free packs do not advance paid sales pace.

Each paid pack yields three independent weighted items after native block N+2. The first successful resolution locks entropy for all remaining packs in that receipt; expiry yields three Common GPUs per ordinary pack. Seasonal packs keep their Rare guarantee on expiry; starter expiry yields three Rare GPUs. Inventory must fit the chosen opening batch, so clients may resolve one pack at a time. Paid-account status is recorded by the purchase path. Since v3.4, Mythic eligibility is checked at each opening (`PackSale.resolve`) using the farm's current level, including each partial opening of a receipt; it is not fixed at purchase or entropy capture. A holder below level 10 can inspect a captured seed and wait until reaching level 10 (five days of farm age and 2800 XP): the same Mythic-range roll then yields a Mythic (800000 base hash) instead of a Common (10000). Resolution is permissionless, so another caller may open the receipt sooner. This is the intended, pinned behavior documented in [report-v34.md](report-v34.md), L-5; see [the regression tests](../test/PackMythicTiming.t.sol). Inventory starts at 15 unequipped items, expansion adds 5 for `ExpansionPrice*(expansions+1)^2`. Equipped items use room space, not inventory.

| Kind | Weight | Tag | Base mining |
|---|---:|---|---:|
| GPU 0 / ASIC 1 / FPGA 2 | 16 / 15 / 12 | Compute | 100% |
| Power Supply 3 / Battery 4 / Solar Panel 5 | 9 / 7 / 7 | Power | 60% |
| Fan 6 / Liquid Cooling 7 | 9 / 6 | Cooling | 60% |
| Router 8 | 6 | Network | 60% |
| Motherboard 9 / Server Rack 10 / Surge Protector 11 | 5 / 4 / 4 | Infrastructure | 60% |

Rarities are Common 70%, Rare 22%, Epic 6.7%, Legendary 1%, Mythic 0.3%; below level 10 the Mythic probability goes to Common. Rarity hash is 10/28/80/250/800, represented internally with ×1000 precision. All items are soulbound; only exact own-farm custody movements are allowed. No public transfer approval or player-to-player route exists.

Room 0 starts unlocked; room 1 unlocks at farm age 3 days; room 2 at level 7; room 3 at level 10. These gates are independent: buying XP cannot bypass room 1’s three-day requirement. `roomUnlocked` checks an index; `rooms` counts available rooms and is not a prefix bound. Every room has six arbitrary, nonduplicate types. Epic/Legendary/Mythic equip gates are level 3/5/10. XP is 100 per active settled epoch, 25 per paid pack and 2500 per ETH-equivalent token spend. Thresholds for levels 1–10: 0,100,400,600,800,1200,1600,2000,2400,2800. Activity alone reaches level 3 in four epochs, level 5 in eight and level 10 in 28; purchases/spend accelerate it.

Compute Duo adds 10%; Triple Core replaces it with 20%; all five tags adds 15%; Airflow Fan+Rack adds 5% and halves fire damage. Cold Power PSU+Liquid cuts electricity 15% and makes fire immune; Off-grid Solar+Battery cuts electricity 20% and halves outage loss; Surge Protector+PSU blocks surge; Router+Rack blocks cable theft. Three of the same Rare/Epic/Legendary/Mythic add 5/10/20/30%, highest rarity only. Hash bonuses add up to 40%, electricity savings add separately. Params may reduce those bonuses within documented bounds.

Durability starts 100, ordinary wear is 0.5 per active epoch, and mining multiplies by durability. Overclock adds 10% per level through 5, costs `OverclockPrice*(next level)`. Repairs cost missing basis points × internal rarity hash × RepairBps ×1 token /10,000,000; restore physical health now, effective next epoch for normal mining. Cable repair costs MergePrice. Three same type/rarity/starter-status unequipped items merge one rarity up, at most Legendary, for `MergePrice*(old rarity+1)`. These are token spends to the pool.

## Event and season rules

Swarm plans only current+1/current+2, once each, with kind, severity 5000–10000, random number and nonempty letter. It cannot submit player/district. The event seed binds that number to the hash of the block after the shift. Districts are address-hash modulo 8; this is not Sybil resistance and addresses can be ground before participation.

Missing plans use the fixed 20-entry table in GridOperator, subject to positive-weight substitution, maximum four of each negative in rolling 20, at least four positives per complete 20, and district outage cooldown 2 days. The first window reserves enough remaining slots to satisfy the positive floor. Missing/expired hash fallback ignores the swarm number; it cannot be seed-ground by submitting a known number. Expiry is predictable, so keepers should preserve live entropy promptly. Every resolved event emits its herald letter; every Params change requires a letter.

At full severity: outage affects 30% of district farms (off-grid half production); surge affects 10%, damaging one random item 50 with 2% destruction unless Legendary/Mythic; fire makes uncooled rooms yield zero and damages nonimmune items 30; cable theft affects 20%, disabling Router effects for the event epoch and next; audit takes 10% gross from exact top decile; Green adds 10% in one district; Cheap halves city electricity. Severity scales outage/surge/theft probabilities, fire damage and audit/Green magnitude. Supply drop triggers at twice epoch target sales and awards an item entitlement to 5% of active farms; claims mint Common/Rare without blocking settlement on inventory capacity.

Seasons are calendar weeks from launch, using epoch-start week for mining/activity. District score includes packs, lobby and repairs in ETH equivalents. Active means at least one nonzero-hash settled epoch in that week. Every active farm in the winning district can claim one Rare-guaranteed pack. District ties choose the lowest district index.

The lottery has no paid entry or refundable deposit: each active epoch gives one ticket. After the week and all its epochs settle, anyone scans best-farm scores in batches of 1–64, then prepares a future N+2 block. Finalization draws up to three distinct farms proportionally to tickets, removing each winner's weight. Winners claim one Epic 90%/Legendary 10% item. Fewer than three entrants means every entrant wins at most once. The best in-game ETH-equivalent spend / gross token yield ratio earns 1% of weekly nominal emission; ties choose the lower address. Prize funding was reserved in each epoch, so settlement cannot mint or overdraft. No eligible best farm recycles the prize.

Expired lottery entropy cannot finalize to a caller-known seed. Anyone re-arms after 256 blocks; there is no refund because no entry principal was taken. Full inventory leaves item claims available. A failed claim rolls back the claimed flag. There is no owner selection, cancellation or prize withdrawal. Future hashes remain sequencer-influenced and delayed/rearmed resolutions are not VRF security.
