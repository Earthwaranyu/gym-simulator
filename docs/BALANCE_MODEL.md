# Balance Model — findings from `scripts/simulate.luau`

Run it yourself: `luau scripts/simulate.luau` (about 5 seconds). It is deterministic —
same commit, same numbers — so any change in this table is a change in the game.

The model uses the game's real `Formulas`, and reads equipment, zone, rank, and combo
numbers from `scripts/_balance_inputs.luau`, generated from the actual configs by
`scripts/extract_balance.py`. `check.sh` fails if that generated file is stale, so a
balance change cannot silently invalidate these results.

> **Additive-rate note (#121):** every exercise pays exactly once per second. Manual
> training grants the universal +1 base; a machine adds its x1–x64 equipment bonus, so
> a starter station pays +2/s before owned multipliers. Combo is a discrete x2 only
> after a complete 50-tick set—there is no longer hidden fractional gain each second.
> Animation cycles still vary from 0.5–1.2 seconds but no longer drive payout timing.
> The tables below were regenerated from all 35 live definitions. Void, Solar, Nebula
> and Ascendant remain dormant future themes and are not reachable in this build.

**What is measured and what is assumed.** Everything about the *game's* numbers is
measured from the configs. Everything about *player behavior* — training uptime, how
often someone is killed, how long they take to remount — is a stated assumption, listed
per play style in the script. Replace those with real numbers after #102's alpha
sessions; until then, read every row below as "given these behaviors", not "players
will".

Results below are from the 24-hour horizon at the commit that added this file.

## The first ten minutes work

| Style | 1st upgrade | 1st rank | 2nd district | power @ 1h |
|---|---|---|---|---|
| Active | 2.5m | 12.1m | 4.0m | 84.3K |
| Casual | 2.5m | 19.2m | 7.2m | 32.9K |
| Social | 2.5m | 17.1m | 6.2m | 40.4K |
| Boosted (VIP 2x) | 2.5m | 6.9m | 2.1m | 215.3K |
| Killed every 2m | 2.8m | 13.8m | 4.5m | 50.0K |
| Killed every 30s | 4.5m | 23.5m | 7.5m | 15.4K |

**First upgrade lands at 2.5 minutes for every style**, because tokens accrue on a timer
rather than from reps — even a player being killed constantly gets their first permanent
choice inside three minutes. That comfortably meets the "first permanent choice in five
minutes" target in #111, and it does so without a Robux prompt.

The second location tier now arrives at 4.0 minutes for an active player, while the first
rank arrives at 12.1 minutes. The additive starter machine makes its advantage immediately
visible without pretending its printed +1 equipment bonus replaced the player's base.

## Being killed costs far more than the docs claim

| Style | deaths / 24h | combo ticks lost | power vs uninterrupted |
|---|---|---|---|
| Killed every 2m | 719 | 5,033 | **−37.1%** |
| Killed every 30s | 2,879 | 36,012 | **−89.4%** |

This is the most important finding, and it contradicts how the design has been describing
itself. `CHECKLIST.md` #33 says death costs "no stat, cash, or token loss" and the pitch
has been that dying costs "time and combo only". Formally true — but a player killed
every two minutes ends the day with only **about 63% of the power** of one who was left alone,
because repeated deaths prevent full 50-tick sets and the token clock stops while dead.

That is a fairness decision, not a bug, and it belongs to Phase 26. Stated plainly:
under the current numbers, a determined griefer can still erase much of a victim's
progression rate without taking a saved currency. The kill-only interruption rule (#96)
softens this; the open question is whether −37.1% at a two-minute death rate is acceptable.

## Progression pacing to the endgame

| District | needs power | reached (Active) |
|---|---|---|
| Garage | 0 | 0s |
| Iron | 500 | 4.0m |
| Powerhouse | 5.00K | 18.8m |
| Strongman | 50.0K | 52.2m |
| Titan | 500K | 1.8h |
| Skydeck | 5.00M | 3.4h |
| Storm | 50.0M | 6.0h |
| Void | 1.50T | never (dormant) |
| Solar | 30.0T | never (dormant) |
| Nebula | 600T | never (dormant) |
| Ascendant | 12.0Qa | never (dormant) |

All seven active tiers arrive inside about 6 hours of continuous active play. The next
configured zone is intentionally dormant, so endgame must come from future horizontal
goals rather than an accidentally reachable placeholder multiplier.

## Sensitivity — which levers actually matter

| Change | 1st upgrade | 24h power | upgrades bought |
|---|---|---|---|
| baseline | 2.5m | 8.27B | 61 |
| gains −25% | 2.5m | 6.19B | 61 |
| gains +25% | 2.5m | 10.35B | 61 |
| gains ×2 | 2.5m | 16.60B | 61 |
| upgrade cost −25% | 2.0m | 15.80B | 66 |
| upgrade cost +25% | 3.2m | 5.00B | 58 |
| upgrade cost ×2 | 5.0m | 1.77B | 50 |

Two things fall out of this:

1. **Base gain does not affect pacing at all, only scale.** Doubling every machine's
   output leaves the first upgrade at 2.5 minutes and the upgrade count at 61, because
   tokens come from a clock rather than from reps. Machine gain is a *number-size* dial,
   not a progression dial.
2. **Upgrade cost is the only real pacing lever, and it is violently non-linear.** A 25%
   cost increase costs the player 74% of their 24-hour power; doubling costs takes away
   98%. The exponential cost curve compounds against the doubling multiplier, so small
   edits here are not small.

The practical rule: **tune pacing with `MultiplierCost` and the token tick, never with
`BaseGain`.** And treat any change to the cost curve as a major change requiring a fresh
run of this model, not a tweak.

## Known limits of this model

- One player, one server. No queueing for occupied machines, no travel time between
  districts, no competition for a station.
- Uptime is a duty cycle, not real behavior: the player trains for the first N% of every
  minute. It gets the *ratio* right and the burstiness wrong.
- Cash, the shop, quests, and Robux products are not modelled — only tokens and stats.
- The greedy "buy the cheapest upgrade the moment it is affordable" policy is what an
  unoptimising player does. A player who saves for a specific stat will differ.
