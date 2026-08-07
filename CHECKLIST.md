# Gym Simulator — Build Checklist

Gym-training game in the vein of **Gym League**, with the key differentiator borrowed from
**Super Power Training Simulator**: PvP is live inside the gym. Players can attack each other
mid-training-set, interrupting reps to annoy them.

**Progress: 75 built / 77** — Phases 0–10 complete, Phase 11 in progress. #22 (stamina)
and #24 (training anti-exploit) were withdrawn by design, not skipped: reps are
server-driven with no client remote to exploit.

**Before this ships**, see [`docs/PLAYTEST.md`](docs/PLAYTEST.md). Two things are stubbed
on purpose: `DataService` uses the Studio mock store, and every product `AssetId` is `0`
until they exist in the Creator Dashboard.

---

## Locked Design Decisions

| Decision | Choice |
|---|---|
| Core stats | **5** — Arms, Chest, Back, Core, Legs |
| PvP zoning | **Open PvP everywhere**, except safe spawn, shop, and quest board |
| Death cost | **Time + broken combo only.** No stat, cash, or token loss |
| Progression sink | **Tokens → per-stat multiplier upgrades.** No rebirth system |
| Token accrual | Passive per-tick, **only while alive and inside a gym zone**, plus quest rewards |
| Training | **Hold E to mount.** You teleport onto the machine, lock into it, and reps tick on their own — no stamina, no clicking. Hold E again to get off |
| Assets | **Everything original.** Part-built machines, animations generated from joint angles. No Toolbox models, no uploaded animation ids |
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

