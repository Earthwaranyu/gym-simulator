# Balance Model — findings from `scripts/simulate.luau`

Run it yourself: `luau scripts/simulate.luau` (about 5 seconds). It is deterministic —
same commit, same numbers — so any change in this table is a change in the game.

The model uses the game's real `Formulas`, and reads equipment, zone, rank, and combo
numbers from `scripts/_balance_inputs.luau`, generated from the actual configs by
`scripts/extract_balance.py`. `check.sh` fails if that generated file is stale, so a
balance change cannot silently invalidate these results.

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
| Active | 2.5m | 2.7m | 18.0m | 5.26M |
| Casual | 2.5m | 5.3m | 28.5m | 529K |
| Social | 2.5m | 4.4m | 25.1m | 1.66M |
| Boosted (VIP 2x) | 2.5m | 87s | 11.1m | 36.1M |
| Killed every 2m | 2.8m | 3.1m | 21.1m | 2.81M |
| Killed every 30s | 4.5m | 6.0m | 40.5m | 161K |

**First upgrade lands at 2.5 minutes for every style**, because tokens accrue on a timer
rather than from reps — even a player being killed constantly gets their first permanent
choice inside three minutes. That comfortably meets the "first permanent choice in five
minutes" target in #111, and it does so without a Robux prompt.

The first *rank* takes 2.7 minutes and the second district 18 minutes. Eighteen minutes
is longer than a median first session is likely to be, which is a real risk for the
first-session payoff in #115: a new player probably leaves having seen one district.

## Being killed costs far more than the docs claim

| Style | deaths / 24h | combo reps lost | power vs uninterrupted |
|---|---|---|---|
| Killed every 2m | 719 | 6,883 | **−72%** |
| Killed every 30s | 2,879 | 46,422 | **−99.8%** |

This is the most important finding, and it contradicts how the design has been describing
itself. `CHECKLIST.md` #33 says death costs "no stat, cash, or token loss" and the pitch
has been that dying costs "time and combo only". Formally true — but a player killed
every two minutes ends the day with **a quarter of the power** of one who was left alone,
because the combo multiplier never gets to climb and the token clock stops while dead.

That is a fairness decision, not a bug, and it belongs to Phase 26. Stated plainly:
under the current numbers, a determined griefer can cost a victim most of their
progression rate without ever taking anything the victim can see being taken. The
kill-only interruption rule (#96) already softened this compared to hit-staggering; the
open question is whether −72% at a two-minute death rate is the intended ceiling.

## Progression pacing to the endgame

| District | needs power | reached (Active) |
|---|---|---|
| Garage | 0 | 0s |
| Iron | 25.0K | 18.0m |
| Powerhouse | 500K | 41.5m |
| Strongman | 10.0M | 72.7m |
| Titan | 200M | 2.0h |
| Skydeck | 4.00B | 3.0h |
| Storm | 80.0B | 4.5h |
| Void | 1.50T | 6.5h |
| Solar | 30.0T | 9.5h |
| Nebula | 600T | 13.8h |
| Ascendant | 12.0Qa | 19.7h |

Eleven districts inside a day of continuous play, with the gap between them widening from
18 minutes to about 6 hours. Nothing here stalls hard.

**The stall is after Ascendant.** Every style's longest gap with no upgrade, no rank, and
no new district is roughly 1.5 hours, and it begins once the last district is unlocked —
there is nothing left to unlock, which is exactly what Phase 25's endgame item (#152)
exists to fill. That is a content gap, not a tuning one.

## Sensitivity — which levers actually matter

| Change | 1st upgrade | 24h power | upgrades bought |
|---|---|---|---|
| baseline | 2.5m | 104Qa | 61 |
| gains −25% | 2.5m | 55.0Qa | 61 |
| gains +25% | 2.5m | 153Qa | 61 |
| gains ×2 | 2.5m | 301Qa | 61 |
| upgrade cost −25% | 2.0m | 282Qa | 66 |
| upgrade cost +25% | 3.2m | 27.2Qa | 58 |
| upgrade cost ×2 | 5.0m | 2.23Qa | 50 |

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
