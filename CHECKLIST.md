# Gym Simulator — Build Checklist

Gym-training game in the vein of **Gym League**, with the key differentiator borrowed from
**Super Power Training Simulator**: PvP is live inside the gym. Players can attack each other
mid-training-set, interrupting reps to annoy them.

**Foundation status: 93 completed / 95 historical items.** #22 (stamina) and #24
(training anti-exploit) were withdrawn by design, not skipped: reps are server-driven
with no client remote to exploit.

**Growth roadmap: 0 / 73 items complete (#96–#168).** The checked foundation proves a
large playable prototype; it does **not** mean the product is ready for a public launch.

**Current public-launch blockers:** `DataService` still uses the Studio mock store, four
product `AssetId`s are `0`, sound IDs are blank, and real persistence, Robux receipts,
multiplayer balance, mobile controls, and load testing are incomplete. The current
[`docs/PLAYTEST.md`](docs/PLAYTEST.md) also describes an older world and is reconciled in
#96 before it is used as release evidence.

---

## Locked Design Decisions

| Decision | Choice |
|---|---|
| Core stats | **5** — Arms, Chest, Back, Core, Legs |
| PvP zoning | **Open PvP everywhere**, except safe spawn, shop, and quest board |
| Death cost | **Time + broken combo only.** No stat, cash, or token loss |
| Progression sink | **Tokens → per-stat multiplier upgrades.** No rebirth system |
| Token accrual | Passive per-tick, **only while alive, inside a gym zone, and somewhere you can be attacked**, plus quest rewards |
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
      *Superseded by Phase 14: that wiring disagreed with `CLAUDE.md` on four of the five
      stats and left Back doing nothing. See #86–#90.*
- [x] 31. **Ability registry** — folder of ability modules sharing one interface (`Cost`, `Cooldown`, `Validate`, `Execute`); new abilities are new files only.
      *Corrected by #96: only **Punch** ships. Slam and Dash are **deferred** to the
      three-move kit in #122 — no doc may imply they exist. See `docs/PRODUCT_TRUTH.md`.*
- [x] 32. **Training interrupt** — the core hook.
      *Superseded by #96: interruption is now **kill-only**. A hit damages and grounds
      the victim but leaves them mounted; only death dismounts them and resets the
      combo. The attacker must commit to a full kill, so the cost of interrupting is
      proportional to the effort of causing it.*
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
- [x] 78. **Run it again, and fix what only running finds.** A live Studio session over the
      MCP bridge, the #64 method. The boot log is clean — 23 services, 14 controllers, no
      station outside a zone, no district without a landing pad — and the travel rules all
      hold from a real client: a locked district refuses with its shortfall, an unlocked one
      lands you on its pad, a second attempt hits the cooldown, and travelling from outside
      the plaza is refused. All 55 stations resolve to the district they stand in, so the
      tiering the new mount gate reads is right for every one of them.
      One real bug, and only visible from the air: **the edge kerbs were inverted**. The
      bar at `x = half` was given the island's *full width* along X instead of along Z, so
      each of the four kerbs shot a whole island's width out into the void. Inherited
      unnoticed from #67's `platform()` — from inside a district it looks like a kerb.
      Two things that looked like bugs and were not, both worth writing down: a district
      origin carries a yaw, so a world-space bounding box over-reports a rotated part by up
      to 41% and invents overhangs that aren't there — the check now measures in the
      district's own frame. And discs are cylinders stood on end, so their two equal axes
      are a circle, not a square.

## Phase 12 — Reachable without being told

- [x] 79. **Buttons, not a hotkey.** Map, Upgrades, Shop, Top and Settings get a permanent
      bar down the right of the screen. Everything the menu holds used to be behind either
      the M key or a walk back to the plaza, and neither is discoverable: a player who
      never presses M never learns the game has upgrades, and one out on Storm Peak cannot
      reach the shop without travelling home first. **Quests deliberately has no button** —
      Coach standing in the plaza is how you are meant to find those, and a sixth button
      beside the others would make him scenery. Which tabs appear is `OnBar` on the tab
      itself, defaulting to true, so the bar never names a screen and a new tab arrives
      with a button already. `Toggle(tabId)` closes on a second press, because a button
      that is always on screen has to put you back where you were.
- [x] 80. **Spawn where you train.** Garage Gym *is* the spawn now: five machines on
      painted bays ringing the plaza you appear on, 92 studs out — the first thing a new
      player can see from where they land is the thing the game is about. Its old city
      block became another block of buildings, Iron Hall moved to a corner plot, and the
      street grid widened from ±140 to ±170 to make room.
      The interesting part is what had to change to allow it. A gym built *around* the
      shelter means its zone volume covers the shelter, and **no arrangement of boxes wraps
      a ring without covering its middle** — so a plaza inside a gym zone would have been a
      safe AFK farm, the exact thing token accrual exists to prevent. Trying to dodge it
      with geometry pushed the machines out past 115 studs and still only just worked. So
      the rule moved into `TokenService` instead: **no pay where you cannot be hit.** That
      is both simpler and more honest than the volumes it replaces — it holds for every
      safe zone that will ever exist, not just the ones somebody remembered to draw around.
      Verified live: 34 seconds stood at spawn earns nothing, the same 34 seconds at a
      machine earns, and every training spot sits 17 studs outside the shelter so the PvP
      hook still reaches it.

## Phase 13 — A UI that survives a phone

#79 put the menu on screen and solved discoverability. It did not solve the buttons:
five identical dark text rectangles, on the edge of the screen mobile uses to drag the
camera, at 38px against a ~48px touch floor, with no feedback on press. This phase takes
the genre's **ergonomics** — icon first, left column, big targets, immediate feedback —
and keeps the project's **styling**, because `CLAUDE.md` asks for GTA V over bubbly
Roblox UI.

- [x] 81. **Icons drawn, not uploaded.** `Icons.luau`: one builder per glyph, each
      assembled from Frames with `UICorner`, `UIStroke` and `Rotation`. Interface art was
      the last place the everything-original rule had not reached, and a Toolbox icon pack
      would have broken it for five small pictures. Everything inside a builder is in
      **scale, never offset**, so an icon is whatever size its tile is — which is what lets
      #85 resize the bar without touching this file.
      Shapes are picked for what survives 28px on a phone: no gear and no shopping cart,
      because a circle of teeth costs a dozen Frames and reads as a grey blob at that size.
      **Studio's screen capture does not render GUIs at all** — a SurfaceGui filled edge to
      edge with bright green photographs as a black rectangle — so these were being written
      blind. `scripts/preview_icons.luau` fixes that: it draws the real glyph, reads back
      each Frame's laid-out geometry and mirrors it into Parts the capture *can* see. Two
      icons were wrong the first time it was pointed at them: Shop was a rotated square and
      so the same silhouette as Map, and Settings' round knobs merged into their rails.
- [x] 82. **A button that behaves like one.** `UI.Pressable` grows a button under the
      pointer and shrinks it under a press, springing back on release — or when a finger
      slides off it, which never sends a release and would otherwise leave the tile stuck
      shrunk. It listens on `InputBegan` rather than `MouseButton1Down`: the mouse events
      do fire for touch, but a control that has to work on a phone should be listening to
      the phone. `AutoButtonColor` is switched off, because it tints by a few percent —
      invisible on a dark theme, which is exactly why the old bar felt like it had not
      registered the press — and because left on it fights the tween on the same events.
      Lives in `UI.luau` beside the palette for the reason `UI.Panel` does: how hard a
      button presses is styling, and a restyle should stay one file. Plus a blank
      `EffectsConfig.Sounds.UiClick`, quieter and pitch-jittered because it is the one
      sound a player can trigger as fast as they can tap.
- [x] 83. **The bar, rebuilt.** Left edge on the vertical centre, 164×56 buttons — an icon
      tile, a label, 8px apart — using `Icons` and `UI.Pressable`. Three deliberate
      corrections to #79: **left, not right**, because the right half of a phone screen is
      where you drag to turn the camera; **56px, not 38**, which clears the touch floor;
      and **icon first**, because five dark rectangles of text read as more HUD panels.
      The open tab fills with the accent and knocks its glyph out of it, driven by a new
      `MenuController.Changed` signal rather than set at click time — Escape and the ✕
      never touch the bar, so a click-time highlight would stay lit after them.
      This leaves the bar overlapping the stat panel, which #84 is for.
- [x] 84. **Room on the left.** The Summary and Stats panels were two stacks 250px tall
      owning the whole left column, which left the bar nowhere to go. They merge into one
      block 84px tall: power and tokens on one line, the five stats as a wrapping grid of
      coloured chips underneath. Still generated from `StatConfig.List`, so a sixth stat
      still needs no edit here, and chips truncate rather than run over their neighbour
      because these numbers reach the trillions.
      It also fixed something older. Both ScreenGuis had `IgnoreGuiInset = true`, which
      puts y = 0 at the true top of the screen — *underneath* Roblox's own top bar — so
      the summary panel at y = 16 had been clipped by it on every device. The first attempt
      was a `TOP_INSET = 44` constant; the real inset measured 58 and is not a constant
      across devices, so the answer is to stop ignoring it and let Roblox place the origin.
      Verified in a live session: zero overlaps between any two panels or the bar.
- [x] 85. **Fits a phone.** Modelling the layout against real device heights killed the
      original design outright: **a column of five 56px buttons needs 312px, and no phone
      has it** once the bottom 40% is given back to the thumbstick and the jump button —
      an iPhone 14 in landscape leaves about 126px between the HUD and the touch zone.
      So `MenuBarController._plan` decides the shape from the geometry rather than assuming
      one: a column where it fits, shrunk to fit where it nearly does, and a horizontal
      strip of icon-only tiles under the HUD where it does not. Computed, not switched on
      `TouchEnabled`, so a tablet keeps the column it has room for. It is a pure function
      precisely so it can be checked against a table of device sizes without a device.
      Two bugs it found. `_plan` sized a column to fit a window and `_arrange` then centred
      it on the whole viewport, pushing it straight back out of the bottom on both iPads.
      And the HUD scaled off the camera while the bar scaled off its own GUI space — 1.04
      against 0.96 — so `UI.ScaleWithViewport` now measures the ScreenGui, which is the
      space either of them actually has.
      Verified: every device from a 320px phone to a 1440p monitor clears both the HUD
      block and the reserved zones, the smallest tile is 48px against a 44px floor, and
      the strip fits the narrowest landscape phone. Drawing the icons at their real 38px
      also showed the Settings handles were taller than the gap between its rails and
      merged into a block; they are shorter now.

## Phase 14 — Five stats, five jobs

`CLAUDE.md` names what each muscle does. The code did something else for four of the
five, and **Back did nothing at all** — you could train it to a trillion and no number
in the game changed. Chest and Core were wired to each other's jobs, Arms shared its
one job with Chest, and Legs only affected running.

- [x] 86. **One job per stat.** `AttackDamage` takes Arms alone and `MaxHealth` takes
      Chest, with `CombatService`'s two call sites following. Arms' weight rose 6 → 9 to
      absorb exactly what Chest had been adding, so an evenly-trained player deals what
      they always did — 35 at 1e3, 116 at 1e12 — and time-to-kill is untouched. This is a
      reassignment, not a rebalance, and there are now two self-test checks that say so by
      name rather than leaving it to be believed.
      **The safety net was not plugged in.** `Formulas.RunSelfTest` holds the invariants
      that keep PvP playable at trillion-stat scale — a maxed player cannot one-shot a
      beginner, time-to-kill does not drift as the server ages — and nothing called it.
      `Bootstrap` ran `NumberFormat`'s and not this one. Balance is the one thing here
      that breaks quietly: a retuned weight still compiles, still type-checks, still
      lints. So `scripts/selftest.luau` now runs both suites under the `luau` CLI in
      milliseconds, `check.sh` runs it before every commit, and Bootstrap runs it too for
      a build that reached Studio anyway. Verified by deliberately breaking a weight and
      watching four checks fail.
- [x] 87. **Back finally does something.** `Formulas.DamageResistance`, applied in
      `ApplyDamage` between the falloff and the hit. **Contested against the attacker's
      Arms**, and that choice is the design: a flat reduction read off your own Back would
      stack on the power-gap falloff and make veteran fights drag, and it would tax every
      attacker regardless of what they trained. Contested, two players who invested equally
      cancel out *exactly* — a fair fight is identical to one where Back does not exist,
      and time-to-kill is untouched at every scale. What it buys is an answer to somebody
      who out-levelled you on Arms alone: −8% per 10× of Back over their Arms, capped at
      half, because a stat that could reach immunity is not a stat. The self-test now
      asserts equal investment cancels, and that resistance and falloff together still
      leave a hit that lands.
- [x] 88. **Core hits back.** `Formulas.Retaliation` sends a share of every landed hit
      back at whoever threw it — a fraction of the incoming damage rather than a flat
      number, so a heavy hitter takes more back than a light one and Core can never punish
      somebody for a scratch. Capped at 35%, which costs an evenly matched attacker about
      a third of their own health to win a duel: expensive, survivable, not an inversion.
      **Routed back through `ApplyDamage` itself**, so safe zones, immortality and the
      power-gap falloff all apply to it without being written a second time — and because
      the arguments go the other way round, a retaliation kill is credited to the player
      who was being attacked. Two guards it needs: none on the blow that kills, since a
      dead player does not hit back, and an `isRetaliation` flag so two players with Core
      do not bounce one punch between them until somebody falls over.
- [x] 89. **Legs flies.** `CLAUDE.md` gives Legs "speed in running and flying" and only
      the running half was ever built — everyone flew at a flat 220 whatever they had
      trained, so Legs stopped mattering at exactly the point the map starts being
      vertical. `Formulas.FlightSpeed` fixes that, and climbing became a *ratio* of level
      flight rather than its own flat number so it follows Legs too instead of becoming
      the slow part of flying for a maxed player. Read every frame, not cached on takeoff,
      so a rep landed mid-flight shows up at once.
      The split is deliberate and now says so in `MovementConfig`: **total power decides
      whether you fly, Legs decides how fast.** The gate is matched to how high the
      districts float and belongs to the map; the speed is a stat and belongs to the
      player. The floor sits above `WalkSpeed`'s ceiling, so taking off is an upgrade even
      on zero Legs — asserted, because a rung of the ladder that is slower than the one
      below it is worse than not having it.
- [x] 90. **Tell the player what a muscle does.** Nothing in the game said what a stat was
      *for* — the HUD showed five numbers and no meaning, and Back could be trained for an
      hour before you noticed it changed nothing. Each stat now carries an `Effect` on its
      own definition: a function from your stats to a short line — "116 damage a hit", "580
      max health", "35% of hits sent back". A function on the definition rather than a
      switch downstream, so a sixth stat arrives carrying its own explanation and nothing
      branches on a stat id.
      Shown in the Upgrades tab, so the number you are buying a multiplier on is visible
      before you buy it, and on the training machines, so a player at the pull-up bar
      learns what Back is for while standing at it. Back quotes its *ceiling* and says
      "up to", because a contested reduction has no single number — and reads "no damage
      reduction yet" at zero rather than "-0%".
      The old blurbs were also wrong in the world: Core still promised "your max health
      and stamina pool" when stamina was withdrawn in #22 and health had never been its
      job, and Back said "broadens the frame", which was only accurate because it did
      nothing else.

## Phase 15 — Training belongs to places

The district pass made eleven memorable destinations, but the training inside each one
still exposed the generator: the same five machines sat in a perfect ring or two neat
rows at every power tier. From above, each district read as one compact level rather than
part of an open world with things to discover.

- [x] 91. **Stat venues, scattered through the world.** Every district still supplies all
      five core stats so progression cannot strand a build, but they no longer share one
      obvious gym cluster. A seeded `scatter` layout gives each district a stable irregular
      arrangement: rebuilds reproduce it exactly, while loose angular sectors prevent five
      random rolls from piling onto one edge. Garage Gym uses a tighter outside band so its
      venues remain beyond the safe plaza and PvP still reaches every trainee.
      Each machine now owns a piece of architecture that advertises its purpose before its
      UI label is readable: an open-front **Chest bay**, steel **Arms cage**, tall **Back
      tower**, low **Core court**, or marked **Legs lane**. Stat colours provide wayfinding;
      a smaller district-colour beacon still communicates the progression tier. Venue
      geometry lives in a `TrainingAreas` folder beside the machine folder, keeping the
      `TrainingStation` model contract unchanged and preserving streaming, prompts, held
      props, zone gain multipliers, and travel gates. Garage's floor bays now derive from
      the actual generated positions instead of a second layout formula, so decoration and
      machines cannot drift apart.

## Phase 16 — One world, fifty-five destinations

#91 scattered machines *inside* the old progression islands. It solved the repeated
five-point ring but kept the deeper problem: the world was still eleven isolated level
plates, rising into the sky, and the Map button travelled to a tier rather than to the
body part the player meant to train.

- [x] 92. **A connected city with every machine on the map.** The floating archipelago is
      replaced by one 2,670×1,290-stud ground-level city plate. A complete road grid links
      all 55 blocks at the same playable Y, with a seawall and foundation making it read as
      one place rather than a baseplate. Each block hides exactly one machine inside one of
      five street contexts — warehouse, alley, construction yard, underpass, or bunker —
      and keeps the stat-specific Chest bay, Arms cage, Back tower, Core court, or Legs lane
      inside. Two ordinary buildings disguise most entrances as part of the street instead
      of announcing another freestanding gym.
      Tier/stat pairs are seeded and shuffled across the whole grid: every stat still has
      eleven multiplier levels, but adjacent doors can lead to unrelated stats and tiers.
      Small private `GymZone` volumes replace district-wide volumes, preserving gain math,
      token eligibility and mount gates without recreating level neighborhoods invisibly.
      Every station now carries a unique `TravelId`. `TravelService` publishes all 55
      destinations with stat, equipment, tier, requirement, multiplier and server-known
      coordinates, then lands beside the exact selected machine's `TrainExit`. The Map tab
      renders all 55 immediately, colours pins by stat, dims rather than hides locked spots,
      and shows the selected machine and tier before travel. Verified live: 55 unique ids,
      11 destinations per stat, five per tier, 55 rendered pins, and a client travel request
      landed within one stud of the chosen Arms machine.

## Phase 17 — A city worth learning

The connected grid fixed progression, but it was still a diagram: plain blocks, an empty
map background, and no reason to remember one street from another. The starter machines
were also far enough apart to feel like five unrelated destinations.

- [x] 93. **The old islands become city landmarks, interiors, and a faithful map.** Ten
      flat neighborhoods now reuse the old archipelago's visual language — docks and
      cranes, beach and palms, quarry machinery, rooftops, storm pylons, void monoliths,
      solar foundries, nebula hardware, and the marble civic district — while their 50
      non-starter tier/stat pairs remain independently shuffled. Scenery therefore gives
      directions without exposing progression. A collision keep-out keeps every landmark
      and entrance readable instead of dropping old island props through a hidden gym.
      The five x1 body-part venues now share one paved starter campus around spawn. A
      visible cyan ForceField perimeter shows the smaller functional safe zone while the
      machines remain outside it, preserving PvP interruption during training.
      Seven destinations are concealed on the third floor of original, primitive-built
      enterable buildings. Each has a real doorway, two connected stair flights and
      landings, a closed upper facade, floor metadata, and an atomic streaming model so
      fast travel cannot arrive before its support floor. All seven entrance-to-machine
      paths succeed.
      The Map tab is now a vector plan generated from the actual tagged land, roads,
      blocks, parks, plaza, safe zone and 121 building footprints, with a stat legend and
      all 55 exact-location pins. It preserves the world's aspect ratio and supports
      mouse-wheel/buttons for 1–4x zoom plus touch/drag panning and recentering; selection
      refreshes retain the current view. Verified live: 196 background features and 55
      pins render, zoom expands the 616×300 canvas to 770×375 at 1.25x, every station has
      floor support and its matching private zone, all seven interiors pathfind, and
      Garage Dumbbells travel lands exactly on its `TrainExit`.

## Phase 18 — A world that does not reveal its formula

The city map finally showed every destination, but fifty of them still occupied an
11×5 square grid and every tier repeated the same five exercises. Once a player saw one
block, both the next location and the machine waiting there were easy to predict.

- [x] 94. **Irregular districts, reachable sky gyms, and three exercises per muscle.**
      The single rectangular city plate is replaced by ten differently sized and rotated
      coastal neighborhoods around the starter campus. Thirty-six overlapping land
      footprints and thirteen angled road/causeway links keep the whole ground map
      walkable while giving it bays, peninsulas, a harbor, beach, quarry, high-rise core,
      foundry, storm works, neon market, observatory, and void-rail silhouette. The old
      themed props live in those environments, filtered around every training footprint.
      Fifty non-starter tier/stat pairs are reproducibly shuffled into neighborhoods with
      unequal site counts; every tier spans at least four neighborhoods, every stat spans
      at least seven, adjacent sites remain 119+ studs apart, and progression cannot be
      read from the scenery. This is generated randomness rather than per-server churn, so
      players can still learn the locations shown on the map.
      Ten Strongman-or-higher destinations now sit on original primitive-built crane decks
      110–194 studs above their streets. Flight already unlocks below Strongman's power
      gate, and each atomic sky environment includes a wide landing surface, open approach,
      rails, tether mast, and lower recovery scaffold. Five other secrets remain inside
      pathfindable third-floor buildings; the remaining forty are street-level.
      Chest, Arms, Back, Core, and Legs each rotate through three real exercise families:
      flat/incline/fly presses; dumbbell/barbell/pushdown arm work; pull-up/row/pulldown back
      work; sit-up/knee-raise/twist core work; and treadmill/squat/leg-press leg work. All
      fifteen machines are original part geometry, all fifteen poses are procedural joint
      motion capped at 145 degrees, and gain-per-second stays within 10.90–11.44 so a random
      variant never changes progression. The server publishes environment, family, variant,
      sky-access, and flight metadata; the vector map draws water and sky platforms and
      labels sky pins as flight-required.
      `validate_gym.py` now guards determinism, committed JSON freshness, the 55-location /
      15-variant balance, machine contracts, sky gating, irregularity, geometry, and instance
      budgets on every `check.sh` run. Verified in Studio: all 55 stations bind one prompt,
      all five interior routes succeed, every exit has support exactly three studs below,
      the client receives 157 faithful map features, locked sky travel is refused, starter
      travel lands at zero error, and every one of the fifteen poses visibly changes a joint.

- [x] 95. **Flight from the first spawn.** Flight permission no longer waits for a
      power milestone: `MovementConfig.FLIGHT_POWER` is `0`, so the server publishes
      `FlightAllowed = true` as soon as a player is alive. Q still toggles flight, WASD
      steers, Space climbs, and Left Shift descends; Legs still controls speed, while
      training and the short post-hit combat lock still ground the player. Verified in
      Studio with a fresh mock player: the attribute was true before earning any stats,
      Q created `FlightVelocity` and platform stand, and Q again returned control to the
      Humanoid.

---

# Roadmap — From Playable Prototype to Viral-Ready Live Game

No checklist can guarantee virality. Virality is an outcome of players getting value
quickly, returning, deliberately playing with friends, and recommending an experience
whose store page tells the truth. This roadmap is designed to maximize those conditions
and Roblox's current recommendation signals without sacrificing fairness or safety.

The product loop this roadmap optimizes is:

> **accurate promise → first delight → meaningful goal → social story → return → share → repeat**

## Audit of the current product

| Area | What is genuinely present | Largest gap before growth |
|---|---|---|
| Core fantasy | 55 locations, 15 exercises, muscle growth, five meaningful stats, flight, PvP, reputation | A new player is not taught or directed through the fantasy |
| World | Irregular connected city, interiors, sky gyms, vector map, streaming-aware travel | The full map is information overload and low-population servers disperse encounters |
| Progression | ranks, tokens, multipliers, two daily quests, one one-shot quest | no balanced first-hour path, mastery, weekly goals, comeback loop, or post-endgame purpose |
| Combat | authoritative Punch, damage, kills, bounties, safe zones; interruption settled as kill-only (#96) | only one ability — Slam/Dash deferred to #122; paid-peace fairness still open (Phase 26) |
| Social | roster, kill feed, global Power/Kills boards | no parties, friend co-training, invites, rivals, crews, co-op events, or shareable moments |
| Monetization | receipt architecture and four configured product definitions | every id is `0`; paid peace can still permit aggression; no live receipt evidence or cosmetic catalog |
| Analytics | partial onboarding and economy logging | declared FirstMultiplier/FirstPurchase steps are not wired; no social, tutorial, interruption, source, or experiment telemetry |
| Platform reach | responsive menu-bar work and StreamingEnabled | flight is keyboard-only, major panels are fixed-size, controller/accessibility/localization/device QA are incomplete |
| Operations | deterministic world generator, validator, lint/type/build checks | no live-ops scheduler, feature flags, content calendar, staged rollout, rollback rehearsal, or current playtest document |

## Growth scorecard and decision rules

Roblox's Home recommendations currently evaluate per-user signals including **qualified
play-through rate (qPTR), 7-day playtime, 7-day play days, 7-day spend days, 7-day Robux
spent, and 7-day intentional co-play days**. We optimize them together; revenue never
overrules player safety, truthful merchandising, or retention.

These are **starting internal gates, not Roblox promises or universal industry facts**.
Replace them with the live Creator Dashboard's similar-experience benchmarks once enough
traffic exists:

| Funnel | Initial internal gate before scaling acquisition |
|---|---|
| First delight | p50 join→first rep ≤30s; onboarding completion ≥75%; 5-minute survival ≥65%; 10-minute survival ≥45% |
| Retention | D1/D7/D30 at or above the similar-experience benchmark; working stretch targets 20% / 8% / 3% |
| Engagement | median session ≥15 minutes; ≥3 distinct activity types per healthy session; 7-day play days/user ≥2 |
| Social | intentional friend play in ≥20% of sessions; invite acceptance ≥8%; 7-day intentional co-play days/user ≥0.35 and rising toward benchmark |
| Discovery | qPTR at or above benchmark with honest, meaningfully different creatives; judge each source by downstream D7, not clicks alone |
| Monetization | 100% idempotent grants; no statistically meaningful D1/D7 or non-payer/PvP-victim regression after a store change |
| Reliability | crash-free sessions ≥99.5%; OOM exits <0.1%; p95 join→interactive ≤10s; p50 ≥55 FPS on the chosen low-end mobile tier; healthy server heartbeat at capacity |

Execution rules:

1. Finish P0 truth, telemetry, onboarding, fairness, mobile, data, and performance gates
   before public acquisition.
2. Every experiment has one hypothesis, one primary metric, guardrails, a deterministic
   cohort, a minimum observation window, and a keep/revert decision.
3. Compare new-player, returning-player, payer/non-payer, solo/social, platform, locale,
   and PvP-victim cohorts. An average must not conceal a harmed group.
4. Do not buy traffic to diagnose a product problem. Paid acquisition starts only after
   retention and session quality meet the live peer benchmark.
5. Each implementation item below lands as one reviewable commit after its automated and
   human acceptance evidence is recorded. This roadmap edit itself is documentation only.

## Phase 19 — P0: Make the roadmap true and measurable

- [x] 96. **Reconcile product truth.** Audit `AGENTS.md`, `CLAUDE.md`, this checklist,
      `README.md`, `docs/PLAYTEST.md`, and the live build as one versioned inventory.
      Decide hit-vs-kill training interruption; either deliver or explicitly defer Slam
      and Dash; correct board/system/count/control claims; rewrite playtests for 55 stations,
      15 variants, current flight, and current map. No checked claim may lack code or test
      evidence.
      *Done: `docs/PRODUCT_TRUTH.md` v1 is the versioned inventory. Interruption is
      kill-only; Slam/Dash explicitly deferred; PLAYTEST rewritten for 55 stations, 15
      variants, 11 zones, current flight and travel.*
- [x] 97. **Own one KPI scorecard.** Add a concise product brief and dashboard definition
      for qPTR, qualified plays by source, join→first rep/upgrade/flight, onboarding,
      session length, 5/10-minute survival, D1/D7/D30, activity variety, intentional
      co-play, invite conversion, payer metrics, PvP-victim churn, saves, receipts, crashes,
      OOMs, FPS, and server heartbeat. Assign an owner and review cadence to every metric.
      *Done: `docs/KPI_SCORECARD.md` v1 — product brief, six owner roles, four cadences,
      the internal gates, and every metric tagged WIRED / PARTIAL / NOT WIRED. Most are
      NOT WIRED today; #98 is what closes that, and a NOT WIRED metric may not be cited.*
- [ ] 98. **Analytics contract v2.** Version a server-validated event schema and wire the
      missing FirstMultiplier and FirstPurchase steps plus moved, prompt seen, training
      started/ended, map opened, first flight, first travel, zone/rank unlock, interruption,
      death/kill, quest completion, item viewed, purchase prompt/result/grant, session end,
      device/input, locale, acquisition source, and friend/co-play context. Add funnel,
      custom, and economy self-tests; telemetry failure can never stop gameplay.
- [ ] 99. **Feature flags and honest experiments.** Add persistent deterministic cohorts,
      typed remote configuration, safe defaults, per-feature kill switches, exposure
      logging, and a Studio override. Flags may select config/UX, never trust client
      rewards, and never change saved shape without a migration and rollback path.
- [ ] 100. **Progression and economy simulator.** Build a headless deterministic model
      from fresh spawn through every district and beyond Ascendant for active, casual,
      social, boosted, frequently-killed, and returning play styles. Gate balance changes
      on documented time-to-first-upgrade/rank/zone, sources/sinks, stall points, inflation,
      and sensitivity ranges instead of intuition.
- [ ] 101. **Finite-number and hostile-input safety.** Define behavior above the current
      suffix range; cap or safely display every stat, multiplier, damage, and datastore
      value; fuzz formulas and runtime remote schemas with NaN/Inf/oversized/malformed
      inputs; rate-limit endpoints; and record impossible gains without immediately
      auto-banning. A hostile client must not grant value, corrupt replication, or crash a
      server.
- [ ] 102. **Baseline before feature work.** Run instrumented human alpha sessions on
      keyboard, touch, and gamepad; capture first-rep/upgrade timing, confusion, deaths,
      session exits, frame/memory/network traces, and qualitative notes. Freeze the first
      beta targets from evidence and record the baseline commit/build so every later claim
      has a comparison.
- [ ] 103. **Deterministic service readiness.** Replace concurrently spawned, best-effort
      startup with explicit dependencies/readiness and critical-vs-optional health. Joiners
      present before or during boot cannot miss profile, entitlement, quest, analytics, or
      replication setup; a critical failure fails the build/server visibly instead of
      leaving a half-alive game. Prove 100 boot/join cycles initialize every service once.
- [ ] 104. **Durable profile boundary.** Add an in-flight load guard, environment-specific
      dev/stage/prod store names, schema/version checks, finite/range sanitization, historical
      migration fixtures, corruption repair, and a typed allowlisted client DTO that never
      exposes receipt ids. Order persistent stat/cash/quest/reward mutations transactionally
      enough that disconnecting after any step produces all-or-none durable results.
- [ ] 105. **Commit receipts before acknowledgement.** Replace in-memory-only receipt
      acknowledgement with a durable idempotent receipt journal/commit-before-ack design,
      keep tombstone handlers for retired products, fail startup on duplicate ids, and alert
      on pending/unknown receipts. Fault-inject before/after grant, journal, save, and ack:
      ownership lands exactly once and a paid receipt is never acknowledged without a
      durable grant. A shop kill switch must never stop fulfillment of an existing receipt.
- [ ] 106. **Authorize movement and travel.** Validate every movement/combat/travel payload,
      issue narrow server teleport authority, enforce speed/position envelopes that respect
      maximum Legs flight and network latency, and revalidate travel after every streaming
      yield. A hit, death, respawn, exploit teleport, or stale character cannot escape combat,
      enter locked training, or bypass Fast Travel; legitimate maximum-speed flight at the
      supported latency has no false positives.
- [ ] 107. **Hermetic CI and Studio contracts.** Pin/checksum tool definitions and make a
      clean clone install dependencies, lint/typecheck, run self-tests, validate generated
      JSON/config/migrations, and `rojo build` reproducibly. Add automated Studio contracts
      for all 55/15 world entries, every remote failure path, profile load/save, receipts,
      training/travel, and a two-client PvP scenario; no launch claim depends only on a
      manual memory.
- [ ] 108. **Scale the existing runtime before adding systems.** Cache immutable map and
      entitlement data, replace per-second full-roster/profile broadcasts with versioned
      deltas/coalescing, batch leaderboard/name work, and clean character/streaming caches on
      respawn/removal. Ratchet world budgets near the measured build rather than the old
      3× allowance. At target capacity, meet script/network/memory budgets with no per-frame
      descendant scans, stale rig leaks, or repeated static Workspace scans.

## Phase 20 — P0: Win the first ten minutes

- [ ] 109. **Saved Coach onboarding.** Add a resumable, skippable, one-objective-at-a-time
      path: move/look → train ten reps → try a second muscle → buy the first multiplier →
      fly through a marker → open/select the map → practice combat on a dummy. Store only
      durable step completion; repeat visits never replay forced panels.
- [ ] 110. **Config-driven guidance.** Add a reusable objective ribbon, world waypoint,
      distance indicator, highlight, and contextual control hint driven by station/map/
      quest config rather than hardcoded paths. It must recover after death, streaming,
      travel, control-scheme changes, and a destroyed target without trapping progress.
- [ ] 111. **First permanent choice in five minutes.** Fund one guaranteed onboarding
      multiplier through an earned one-time reward, preview how each of the five stats
      changes gameplay before the choice, confirm the chosen benefit immediately, and log
      time, choice distribution, hesitation, and abandonment. No Robux prompt appears first.
- [ ] 112. **New-player peace shield.** During onboarding or a short non-repeatable grace
      window, visibly block both incoming **and outgoing** PvP; end it when the player
      explicitly opts into combat or the window expires. It cannot accrue bounties,
      competitive rewards, or protected attack positioning and does not become a permanent
      free PvP opt-out.
- [ ] 113. **Sparring dummy and safe failure.** Add an original server-authoritative target
      that teaches range, Punch, cooldown, damage roles, knockback, and recovery without
      requiring another player or affecting reputation. It works in an empty server and
      gives no farmable economy after its tutorial reward.
- [ ] 114. **Progressive map disclosure without hiding content.** Keep the selected user
      promise that all 55 locations are visible, but default the first-session view to
      starter/nearby/recommended filters, a clear “Show all” control, search/filter by
      muscle/access/environment, and one highlighted next destination. Preserve zoom,
      pan, selection, and accessibility across refreshes.
- [ ] 115. **First-session payoff and return hook.** Celebrate the completed fantasy—first
      visible growth, stronger movement/combat, flight, discovery—with restrained original
      audiovisual feedback, then let the player choose a next-stat/district goal for the
      next session. Human-test the entire route on keyboard, phone, tablet, and controller
      until the first-delight and onboarding gates hold.

## Phase 21 — P1: Make every minute feel good

- [ ] 116. **Original soundscape.** Replace blank sound ids with owned original music,
      ambience, machine loops, reps, UI, flight, impacts, city layers, and district cues;
      keep source/provenance records and loudness standards. Music/SFX settings, distance
      rolloff, concurrency limits, interruption cleanup, and a silent fallback all work.
- [ ] 117. **Lock the game's risk rule.** Decide with two-player evidence whether any valid
      hit or only a knockout dismounts training, then make server behavior, stagger/combat
      lock, HUD, tutorials, analytics, docs, and balance agree. Measure attacker delight
      against victim early-exit/D1 harm and retain the smallest interruption that makes the
      hook legible.
- [ ] 118. **Three real combat choices.** Complete the registry with a reliable light
      attack, a mobility/escape move, and an area/commitment move (Punch, Dash, Slam or
      better tested equivalents). Each has server validation, readable cost/cooldown,
      anticipation/recovery, counterplay, touch/gamepad bindings, and automated hit/range/
      rate-limit tests.
- [ ] 119. **Combat feel and accessibility pass.** Add readable anticipation, contact,
      recovery, hit reaction, knockout/ragdoll, finisher restraint, camera/audio feedback,
      and settings for shake, flash, damage numbers, and high-contrast cues. Validate the
      same authoritative result under latency and never rely on color or sound alone.
- [ ] 120. **Milestones that punctuate the grind.** Author short sequences for rank, zone,
      multiplier, stat-shape, exercise-mastery, and reputation thresholds: preview, moment,
      reward, next goal. Server announcements are nearby/relevant, rate-limited, opt-out,
      and never cover controls or pressure a purchase.
- [ ] 121. **Population-concentrating hotspot.** Rotate a disclosed “Hot Gym” or city
      incident that gives modest earned rewards and funnels willing players toward one
      location, with beginner and empty-server alternatives. Measure activity variety,
      co-presence, PvP, interruption, and victim exits before making it permanent.

## Phase 22 — P0: Mobile, controller, accessibility, and performance

- [ ] 122. **Complete touch/gamepad flight.** Add discoverable toggle, ascend, descend,
      steering state, altitude feedback, and control hints for touch and gamepad. Reserve
      safe screen areas so flight never overlaps jump, Punch, camera drag, thumbstick,
      menu, or Roblox controls; test respawn, training, combat lock, and input switching.
- [ ] 123. **Responsive main menu.** Replace the fixed 640×500 body and fixed six-tab row
      with breakpoint/content-driven layout for small phones, tablets, desktop, notches,
      landscape changes, translated text expansion, and 44px+ targets. No tab, purchase
      detail, map control, or close action can render off-screen.
- [ ] 124. **Responsive roster.** Close it by default on small touch screens, provide a
      visible on-screen toggle/dismiss control, reflow or paginate 300×462 content, and
      preserve keyboard Tab behavior. Long names, ten-plus players, safe insets, menu,
      chat, and mobile controls do not overlap.
- [ ] 125. **One HUD safe-area planner.** Centralize placement/reservation for thumbstick,
      jump, combat, flight, menu bar, vitals, objectives, toasts, map, roster, and Roblox
      core UI. Validate representative phone/tablet/desktop/console fixtures and dynamic
      resize/orientation rather than adding controller-specific pixel offsets.
- [ ] 126. **Full controller path.** Implement deliberate selection order, focus state,
      back behavior, scrolling, map zoom/pan, purchases, remappable/action-aware help, and
      glyph switching. A controller-only player completes onboarding, trains, flies,
      fights, upgrades, shops, parties, and exits every modal without a mouse.
- [ ] 127. **Persisted accessibility/settings.** Add music, SFX, reduced motion, screen
      flash/shake, damage numbers, kill feed, text/UI scale, high contrast, color cues,
      camera sensitivity, and control help with migration-safe defaults and immediate
      preview. Critical information always has text/shape as well as color/audio.
- [ ] 128. **Localization-ready product.** Move every player-facing dynamic/static string
      to keys, preserve names/numbers/placeholders safely, pseudo-localize long strings,
      enable automatic capture/translation, and manually review the top live locales.
      Critical onboarding, map, quest, control, safety, and purchase copy reaches 100%
      coverage before global acquisition.
- [ ] 129. **Device and capacity budget.** Set part/physics/network/UI/script/memory/load
      budgets, profile low-end phone/tablet/console/desktop, and soak at target server
      capacity with streaming, 55 stations, flight, combat, effects, leaderboards, and
      events active. Track p50/p95 by device; fix regressions before increasing content.

## Phase 23 — P1: Retention without coercion

- [ ] 130. **Persistent goal service.** Provide claim-free, auto-awarded short/mid/long
      goals across rank, zones, every stat, exercises, quests, combat, reputation, social
      play, and exploration. The HUD shows one chosen goal while the menu shows the full
      tree; requirements/rewards are data-driven and migration-safe.
- [ ] 131. **Daily and weekly contract catalog.** Expand beyond two dailies to balanced
      rotations covering training, varied exercises, exploration, reputation, PvP, races,
      and co-op; add fair rerolls and population-aware fallbacks so an empty or protected
      server never makes completion impossible. Simulate reward inflation before launch.
- [ ] 132. **Forgiving return calendar.** Add a seven-day/flexible reward path with grace
      days and catch-up; missing a day never deletes accumulated progress or creates a
      purchase emergency. Rewards teach underused activities and remain modest beside
      active play.
- [ ] 133. **Exercise and district mastery.** Track all 15 variants, five families, ten
      neighborhoods, interiors, and sky gyms in a discoverable collection/logbook with
      original cosmetic/title rewards and meaningful milestones. Mastery adds identity
      and route choice, not a hidden power reset.
- [ ] 134. **Badges and achievements.** Add idempotent platform badges plus in-game
      achievements for meaningful firsts, social feats, mastery, exploration, reputation,
      fair PvP, and long-term goals. Never award or announce a badge from a client claim.
- [ ] 135. **Respectful comeback path.** Give lapsed players a personalized recap, chosen
      catch-up goals, and a capped temporary earned boost based on absence. It helps them
      re-enter current content without leapfrogging active players or inventing false
      urgency.
- [ ] 136. **Actionable opt-in notifications.** After platform eligibility, request
      permission at a relevant success moment and send at most policy/throttle-safe,
      personalized events such as a nearly completed weekly, crew challenge, or beaten
      record with useful launch data. Never gate progress, send generic ads, or pressure a
      purchase; monitor CTR, dismiss, and opt-out.
- [ ] 137. **Retention/farming review.** Cohort-test D1/D7 loops, activity diversity,
      progression stalls, AFK incentives, multi-account/kill trading, quest failure, and
      reward inflation. Remove mechanics that inflate minutes while players are not having
      fun or that make victimization the dominant new-player memory.

## Phase 24 — P1: Social and genuinely shareable play

- [ ] 138. **Parties.** Add server-authoritative party membership, invites, accept/decline,
      shared waypoint, same-server routing, reconnect/respawn handling, privacy controls,
      and clean leadership/leave rules. Parties coordinate friends but never bypass zone,
      equipment, reward, combat, or travel requirements.
- [ ] 139. **Active friend co-training.** Add a capped spotter bonus and paired/co-op
      machine or flight/race challenges that require both players to participate. Use
      relationship/session/daily caps and contribution checks against alts; log whether
      social cohorts retain better than solo cohorts.
- [ ] 140. **Opt-in rival contracts.** Turn revenge into a clear challenge/rematch loop
      with consent, expiration, balanced stakes, anti-repeat farming, block/privacy limits,
      safe-zone behavior, and a non-PvP decline path. Never reveal precise private location
      outside the mutually accepted activity.
- [ ] 141. **Server-wide cooperative events.** Add scalable city threats/community goals
      where each of the five stats has a role, beginners can make real contributions, low
      populations receive adaptive objectives, and rewards use contribution bands rather
      than last-hit ownership.
- [ ] 142. **Contextual Roblox invites.** Check eligibility and prompt only at genuine
      moments—forming a party, starting a duo event, first transformation—not on join.
      Route the recipient through launch data into the same activity; any reward is granted
      once only after the invitee completes meaningful onboarding, with relationship and
      daily anti-abuse caps.
- [ ] 143. **Earned identity.** Add original titles, nameplates, auras, trails, procedural
      poses/emotes/finishers, and a saved loadout visible in the world, roster, profile,
      party, and showcase. Separate earnable and purchasable variants clearly and keep
      gameplay hitboxes/readability unchanged.
- [ ] 144. **Capture-worthy moments.** Build optional photo/showcase spots and clean
      milestone compositions for transformations, sky gyms, crew flights, rival wins, and
      world events; support hiding UI and restoring it safely. Never auto-post, require
      external sharing, or pay for unverifiable off-platform actions.
- [ ] 145. **Demand gate for clans, gifting, and trading.** Measure party reuse, co-play,
      identity ownership, support load, fraud risk, and player interviews before scoping
      these systems. Do not ship trading at launch; duplication, scams, moderation, and
      economy damage outweigh an unproven social benefit.

## Phase 25 — P2: Endgame and a live world

- [ ] 146. **Horizontal endgame mastery.** Extend beyond Ascendant/Godlike with permanent
      mastery branches, collections, difficult routes, titles, cosmetic evolution, and
      build expression. Preserve the locked no-rebirth promise: never erase or reset
      trained stats merely to restart the same grind.
- [ ] 147. **Fair seasonal PvP.** Add rating, divisions, placement, decay, matchmaking/
      population fallback, anti-collusion, and cosmetic seasonal rewards; reset only
      seasonal rating/rewards, never permanent stats. Prefer normalized event rules so
      spending or old power alone cannot decide competitive rank.
- [ ] 148. **World bosses and city threats.** Create scalable encounters with readable
      phases, contributions for Arms/Chest/Back/Core/Legs, solo/low-pop fallback, death
      recovery, anti-AFK contribution, and cosmetic/mastery drops. Use the existing world
      generator/content registries rather than one-off service branches.
- [ ] 149. **Reputation becomes gameplay.** Add Hero and Criminal contract tracks,
      asymmetric public objectives, counterplay, safe alternatives, and rewards/risks that
      make the title matter without trapping Neutral players. Repeated victim farming,
      party collusion, and protected targets cannot advance it.
- [ ] 150. **Fresh leaderboards.** Add weekly/seasonal, friend, mastery, event, and fair-PvP
      boards alongside lifetime Power/Kills; use bounded stores, reset/version strategy,
      tied-score rules, cached failure behavior, and cosmetic—not runaway power—rewards.
- [ ] 151. **Population-aware event rotation.** Select hotspots, races, bosses, co-op, and
      rivalry events from typed configs using server population, player progression, recent
      history, and overlap priority, with empty-server fallbacks and cross-server messaging
      only where it materially improves play.
- [ ] 152. **Endgame command center.** Give advanced players one clear screen for mastery,
      collections, season, reputation, community objectives, records, and next rewards so
      “make the number larger” is never the only visible purpose.

## Phase 26 — P1: Ethical monetization that does not poison PvP

- [ ] 153. **Immortality becomes peace mode.** While active, the player can neither deal
      nor receive player damage, earn PvP/bounty/reputation rewards, nor body-block fights;
      show an unmistakable barrier and exact expiry/stacking behavior. Test activation,
      expiry, reconnect, training, safe zones, parties, and every ability.
- [ ] 154. **VIP fairness review.** Evaluate permanent 2× power and paid-only long-term
      protection against payer/non-payer and attacker/victim retention. Prefer durable
      identity/convenience or normalized competition over paid combat dominance; if a sold
      benefit changes, publish a migration, compensation, and unchanged-term plan first.
- [ ] 155. **Cosmetic-first catalog.** Build preview/equip/ownership flows for original
      auras, trails, nameplates, gym skins, procedural pose/finisher styles, profile themes,
      and loadout slots. Use several honest price points; do not add paid random rewards
      without eligibility, disclosed odds, duplicate/pity/refund design, and policy review.
- [ ] 156. **Keep progression honest.** Power gates, map information, combat outcome, and
      competitive boards cannot be silently skipped by spending. Fast Travel may sell
      convenience without bypassing requirements; no purchase modal appears during the
      first-fun path or immediately after defeat.
- [ ] 157. **Transparent regional store.** Fetch/display the user's actual localized or
      managed price, contents, permanence/duration, peace-mode limitation, stacking,
      ownership, restore state, and cancellation rules. Apply `PolicyService` eligibility,
      accessible previews, clear close/back, and no false timers, fake discounts, or
      preselected purchases.
- [ ] 158. **Live commerce proof.** Create and fill all four real ids, disable zero-id
      products in production checks, and test developer products/gamepasses on live servers:
      prompt cancel, success, retry, reconnect, duplicate receipt, unknown product, grant
      failure, concurrent session, ownership loss/refund behavior, and purchase-history
      growth. Grants are idempotent and auditable.
- [ ] 159. **Monetization guardrails.** Track view→detail→prompt→accept→receipt→grant and
      post-purchase value/retention by product, platform, locale, cohort, payer status, and
      PvP exposure. Keep/price tests require healthy non-payer and victim retention, not
      revenue alone; consider a subscription only after repeatable monthly value exists.

## Phase 27 — P2: Live operations, discovery, and staged launch

- [ ] 160. **Versioned live-ops framework.** Add typed `LiveOpsConfig`/scheduler with UTC
      windows, deterministic overlap priority, reward version, safe default-off behavior,
      per-event kill switch, exposure/event analytics, server refresh strategy, and Studio
      preview. A malformed/expired config cannot affect normal progression.
- [ ] 161. **Content factory.** Add templates, schema validators, balance preview, geometry/
      path/streaming validation, and freshness tests for quests, events, rewards, cosmetics,
      zones, machines, environments, and poses. Preserve original primitive/procedural asset
      rules and instance/performance budgets so a small update is routine rather than risky.
- [ ] 162. **Rollback and disaster rehearsal.** Version event/content/save changes, back up
      production configuration, document ownership/escalation, and rehearse disabling a
      broken event, rolling back code/config, repairing affected profiles, and reconciling
      receipts without wiping legitimate progress.
- [ ] 163. **Twelve-week content inventory.** Before launch, prepare and test a realistic
      calendar of daily rotations, weekly/biweekly events, challenges, cosmetics, and at
      least one larger update. Ship small improvements every 2–4 weeks and major value
      only when ready; never publish a cadence the content factory cannot sustain.
- [ ] 164. **Creator campaign tools.** Add bounded promo codes/share campaigns with expiry,
      maximum claims, idempotency, source/launch attribution, and anti-alt limits; favor
      cosmetics or modest currency. Create one share link per channel/creator and judge it
      on qualified play, D7, co-play, and payer quality rather than views.
- [ ] 165. **Truthful publishing package.** Produce an original recognizable icon, several
      meaningfully different 16:9 thumbnails, a short authentic gameplay trailer, semantic
      title/description, update notes, and screenshots showing the real transformation,
      city, sky gyms, social action, and flight. Localize metadata and keep creatives only
      when qPTR **and** downstream retention improve.
- [ ] 166. **Release-candidate proof.** Replace mock storage/blank sounds/zero ids, update
      playtests, and pass real persistence, session lock, migration, commerce, two-client
      PvP, 10+/target-capacity soak, private server, empty server, streaming/cold travel,
      all 15 poses, R15 scale extremes, keyboard/touch/gamepad, locale, accessibility,
      exploit, disconnect, shutdown, and rollback tests with no unexplained errors.
- [ ] 167. **Invite-only alpha → staged public beta.** Start with observed target-audience
      sessions, then limited cohorts and gradually increased traffic. Review onboarding,
      D1/D7, social uplift, fairness/victim churn, economy, performance, saves, and support
      after each stage; stop or roll back before paid ads/large creator pushes when a gate
      misses.
- [ ] 168. **Weekly growth operating loop.** Maintain one decision log and dashboard review:
      observe → identify the largest constraint → form one hypothesis → ship the smallest
      safe experiment → wait for the required cohort window → keep/revert → document the
      next constraint. Scale acquisition only when qPTR, retention, engagement, intentional
      co-play, monetization, and reliability improve together; pivot the weak loop instead
      of manufacturing activity.

## Official Roblox evidence used for this roadmap

- [Discovery and Home recommendation signals](https://create.roblox.com/docs/production/promotion/discovery)
- [Analytics overview and similar-experience benchmarks](https://create.roblox.com/docs/production/analytics)
- [Retention and onboarding guidance](https://create.roblox.com/docs/production/analytics/retention)
- [Funnel events](https://create.roblox.com/docs/production/analytics/funnel-events) and
  [custom events](https://create.roblox.com/docs/production/analytics/custom-events)
- [Invite prompts and launch data](https://create.roblox.com/docs/production/promotion/invite-prompts)
- [Experience notifications](https://create.roblox.com/docs/production/promotion/experience-notifications)
- [Monetization safety and transparency](https://create.roblox.com/docs/production/monetization),
  [managed pricing](https://create.roblox.com/docs/production/monetization/managed-pricing),
  and [monetization analytics](https://create.roblox.com/docs/production/analytics/monetization)
- [Localization and automatic translations](https://create.roblox.com/docs/production/localization/automatic-translations)
- [Performance optimization](https://create.roblox.com/docs/performance-optimization)
- [Experience icons](https://create.roblox.com/docs/production/publishing/experience-icons) and
  [thumbnails](https://create.roblox.com/docs/production/publishing/thumbnails)

---

## Historical Milestone 1 — Vertical Slice

> **Archived reference only.** This milestone describes the original small prototype and
> is not a current launch test. Item #96 replaces its stale station, control, combat, and
> stamina assumptions before further implementation is checked off.

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
