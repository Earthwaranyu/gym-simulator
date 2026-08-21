# Balance Model — current findings

Run `luau scripts/simulate.luau` for the deterministic 24-hour audit. For the
full transformation audit use `luau --codegen scripts/simulate.luau -a 168`. The model reads
the live exercise, district, load, token, combo, and per-muscle multiplier configs.

Its balanced policy always trains the lowest of Arms, Chest, Back, Core, and Legs,
uses the best unlocked district and supported load, buys the cheapest next multiplier
for an individual muscle, and performs the next physique transformation as soon as its
total-Power gate is met. The simulation assumes the required Fight Tokens are already
available, so transformation timestamps are the training-side lower bound; the live
game additionally requires 2,555 Fight Tokens across the full class path. Player behavior such as
training uptime and death frequency remains an explicit assumption.

## Extreme PvP model

Combat uses visible power-ratio bands rather than logarithmic defensive curves.
Arms is raw punch damage and Chest grants 10 max HP per point, plus the base 100 HP.
At equal Arms and Chest an unblocked fight therefore takes about ten hits; a 10× Arms
advantage over Chest approaches a one-hit kill.

Core resolves first against the attacker's Arms. Equal or lower Core reflects nothing;
greater Core reflects 10%; 10× Core nullifies the hit and fully reflects it. Back then
uses the same documented SPTS bands on what remains: equal or lower Back blocks nothing,
greater Back blocks 10%, and 10× Back blocks everything. Reflected damage is true return
damage: it bypasses the attacker's Back, never triggers another reflection, and can kill
even when the original remaining hit also kills the defender. Safe zones and immortality
still stop both ordinary and reflected damage.

The original game is closed-source and community documentation states only the greater
than and 10× bands. The previous 2× and 5× steps were therefore removed. One requested
extension remains: at full reflection the counter is at least `100 + defender Core`.
This makes `/power 1000` (200 Core) return 300 against a zero-stat attacker's 100 HP,
instead of returning only the attacker's one raw damage. Equal-stat players receive raw
damage with no block or reflection, producing an approximately ten-hit fight when Arms
and Chest are trained equally.

## District progression

Runtime access is per relevant muscle. The balanced Power equivalent is five times the
entry requirement: the amount shown when every route has opened that district.

| District | Rate | Relevant muscle to enter | Balanced Power equivalent | Load range |
|---|---:|---:|---:|---:|
| Muscle Beach | x1 | 0 | 0 | 0–100 kg |
| Civic Park | x2 | 10K | 50K | 0–1K kg |
| Boardwalk Club | x4 | 50K | 250K | 0–10K kg |
| Freight Yard | x8 | 200K | 1M | 0–100K kg |
| Titan Square | x16 | 1M | 5M | 0–1M kg |
| Apex Office | x32 | 5M | 25M | 0–10M kg |
| Stormline Rooftop | x64 | 50M | 250M | 0–100M kg |

Every district has eleven selections: the bare/unloaded state plus ten equal load
jumps. Late selections use a
`progress^1.65` stat requirement curve, and the final selection is the next district's
exact entry requirement. The load bonus rises from x1 to x2 and all ten steps have a
distinct physical plate/stack change; the geometry's ten states stay hidden at
zero and reach a full stack at the maximum.

## Verified active pacing

The 168-hour deterministic run gives the uninterrupted Active policy (90% mounted
uptime, no Robux boost) this cumulative route under immediate, Fight-Token-funded transformations:

| Milestone | Time |
|---|---:|
| First muscle multiplier | 2.5m |
| Conditioned transformation | 46.7m |
| Civic Park | 1.6h |
| Defined transformation | 1.9h |
| Boardwalk Club | 2.7h |
| Shredded transformation | 3.3h |
| Freight Yard | 4.0h |
| Titan Square | 4.7h |
| Powerbuilt transformation | 5.2h |
| Apex Office | 6.8h |
| Elite transformation | 8.2h |
| Stormline Rooftop—all five muscles at 50M | 10.9h |
| Beast transformation | 13.3h |
| Monster transformation | 22.7h |
| Titan transformation | 43.7h |
| Mythic transformation | 3.7d |

A regular player around 50% training uptime should take roughly 6–8 days to reach
Mythic under this immediate-transform policy. Interruptions, travel, menus, delayed
multiplier purchases, or choosing to finish a district before transforming lengthen it.

## Physique transformations

Classes are permanent and sequential. The listed total Power is a gate, not a cost;
all five lifetime stats persist, while their current values are captured as the new
visual-growth baseline. The avatar becomes lean in the next class colour and grows each
muscle again from subsequent training. Fight Tokens are spent. A rewarded direct or
Core-reflection KO grants one Fight Token; repeat kills inside CombatService's anti-farm
window grant none.

Each class also doubles the playtime token tick, which is what keeps income in step
with multiplier costs that double eighteen times over only nine transformations.

| Class | Total Power | Fight Tokens | Token rate |
|---|---:|---:|---:|
| Natural | 0 | 0 | x1 |
| Conditioned | 10K | 5 | x2 |
| Defined | 100K | 10 | x4 |
| Shredded | 1M | 20 | x8 |
| Powerbuilt | 10M | 40 | x16 |
| Elite | 100M | 80 | x32 |
| Beast | 1B | 160 | x64 |
| Monster | 10B | 320 | x128 |
| Titan | 100B | 640 | x256 |
| Mythic | 1T | 1,280 | x512 |

## Per-muscle token multipliers

Each muscle independently owns the historical SPTS permanent doubling path from x1
through x262,144. There is no Power or muscle-stat gate. Each level costs exactly twice
the one before it, so the price per unit of multiplier never changes and no level is a
bargain. The 18 upgrade costs are 100, 200, 400, 800, 1.6K, 3.2K, 6.4K, 12.8K, 25.6K,
51.2K, 102.4K, 204.8K, 409.6K, 819.2K, 1.64M, 3.28M, 6.55M and 13.11M tokens —
26,214,300 to take one muscle to the cap.

## Monster rewards

Both currencies double per tier. A goblin pays Fight Tokens, spent on transformations;
a boss pays Tokens, spent on multipliers, and is the only combat source of them.

| Tier | Goblin (Fight Tokens) | Boss (Tokens) |
|---|---:|---:|
| Garage | 1 | 10 |
| Iron | 2 | 20 |
| Powerhouse | 4 | 40 |
| Strongman | 8 | 80 |
| Titan | 16 | 160 |
| Skydeck | 32 | 320 |
| Storm | 64 | 640 |

## Known limits

- One player, no machine queueing or explicit travel time.
- The Active policy is unusually disciplined; real retention cohorts should replace
  these assumptions once enough telemetry exists.
- Cash, quests, and Robux boosts are not modeled.
- Fight Token acquisition is not modeled; transformation times assume the required
  Fight Tokens have already been earned. This mattered little at a flat +5 per class
  and matters more now the full path costs 2,555.
- The district table above still uses the old campus names. Zones were renamed to
  tiers and the machines scattered across the city; the rates and gates are current,
  the names are not.
