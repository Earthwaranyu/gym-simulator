# Gym Simulator — Build Checklist

Gym-training game in the vein of **Gym League**, with the key differentiator borrowed from
**Super Power Training Simulator**: PvP is live inside the gym. Players can attack each other
mid-training-set, interrupting reps to annoy them.

**Progress: 51 / 60** (2 items withdrawn: #22, #24) — Phases 0 and 1 complete.

---

## Locked Design Decisions

| Decision | Choice |
|---|---|
| Core stats | **5** — Arms, Chest, Back, Core, Legs |
| PvP zoning | **Open PvP everywhere**, except safe spawn, shop, and quest board |
| Death cost | **Time + broken combo only.** No stat, cash, or token loss |
| Progression sink | **Tokens → per-stat multiplier upgrades.** No rebirth system |
| Token accrual | Passive per-tick, **only while alive and inside a gym zone**, plus quest rewards |
| Training | **Automatic on proximity.** No stamina, no clicking — walk to a machine and the stat climbs |
| PvP opt-out | **Paid only** — immortal potions (19 R$ / 1h, 79 R$ / 1 day) and VIP (199 R$, 1h daily) |
| Reputation | Criminal → Neutral → Guardian → Hero, driven by who you kill |
| Git | One commit per checklist item. No co-author trailer. |

## Governing Architectural Rule

**Closed for modification, open for extension.** Adding content must never require editing the
system that consumes it:

- Content lives in **config tables** — new machine, stat, rank, quest, potion, or shop item =
  new table entry.
- Behaviours live in **registries** — new ability or quest = new file in a folder,
  auto-discovered. No `if abilityName == "Punch"` branching anywhere.
- Systems implement a **lifecycle interface** (`Init` / `Start`) and are auto-loaded.
- Stat math flows through a **modifier stack**, so token multipliers, gamepasses, and boosts
  compose without touching the base formula.

---

## Phase 0 — Foundations

- [x] 1. Realign `default.project.json` to the `CLAUDE.md` structure; delete the template stubs. Correct "9 Core Stats" → "5 Core Stats".
- [x] 2. Add Wally (`wally.toml`) + register it in `rokit.toml`; pull in the data library, Signal, and Promise. → ProfileStore 1.0.3 (server realm), Signal 2.0.3, Promise 4.0.0
- [x] 3. Add StyLua + Selene configs; enforce `--!strict` on every `.luau` file.
- [x] 4. `ServiceLoader` / `ControllerLoader`: auto-require every module in a folder, `Init()` all, then `Start()` all. **This is the OCP backbone.** → `Modules/Loader.luau`
- [x] 5. `Types.luau` — shared exported type definitions.
- [x] 6. `Net.luau` — single typed module that creates and hands out every RemoteEvent/RemoteFunction.
- [x] 7. `NumberFormat.luau` — abbreviation module (K → Vg, ~1e63) with a passing self-test.

## Phase 1 — Data Layer

- [x] 8. `ProfileTemplate` schema: stats, tokens, per-stat multiplier levels, cash, owned equipment, quest progress, **reputation**, **immortality expiry**, kill/death record, settings, `SchemaVersion`.
- [x] 9. `DataService` — session locking, release on leave, `BindToClose` flush.
- [x] 10. Migration system: ordered list of version-bump functions, so the schema grows without breaking live saves.
- [x] 11. Replication: server pushes an authoritative read-only profile view to the owning client; client never writes.

## Phase 2 — Stats, Tokens & Progression

- [x] 12. `StatConfig.luau` — one entry per core stat (id, display name, colour, icon, body parts it inflates). The 5 stats live here and **only** here.
- [x] 13. `StatService` — `AddStat` / `GetStat` / `GetTotalPower`, all gains passed through a **modifier stack** (`base * product(multipliers)`).
- [x] 14. `Formulas.luau` — gain-per-rep, token accrual rate, multiplier cost curve, soft-cap / diminishing returns. Pure functions, no side effects.
- [x] 15. Rank/Title system driven by a threshold table (Newbie → Lifter → … → Titan).
- [x] 16. `TokenService` — passive token accrual on a server tick. Requires the player to be **alive and inside a gym zone**, so AFK farming fails and AFK bodies become free kills.
- [x] 17. **Multiplier upgrades** — spend tokens to permanently raise a chosen stat's multiplier. Registers as a source in the #13 modifier stack. Replaces rebirth as the long-term sink.
- [x] 18. **Quest registry** — quests are self-contained auto-discovered modules (objective type, progress hook, token reward, repeat/daily flag). New quest = new file.

## Phase 3 — Training Loop

- [x] 19. `EquipmentConfig.luau` — one entry per machine: stat trained, base gain, stamina cost, animation id, interaction type, unlock requirement, price.
- [x] 20. Place machines in Studio tagged via `CollectionService`; the server binds behaviour by tag, so new machines need **no code change**.
- [x] 21. `TrainingService` — server-authoritative: **auto-starts on proximity**, server-driven rep loop, awards stats via `StatService`. The client sends nothing.
- [~] 22. ~~Stamina system~~ — **removed by design.** Training is automatic and free; nothing paces a set. Being hit staggers you off the machine instead (see #32).
- [x] 23. `TrainingController` (client) — mirrors server training state for the HUD. No input to bind, since training is automatic.
- [~] 24. ~~Anti-exploit on training~~ — **largely moot.** Training has no client remote at all now; the server drives the loop and re-checks distance every tick. Revisit only if a training remote is ever reintroduced.

## Phase 4 — Muscle Deformation

- [x] 25. Character rig prep + a stat→body-scale mapping table. `NumberValue` instances inside the character model drive server-side MeshPart scaling.
- [x] 26. `MuscleService` — server writes the `NumberValue`s; replication is automatic.
- [x] 27. Client-side lerp so growth animates smoothly instead of popping.
- [ ] 28. Scale caps + collision/animation sanity checks at extreme sizes.

## Phase 5 — PvP (the differentiator)

- [x] 29. `CombatService` — server-authoritative damage, hit validation, cooldowns, i-frames.
- [x] 30. Damage/health model derived from stats (Arms + Chest → damage, Core → max HP, Legs → walkspeed).
- [x] 31. **Ability registry** — folder of ability modules sharing one interface (`Cost`, `Cooldown`, `Validate`, `Execute`). Punch, Slam, Dash ship first; new abilities are new files only.
- [x] 32. **Training interrupt** — the core hook. Being hit knocks you off the machine for 3s and resets the rep combo. With training otherwise free, this stagger is the *entire* cost of being attacked — and the whole reason to attack a trainer.
- [x] 33. Death & respawn — respawn timer, rep-streak reset, in-flight token tick forfeited. **No stat, cash, or token loss on death.** *(ragdoll deferred to #56 VFX)*
- [x] 34. **Reputation system** — data-driven tiers (Criminal → Neutral → Guardian → Hero). Killing peaceful trainers pushes you toward Criminal; killing Criminals pushes you toward Hero. Tier table is config, not code.
- [x] 35. **Immortality + barrier** — `CombatService` nullifies all damage while a potion is active, and the player wears a visible body barrier so attackers can see it before swinging.
- [x] 36. Bounty / killstreak system with a revenge incentive so victims get a comeback path.
- [x] 37. Safe zones — tagged parts at spawn, shop, and quest board where damage is nullified. Everywhere else, including every training station, is live.
- [x] 38. Anti-grief balance: damage falloff on large power gaps, and a cooldown blocking repeat-farming the same victim.
- [x] 39. Kill feed + on-screen combat notifications.

## Phase 6 — Economy & Monetisation

- [x] 40. `CurrencyService` — cash from reps, kills, and bounties. Kept distinct from Tokens.
- [x] 41. Data-driven shop catalogue: gym-tier unlocks, supplements (timed multipliers), abilities.
- [x] 42. `MarketplaceService` handler — gamepasses + dev products, **idempotent** receipt processing.
- [x] 43. **Immortal potions** as dev products: 1 hour for 19 R$, 1 day for 79 R$. Expiry stored on the profile so it survives rejoin.
- [x] 44. **VIP gamepass** at 199 R$ — grants one 1-hour immortal potion per day, with a daily-claim reset.
- [x] 45. Boost/multiplier sources all register into the Phase-2 modifier stack (#13) — 2x Stats, VIP, token boosts, and event buffs must not special-case.

## Phase 7 — UI

- [x] 46. UI base components: glassmorphism, custom typography, mandatory `UICorner` / `UIPadding` / `UIAspectRatioConstraint`.
- [x] 47. HUD — stat panel, total power, rank badge, token counter, combo/stagger readout, active-potion timer.
- [x] 48. Training interaction + minigame UI.
- [x] 49. Combat HUD — health bar, ability bar with cooldown sweeps, kill feed.
- [x] 50. **Custom tab bar / player list** — replaces the default Roblox list, showing each player's overall power and reputation.
- [ ] 51. Menus — token/multiplier upgrade panel, quest log, shop, leaderboard, settings.
- [x] 52. Toast/notification system.

## Phase 8 — World & Leaderboards

- [ ] 53. Gym zones — starter gym through elite tiers, gated by total power. Zones double as the token-accrual regions from #16.
- [x] 54. `OrderedDataStore` global leaderboards (Strongest, Most Kills, Highest Bounty) + physical in-world boards.
- [ ] 55. Zone gates / teleporters honouring unlock requirements.

## Phase 9 — Polish & Launch

- [ ] 56. SFX/VFX — rep clanks, hit impacts, level-up bursts, immortality barrier shader, multiplier-purchase flourish.
- [ ] 57. Analytics events on the funnel (first rep, first kill, first multiplier buy, first purchase).
- [ ] 58. Full anti-cheat sweep + global remote rate limiting.
- [ ] 59. Performance pass — StreamingEnabled, animation budget, part count at high player counts.
- [ ] 60. Playtest pass and launch checklist.

---

## Milestone 1 — Vertical Slice

Proves the full **train → grow → get killed → keep going** loop before any content scaling.

In scope: **1–9, 11–14, 16, 17, 19–23, 25–27, 29–33, 37, 46, 47, 49**
(item 10 lands as a migration stub with one no-op entry)

Deferred: ranks (15), quests (18), anti-exploit hardening (24), reputation and immortality
(34, 35), bounty and anti-grief (36, 38), the economy phase (40–45), tab bar (50), world zones
and leaderboards (53–55), and all of Phase 9.

### Acceptance test

1. `rojo build -o gym-simulator.rbxlx` succeeds; Studio Script Analysis is clean under `--!strict`.
2. Two-client playtest: player A trains on the bench press and visibly grows; player B punches A
   mid-set; A's rep combo breaks and stamina drops; A dies, respawns, and returns with stats,
   cash, and tokens fully intact.
3. Token counter increments only while alive inside the gym zone — safe spawn and death accrue nothing.
4. Rejoin restores stats, tokens, and multiplier levels.
5. **OCP smoke test**: adding a second machine (config entry + tagged model) and a second ability
   (one new file) requires zero edits to `TrainingService`, `CombatService`, or `StatService`.