- [x] 19. `EquipmentConfig.luau` — one entry per machine: stat trained, base gain, rep interval, pose, prompt verb, unlock requirement. Plus the model contract (`TrainAnchor` / `TrainExit` / `Base`) a station is expected to provide.
- [x] 20. Place machines in Studio tagged via `CollectionService`; the server binds behaviour by tag, so new machines need **no code change**.
- [x] 21. `TrainingService` — server-authoritative: **hold E to mount**, server-driven rep loop, awards stats via `StatService`. The client sends nothing.
- [~] 22. ~~Stamina system~~ — **removed by design.** Reps are free once you are on the machine; nothing paces a set. Being hit staggers you off it instead (see #32).
- [x] 23. `TrainingController` (client) — mirrors server training state for the HUD. No input to bind: mounting goes through a `ProximityPrompt`, which fires on the server.
- [~] 24. ~~Anti-exploit on training~~ — **largely moot.** Training has no client remote at all; `ProximityPrompt.Triggered` is server-side and range-checked by Roblox before it fires, and the server drives the rep loop. Revisit only if a training remote is ever introduced.

## Phase 4 — Muscle Deformation

- [x] 25. Character rig prep + a stat→body-scale mapping table. `NumberValue` instances inside the character model drive server-side MeshPart scaling.
- [x] 26. `MuscleService` — server writes the `NumberValue`s; replication is automatic.
- [x] 27. Client-side lerp so growth animates smoothly instead of popping.
- [x] 28. Scale caps + collision/animation sanity checks at extreme sizes.

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
- [x] 51. Menus — token/multiplier upgrade panel, quest log, shop, leaderboard, settings.
- [x] 52. Toast/notification system.

## Phase 8 — World & Leaderboards

- [x] 53. Gym zones — starter gym through elite tiers, gated by total power. Zones double as the token-accrual regions from #16.
- [x] 54. `OrderedDataStore` global leaderboards (Strongest, Most Kills, Highest Bounty) + physical in-world boards.
- [x] 55. Zone gates / teleporters honouring unlock requirements.

## Phase 9 — Polish & Launch

- [x] 56. SFX/VFX — rep clanks, hit impacts, level-up bursts, immortality barrier shader, multiplier-purchase flourish.
- [x] 57. Analytics events on the funnel (first rep, first kill, first multiplier buy, first purchase).
- [x] 58. Full anti-cheat sweep + global remote rate limiting.
- [x] 59. Performance pass — StreamingEnabled, animation budget, part count at high player counts.
- [x] 60. Playtest pass and launch checklist.

## Phase 10 — Making it a place, not a prototype

The first playable pass proved the systems but looked like a prototype: coloured boxes
for machines, and training that happened *to* you as you walked past.

- [x] 61. **Build the gym.** Two halls of original part-built machines — bench press with a
      loaded rack, dumbbell rack, pull-up gantry, ab bench, treadmill — inside real rooms
      with walls, mirrors and ceiling lights. Generated by `scripts/build_gym.py`, so the
      geometry is reproducible and owes nothing to the Toolbox. Each machine carries
      `TrainAnchor` parts declaring where a player is placed and how they are posed.
- [x] 62. **Hold E to train.** A `ProximityPrompt` per machine mounts the player: they are
      teleported onto the anchor, locked in place, and the rep loop starts. Holding E again
      gets them off, and so does being punched. Machines have a real capacity now, shown on
      the prompt and the billboard.
- [x] 63. **Training animations.** `PoseConfig` describes each exercise as joint angles;
      `TrainingPoseController` plays it on every training character it can see by writing
      the joint's `Transform` after the animator. Generated rather than uploaded, so no
      animation asset is referenced and nothing needs to be owned.
- [x] 64. **Run it and fix what only running finds.** A live Studio session over the MCP
      bridge. Nothing below was reachable by static analysis, and two of them meant the
      animation system did not move a single limb:
      - Characters have **no `Motor6D` at all** on current Studio builds. Roblox's avatar
        joint upgrade replaced them with `AnimationConstraint`. Both carry `Transform`;
        the controller now takes either.
      - Writing `Transform` after the render step sets the property but changes nothing.
        The value has to land on **`PreSimulation`** — after the animator evaluates,
        before the world step reads joints. Measured, not guessed.
      - Rigs enforce joint limits, so angles past ~150° stop tracking and then reverse.
        The pull-up's ±165° shoulders were on the wrong side of that.
      - The dumbbell rack stood in the only doorway between the two halls.
      - The bench barbell sat 2.9 studs from the lifter's hands; the pull-up bar 1.4
        studs above them. Both now meet the hands the pose actually reaches.
      - Players spawned on `Workspace.SpawnLocation` at the origin — mid-floor, in open
        PvP — rather than the safe-zone bubble. The project now owns that instance.
- [x] 65. **The weights move.** A lifter posed under a barbell that never budges reads as
      miming, not lifting. A training spot can now own props — `HeldBoth` for a barbell,
      `HeldRight`/`HeldLeft` for dumbbells — parked beside its `TrainAnchor`. While
      somebody trains there the prop tracks their hands, and on release it goes back to
      the rack it was authored in. Client-side only and unreplicated: every viewer puts
      the same weight in the same hands from the pose they can already see.
- [x] 66. **Walk, run, fly.** Legs becomes the traversal stat: `Formulas.WalkSpeed` was
      capped at 30 — under 2x base, forever — which was tuned for one gym hall and would
      have made a 3,000-stud map a permanent walk. Ceiling raised to ~7x. Flight unlocks
      at 8M power, held by a `LinearVelocity` so a flier still collides with the world.
      `FlightService` owns permission and publishes it as a character attribute; taking a
      hit grounds you for the stagger window, so one punch still buys one clean opening.
- [x] 67. **The big map.** Eleven tiers on a spiral out to ~1,400 studs radius, ~2,800
      across, 55 machines. The first three stand on the ground; the rest float higher and
      higher, so flight is what opens the back half and the movement ladder *is* the
      progression ladder. A hub plaza at the origin rings one gate per tier.
      **Gain rides on the zone, not the machine**: `ZoneConfig` carries a
      `GainMultiplier` (x1 to x100M) and `TrainingService` resolves a station's tier by
      which volume contains it. One `BenchPress` entry still covers all eleven benches.

## Phase 11 — A city worth hanging around in

#67 built a big map but not a place: eleven identical square decks on a golden-angle
spiral, and a 40-stud force-field bubble for a safe zone. The reference is Super Power
Training Simulator's world — a central city island ringed by themed satellites — with
GTA V's art direction on top of it. And travel becomes a **button**, not a portal.

- [x] 68. **Islands, not decks.** A `DISTRICTS` table replaces `TIERS` and the golden-angle
      spiral: bearing, radius, altitude, silhouette, palette, machine layout, one row per
      district. Bearings are hand-picked, because the point of a map is that no two
      directions look the same. Five silhouettes in a `SHAPES` registry — `slab`, `round`,
      `mesa`, `crag`, and `lot` for the two districts that stand on Downtown's ground
      rather than on an island of their own. Every island grows a **tapering rock
      underside**: once flight unlocks you spend half your time looking up at these, and a
      bare slab from below reads as a placeholder. Geometry now emits one `Folder` per
      district instead of 326 flat children, tags go through a `tagged()` helper, and the
      2048-stud `Baseplate` is gone — the map is 2,866 across and floats over nothing,
      which is the reference's look anyway.
- [x] 69. **Downtown.** A grid, not a scatter: two roads each way with the plaza in the
      block they enclose, and four avenues running out to the island edge. The twelve
      rectangles that leaves are the city's plots — ten get sidewalks, kerbs and two or
      three part-built towers apiece, picked from four skins so the city looks built over
      time rather than extruded in one pass; the other two **are** Garage Gym and Iron
      Hall, which is why those districts are `lot` shaped and stand here instead of on
      islands. Streetlights and parked cars line the grid roads, palms line the plaza and
      the promenade, and the causeway to the Docks now runs due east off the end of the
      east avenue — a bridge you have to go looking for is not a bridge anyone walks.
- [x] 70. **The plaza.** The safe zone stops being a 40-stud bubble and becomes the plaza
      itself — the only safe ground in the game and, once #72 lands, the only place travel
      is free, so it is where everybody ends up. Standing in it: **Coach**, a part-built
      figure tagged `Npc`, and two leaderboard monuments tagged `LeaderboardBoard` — two,
      not the three #54 claimed, because `LeaderboardService` defines exactly two boards
      and a monument with nothing to show is worse than no monument. Benches, palms and
      lamps ring it. All of it is inert geometry carrying a tag and an id; #75 and #76 give
      it behaviour, which keeps the world file free of anything a controller should own.
- [x] 71. **Nine themed districts.** A `PROPS` registry beside `BUILDERS`, one function per
      theme, named by a district row: **docks** (stacked containers, a gantry crane,
      bollards) · **beach** (boardwalk tower, palms, loungers, a volleyball net) ·
      **quarry** (boulders, a climbing conveyor, floodlights, tyre stacks) · **rooftop**
      (helipad, plant rooms, dishes, water tanks) · **peak** (snowdrifts, cable pylons
      strung together, weather masts) · **void** (veined monoliths, light strips) ·
      **solar** (magma channels lit from below, obsidian, braziers) · **nebula** (trusses,
      solar panels, antennae) · **celestial** (marble colonnade, reflecting pool). Props
      go in their own folder per district, and `rim_spots` skips a 28° arc around every
      spawn pad — otherwise travel drops you inside a shipping container, and the gap
      doubles as a clear walk onto the island.
- [x] 72. **Travel is a button.** `ZoneService` and every `ZoneGate` slab are gone;
      `TravelService` owns the rules the geometry used to. It checks **power** (the same
      test the gates made), **where you are** — free travel only from inside a `SafeZone`,
      which is the plaza, unless you own Fast Travel — and **whether you are in a fight**,
      reusing `FlightService:IsGrounded` so travelling out of a losing fight is refused on
      exactly the window that already stops you flying out of one. It dismounts you first,
      because pivoting a player whose root is anchored to a `TrainAnchor` strands them and
      leaves the station reading as occupied.
      Two things fell out of it. The landing pads had become discs — a cylinder stood on
      its end — and landing a player on one would have laid them on their side, so they
      are flat boxes again, unrotated so you arrive facing the gym. And **removing the
      gates opened a hole**: with Iron Hall on a Downtown street, nothing physical stopped
      a fresh player walking in and training at x6. Gain already rides on the zone, so
      mounting now does too — `TrainingService` checks the district's `RequiredPower`
      alongside the machine's. Geometry stops being the gate; config is.
- [x] 73. **The travel map.** A `Map` tab — one entry in `MenuController.tabs`, the
      declared extension point — drawing every district as a pin on a plan view, dimmed
      when locked, with a panel underneath for the selected one: tagline, gain multiplier,
      and either a Travel button or what it still costs. It opens on this tab now, and a
      marker shows where you are standing, so the map answers "where am I" as well as
      "where can I go". Pins are **numbered, not named** — eleven labels on a 616px board
      pile up in the middle where Downtown's two gyms nearly overlap, and an unreadable map
      is worse than a list. Pad positions come from the `GetDestinations` remote rather
      than from `Workspace`: with streaming on, a district 1,500 studs away is not
      replicated, so a client measuring for itself would draw only what happened to be
      loaded.
- [x] 74. **Fast Travel gamepass.** 149 R$ to travel from wherever you are standing
      instead of only from the plaza. One new file implementing `Types.Product`, no service
      edits — and its `Grant` deliberately does nothing: `TravelService` asks whether the
      player owns the pass at the moment they travel, so ownership is read live rather than
      mirrored onto the profile. That makes it trivially idempotent and makes a refund take
      effect at once. It sells the walk back, never the grind; every district's power
      requirement applies to owners exactly as it does to everyone else. The Map tab is its
      point of sale, and with `AssetId` still `0` the server answers "not available yet",
      which the toast shows verbatim.
- [x] 75. **NPCs that do something.** `NpcConfig` (id, title, prompt verb, which tab it
      opens) plus a client `NpcController` that gives every model tagged `Npc` a proximity
      prompt and a nameplate, and a new `MenuController:Open(tabId)` for it to call.
      **Entirely client-side, and deliberately so** — every NPC opens a screen the menu
      already has, so a server half would be a remote whose only job is telling the client
      to open its own UI. Bound per tagged model and rebound on add/remove, because
      streaming unloads the plaza while you are out at a district; a one-shot pass at
      startup leaves the quest giver mute for the rest of the session. Adding a shopkeeper
      is an entry plus a tagged model.
- [x] 76. **The boards read.** `LeaderboardBoardController` puts a `SurfaceGui` on every
      monument's `Screen` and fills it from the `GetLeaderboard` remote #54 has been
      serving to a menu tab nobody opens. **One call feeds every monument on screen** —
      the remote returns all boards at once and is rate-limited to one a second at the
      other end — on a 30-second cycle, because the boards themselves only move every two
      minutes. The face is named `Enum.NormalId.Back` explicitly: this script's convention
      is that the side you approach from is local +Z, and Roblox's `Front` is -Z. An empty
      board says "no entries yet" rather than going blank, which is the normal state in
      Studio, where `OrderedDataStore` is unreachable.
- [x] 77. **Don't fall forever.** `VoidService` returns anyone below -250 to the plaza —
      no death, no lost combo, no forfeited token tick, because stepping off an edge is a
      mistake rather than a play. That height is below the lowest geometry in the game
      (Downtown's rock underside bottoms out at -136) and above `FallenPartsDestroyHeight`,
      so it fires before Roblox kills them.
      Then the streaming pass, which found the real problem with travel: **it crosses up
      to 1,500 studs into a region the client has never loaded**, and a character placed
      on ground that does not exist falls straight through it. Three fixes — Workspace
      gets `StreamingIntegrityMode = PauseOutsideLoadedArea`, `TravelService` waits up to
      a second on `RequestStreamAroundAsync` before it pivots, and every tagged model
      (55 machines, the Coach, both monuments) is `ModelStreamingMode = Atomic`, so a
      bench arrives whole instead of one part at a time with the `TrainAnchor` still
      missing. 2,867 instances across the whole map, one folder per district.

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
