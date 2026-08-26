# Gym Simulator — Build Checklist

Gym-training game in the vein of **Gym League**, with the key differentiator borrowed from
**Super Power Training Simulator**: PvP is live inside the gym. Players can attack each other
mid-training-set, interrupting reps to annoy them.

**Foundation status: 93 completed / 95 historical items.** #22 (stamina) and #24
(training anti-exploit) were withdrawn by design, not skipped: reps are server-driven
with no client remote to exploit.

**Current roadmap: 11 / 18 items complete (#96–#113).** The checked foundation proves a
large playable prototype; it does **not** mean the product is ready for a public launch.

**Current public-launch blockers:** `DataService` still uses the Studio mock store, the
four token-pack `AssetId`s are `0`, sound IDs are blank, and real persistence, Robux receipts,
multiplayer balance, mobile controls, and load testing are incomplete. The current
[`docs/PLAYTEST.md`](docs/PLAYTEST.md) also describes an older world and is reconciled in
#96 before it is used as release evidence.

---

## Locked Design Decisions

| Decision | Choice |
|---|---|
| Core stats | **5** — Arms, Chest, Back, Core, Legs |
| PvP zoning | **Open PvP everywhere**, except safe spawn, shop, and quest board |
| Death cost | **Time + broken combo only.** No stat or token loss |
| Progression sink | **Tokens → per-stat multiplier upgrades.** No rebirth system |
| Token accrual | Passive per-tick, **only while alive, inside a gym zone, and somewhere you can be attacked**, plus quest rewards |
| Training | **Hold E to mount.** You teleport onto the machine, lock into it, and reps tick on their own — no stamina, no clicking. Hold E again to get off |
| Assets | **Everything original.** Part-built machines, animations generated from joint angles. No Toolbox models, no uploaded animation ids |
| PvP opt-out | **Paid only** — immortal potions (19 R$ / 1h, 199 R$ / 1 day) and VIP (699 R$, 1h daily) |
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

- [x] 8. `ProfileTemplate` schema: stats, tokens, per-stat multiplier levels, owned equipment, quest cycle progress, **reputation**, **immortality expiry**, kill/death record, settings, `SchemaVersion`.
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
      planned three-move kit — no doc may imply they exist. See `docs/PRODUCT_TRUTH.md`.*
- [x] 32. **Training interrupt** — the core hook.
      *Superseded by #96: interruption is now **kill-only**. A hit damages and grounds
      the victim but leaves them mounted; only death dismounts them and resets the
      combo. The attacker must commit to a full kill, so the cost of interrupting is
      proportional to the effort of causing it.*
- [x] 33. Death & respawn — respawn timer, rep-streak reset, in-flight token tick forfeited. **No stat or token loss on death.** *(ragdoll deferred to #56 VFX)*
- [x] 34. **Reputation system** — data-driven tiers (Criminal → Neutral → Guardian → Hero). Killing peaceful trainers pushes you toward Criminal; killing Criminals pushes you toward Hero. Tier table is config, not code.
- [x] 35. **Immortality + barrier** — `CombatService` nullifies all damage while a potion is active, and the player wears a visible body barrier so attackers can see it before swinging.
- [x] 36. Bounty / killstreak system with a revenge incentive so victims get a comeback path.
- [x] 37. Safe zones — tagged parts at spawn, shop, and quest board where damage is nullified. Everywhere else, including every training station, is live.
- [x] 38. Anti-grief balance: damage falloff on large power gaps, and a cooldown blocking repeat-farming the same victim.
- [x] 39. Kill feed + on-screen combat notifications.

## Phase 6 — Economy & Monetisation

- [x] 40. ~~`CurrencyService` — cash from reps, kills, and bounties.~~ **Removed.** Cash was deleted; the economy is Tokens (time, quests, bosses) and Fight Tokens (KOs, bounties, goblins).
- [x] 41. Data-driven shop catalogue: gym-tier unlocks, supplements (timed multipliers), abilities.
- [x] 42. `MarketplaceService` handler — gamepasses + dev products, **idempotent** receipt processing.
- [x] 43. **Immortal potions** as dev products: 1 hour for 19 R$, 1 day for 199 R$ (live dashboard prices, read at runtime — see #159). Expiry stored on the profile so it survives rejoin.
- [x] 44. **VIP gamepass** at 699 R$ — grants one 1-hour immortal potion per day, with a daily-claim reset.
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
- [x] 74. **Fast Travel gamepass.** 299 R$ to travel from wherever you are standing
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

## Phase 19 — Islands worth crossing

The archipelago was walkable and unpredictable, but each island was still a mostly
empty plate: one ring of landmark props near the coast, nothing in the middle, and
machines stamped from a single seven-point pattern that every island reused.

- [x] 96. **Bigger, denser, individually-arranged islands.** Every island in
      `REGION_SPECS` grows 1.6x — 2.56x the area — which the measured foundation
      containment box (±5000 x ±4500) allows with no change to the ocean, the world
      foundation, or the ±3850/±3350 centre-sampling box. Re-scattering centres was
      deliberately avoided: the same seed yields different centres the moment the box
      moves, which would re-roll every travel coordinate in the game. The tightest pair,
      Beach↔NeonMarket, keeps a ~442-stud water lane. `region_ground`'s hard
      `lobe_diameter` cap rises 150 → 260 so coves stay proportional instead of leaving a
      rectangle with two pimples.
      `REGION_SITE_PATTERN` is gone. `region_sites` now rejection-samples each island's
      own points inside its own footprint, seeded by island id, honouring a 110-stud edge
      inset, a 220-stud minimum separation (the validator only demands 48, which is less
      than one 88-stud pavement) and a keep-out lane over the shore ramp. Doors face
      roughly inward with up to 40 degrees of jitter. Results are memoised per island id
      because the validator builds the world twice in one process and compares byte for
      byte.
      A `CLUTTER` registry beside `PROPS` adds ten small scenery kinds and a per-theme
      `CLUTTER_KITS` recipe, scattered on a jittered grid across the whole island rather
      than one coastal ring — so a new decoration is a new function plus a dict key, never
      an edit to the scatter pass. Everything passes through the existing
      `PROP_CLEARANCE` site filter and `_decorate`, so no clutter can be collided with.
      A build-time per-island part budget fails the generator rather than the validator.
      Islands go from 68–180 parts to 244–465; `Iron`/OldTown, which names no prop kit and
      was therefore **completely bare**, now picks up the fallback kit. World total 3,759 /
      7,000 BaseParts. Rebuilds are byte-identical and `check.sh` passes.

## Phase 20 — The menu the sketches asked for

The seven-tab menu put the two screens a player opens constantly — the map and their
own stats — behind the same strip as the ones they open twice a session, and the
multiplier ladder spent tokens on a single unconfirmed click of a button whose price
doubles every level.

- [x] 97. **Three tabs, promoted buttons, and a confirm before spending.** The menu is
      Info / Shop / Settings. `Map`, `Train`, `Quests` and `Ranks` stay real tabs that
      `Open()` reaches, but leave the strip via a new `OnBar`/`STRIP_TABS` split, so
      nothing lost a route in. `MenuBarController` stops hardcoding one tile and draws
      three — Menu, Map, Rank — each lighting only when its own screen is open rather
      than all lighting whenever anything is.
      `_renderInfo` replaces `_renderUpgrades` as the character sheet the game never had:
      display name, `RankConfig` rank in its rank colour, a kill breakdown built by
      iterating `ReputationConfig.List`, and the five stat rows carrying the multiplier
      ladder. A new `KillsByReputation` map on the profile records kills by the victim's
      tier id at the moment of death — a top-level key, so `Reconcile` fills it with no
      migration and no schema bump.
      `UI.Confirm` adds a modal over a real scrim button, so the ladder now names the
      multiplier it is buying and the price before anything is spent. The server remains
      the only authority on affordability.
      The Shop grows Gamepass / Potion / Token sections fed by a new `GetProductCatalogue`
      remote over `PurchaseService`'s existing registry, so a new file in `Products/`
      appears in the UI with no client edit; the four token packs are exactly that. Rows
      whose `AssetId` is still `0` render as "SOON" rather than being offered and then
      refused after the player commits.
      Eleven new procedural glyphs in `Icons.luau`, `Token` and `Rank` aliased to existing
      builders so a restyle cannot split them. The hotbar gains the sketch's slot numbers
      bound to keys 1-5 and per-stat icons; slot one is the fist, which punches on a tap
      and opens the Arms route on a hold. A landed Punch now pays `0.25` Arms through
      `StatService`, so the fist really is arm training — worth ~0.42/s against a machine's
      1/s, so fighting adds to a session without ever beating training.
      Verified in a Studio play session: 26 server and 20 client systems ignite with no
      errors, all four token packs register and warn on `AssetId 0`, the bar draws
      Menu/Map/Rank, the hotbar draws 1-5 with Arms on the fist, the Info tab renders name,
      rank and all five tier counters, the Shop renders all four sections with every Robux
      row reading SOON, all seven new glyphs draw, the confirm dialog lays out with
      non-overlapping buttons, and `AddStat(player, "Arms", 0.25)` grants exactly 0.25
      while a mistyped stat id is refused.

## Phase 21 — One button, one screen, and a click that trains

#97 put three tabs behind one Menu tile, which meant pressing Menu still showed a
strip of Info / Shop / Settings — the bar's own navigation, drawn a second time
inside the thing the bar had just opened. The five stat slots along the bottom were
the largest element in the HUD and did nothing but open a list of locations.

- [x] 98. **A button per screen, and left-click training.** The tab strip is gone
      entirely; `MenuBarController` draws five tiles — Info, Shop, Settings, Map, Rank —
      and each opens only its own panel. The panel reclaims the 38 pixels the strip
      occupied, and the lit tile is now the only thing saying where you are.
      The Train tab is gone as a destination: its muscle picker and station list render
      underneath the map, because "where do I train Back" is a question about the map.
      `_renderTrain` gained a `baseOrder` offset so the two sections cannot interleave.
      The bottom dock drops every value, name, multiplier and icon and becomes five
      numbered squares that show one thing: which muscle the left mouse button trains.
      The picked slot is painted in its own stat colour rather than the shared accent,
      so it names the muscle and not merely the fact that something is selected.
      **`ManualTrainingService`** is the new mechanic. Keys 1-5 pick a muscle, and
      holding or clicking left mouse trains it at `BASE_RATE` 1/s through `StatService`,
      so the modifier stack turns it into the multiplier the Info screen advertises.
      The server owns the clock: the client sends "still holding, on this muscle" and
      never an amount, and payout is rate x elapsed time, so spamming clicks earns
      exactly what holding earns and an auto-clicker gains nothing. A hold expires
      0.9s after the last ping, a dead player earns nothing, and while mounted on a
      machine the manual rate applies only to that machine's own muscle — so a chest
      press with Chest held pays machine + manual, and Core held there pays neither.
      Verified in a clean Studio play session: the bar draws INFO/SHOP/SETTINGS/MAP/RANK,
      the dock is 268px with slot 1 picked on spawn, no panel contains a tab strip, Map
      renders the muscle chips and all seven Legs stations beneath the board, and Core
      raised to x4 through the real purchase remote gained 9.27 over ~2.3s — **4.03/s**.
      Spam-immunity measured directly: 40 clicks in one second paid 1.55 while a single
      ping then idling paid 0.90, the exact activity window.

## Phase 22 — A map in the corner, a muscle on every slot

#98 left the top-left of the screen holding the combat feed: four lines of text that
stayed blank until somebody hit you, so the most valuable corner of the display spent
almost all of its life as an empty grey box. The dock below it was five numbered
squares that named nothing — 3 was Back only to a player who had already read the Info
screen. And punching was still bound to F while the left mouse button had been throwing
punches for a whole phase, so the game had two answers to one question.

- [x] 99. **A minimap where the log was, muscles on the dock, and no more F.**
      **`MapRender`** is new and holds everything the Map screen and the HUD both need:
      the memoised `GetDestinations` round-trip, the bounds maths, the projection, and
      the feature Frames. `MenuController:_renderMap` lost 130 lines to it and keeps only
      what is menu-specific — the paper board, the pins, zoom and pan — and its `Bounds`
      takes the aspect as an optional argument, because the map letterboxes the world
      into a board while the minimap wants the world's own shape.
      **The minimap** replaces the feed at the same 16,68 footprint. It draws the real
      city at 2.6 studs a pixel, pins every station as a dot in its muscle's colour, and
      pans an oversized canvas under a fixed centre dot so a move costs one Position
      write rather than a redraw. The whole panel is the Map button, so the rail drops
      from five tiles to four. The hits the feed used to report are damage numbers over
      the crosshair — dealt on one side, taken on the other — and refusals are toasts.
      **The dock** carries a glyph per stat, named by `StatConfig`'s new `Icon` field so
      a sixth stat brings its own picture. Chest is two pec slabs, Back is a lat V, Core
      is a punched six-pack, Legs is two thighs under a hip, and Arms borrows the fist
      because slot 1 is also the punch. Knockouts are now marked with an attribute
      instead of guessed from a name, which fixed the fist filling in its own knuckles
      whenever it was selected. Selecting a slot pops its glyph and the glyph of the
      muscle actually being worked breathes for the length of the set — `UI.Pop` and
      `UI.Pulse`, which drive the icon rather than the button so they never fight
      `UI.Pressable` over one UIScale.
      **F is gone.** The bind survives only for the touch button and a gamepad's X,
      which have no left mouse button; the hint now says what the click does for the
      slot that is up — "Click to punch — ready" on Arms, "Click to train Back" in
      Back's own green on slot 3.
      Verified in a Studio play session: the feed is gone, the rail draws
      Info/Shop/Settings/Rank, the minimap builds 126 world features and 35 station pins
      and its canvas offset tracks a 200-stud move, all five slots draw their glyph, the
      hint reads correctly for both Arms and Back, and the full Map still renders its
      board with 37 markers. Not measurable in that session: the pop and pulse tweens.
      Studio's renderer was stalled — RenderStepped fired 0 times against Heartbeat's 74
      a second, and a control tween created alongside them stayed at scale 1.000 while
      reporting `PlaybackState.Playing` — so the animation needs a human eye on a real
      client before it is called done.

- [x] 100. **A map that turns, slots you can read, and a motion per muscle.** Playing #99
      found three things wrong with it.
      **The minimap was north-up and never turned**, which is only ever right for a
      player whose camera happens to face world north — walk south under a north-up map
      and the marker slides *down* the screen while you walk up it. It now turns with the
      camera. A zero-sized `Pivot` sits where the marker is and the canvas hangs off it by
      its own `AnchorPoint`, which is set to the player's fraction of the map: the point
      the player stands on lands under the pivot with no arithmetic and stays there when
      the pivot rotates. `Pivot.Rotation` is `-deg(atan2(look.X, look.Z))`, and the dot
      became an arrow that always points up, because once the map turns the marker is the
      thing that says which way up currently means. Refresh went from 10Hz to 30Hz —
      a rotation stepping ten times a second is notchy where a pan is not — and skips its
      writes when neither heading nor position moved enough to see.
      **The glyphs were unreadable**: drawn in the HUD's muted grey on a near-black tile
      at about thirty pixels, which is a smudge however good the shape is. They are now
      drawn in their own stat colour, the slot grew from 48² to 56×62, and the muscle's
      name sits under the picture in 9pt caps — the picture makes a slot findable once
      learned, the word is what teaches it. `Back`'s hairline spine and `Core`'s thin
      punched rows were fattened at the same time.
      **Nothing animated**, for two real reasons and not the stalled renderer: the pulse
      was only ever started while mounted on a machine, so a click-training player never
      saw it, and `UI.Pop` and `UI.Pulse` drove the *same* `UIScale`, so the first slot
      change cancelled the pulse for good. Motion moved into `Icons.Animate`, which owns
      it for the same reason the drawing lives there — only that file knows Chest is made
      of `PecLeft` and `PecRight`. Each glyph gets the motion its muscle has: the fist
      jabs, the pecs press, the lats spread, the abs crunch, the thighs squat. Animators
      are written against a Move/Grow/Turn rig that records each part's resting value, so
      stopping restores the glyph exactly. Standing free, all five idle at 0.45 strength,
      staggered 0.17s apart so the row does not throb in unison; on a machine only that
      muscle moves, at full strength. `UI.Pop` keeps the `UIScale` to itself, so the
      collision is gone.
      Verified in a Studio play session: `pivot.Rotation` reads 0 / -90 / -180 / +90 for
      cameras facing north / east / south / west — facing east puts north on the left,
      which is the check the old map failed — walking 400 studs north moves the anchor
      up the canvas (0.5003 to 0.4563) with the marker staying centred, the dock lays out
      278×69 with all five names, keybinds and stat-coloured glyphs (Arms inverted to the
      backdrop colour because it is selected), and `Icons.Animate` on Chest drives the
      real `PecLeft` and restores its exact `Position` on stop. Still not seen moving:
      Studio's renderer was stalled again — RenderStepped 0 against a live Heartbeat, and
      a control tween frozen at 1.000 while reporting `Playing` — so the five motions are
      verified as geometry and rigging, not as something a human has watched.

- [x] 101. **The map stops escaping its window, and the muscles become models.**
      #100's rotation shipped a serious bug: a white rectangle over much of the screen.
      **Roblox does not clip rotated descendants** — `ClipsDescendants` gives up on them —
      so from the first frame the camera was not facing due north, the entire 3294x2968
      canvas, filled with land and water washed most of the way to white, stopped being
      clipped by the 260x150 window and painted itself across the HUD. The same bug
      explains the second report, "move right and the minimap shows me moving left":
      what was on screen was the escaped slab, not the panel, and a slab sliding left as
      the player moves right reads as the player moving left once the marker anchoring it
      is off in a corner. The pan and heading maths were never wrong.
      Two changes, because one of them should not have to be trusted alone. The window is
      now a **`CanvasGroup`**, which composites its descendants into a texture its own
      size and therefore cannot be escaped. And the minimap stops drawing the city: it
      draws a **1000-stud square around the player** — `MapRender.BoundsAround` and
      `MapRender.FeaturesWithin` — redrawn when they wander 90 studs from its middle. The
      canvas is 384 pixels instead of 3294, so the worst a clipping failure could now do
      is show a little more map than intended, and the rotation re-lays out tens of
      Frames rather than hundreds.
      **The stat icons became 3D.** Flat art failed twice, and the third attempt was not
      going to be more linework: a chest and a back are the same rounded blob in
      silhouette however boldly they are drawn. The Creator Store was checked for free
      icons on request and has no usable set — the results are a Battle Cats logo,
      "hieroglyphs", "Oi", and one `strong-bodybuilder-biceps-flex-arm-vector-icon`,
      i.e. re-uploaded stock art with nothing matching it for the other four muscles, so
      taking them would have broken the project's own asset rule for a worse dock.
      **`MuscleIcons`** builds each slot as anchored Parts in a `ViewportFrame` with its
      own camera at a front-left three-quarter angle and its own light: an arm with a
      bicep, a torso with pecs, a back with wedge lats, a six-pack, hips over legs.
      Nothing uploaded, nothing anyone else drew. Each figure exposes one number —
      `SetFlex(0)` resting to `SetFlex(1)` contracted — and decides for itself what that
      means: the arm curls 105 degrees while its bicep swells 34%, the pecs press
      forward, the lats swing out, the abs shorten and thicken, the hips drop into a
      squat. The HUD drives it with a single cosine, phase-staggered per slot, at idle
      amplitude off a machine and full amplitude for the muscle a machine is working —
      which also retires #100's per-part tween rig and its lifetimes. A stat with no
      figure still falls back to the flat glyph and `Icons.Animate`.
      Verified in a Studio play session: the window is a `CanvasGroup` with a 384px
      canvas against a 221x127 panel; with the pivot rotated -70.7 degrees,
      `GetGuiObjectsAtPosition` — which accounts for rotation — finds **no** minimap
      descendant at the screen centre, 300px right of the panel, the far right edge or
      the bottom, where before the fix the same probe at the same rotation found the
      canvas and a water feature at the screen centre and the far right; walking 600
      studs leaves exactly one canvas parented, the old one destroyed; all five slots
      hold a ViewportFrame with a camera and 5 to 15 parts; and flexing the arm moves its
      fist 0.63 studs while the bicep grows 1.15 to 1.33. Still unwatched: Studio's
      renderer was stalled for a third session — RenderStepped 0 against a live
      Heartbeat — so the white rectangle being gone is proven by the hit-test oracle and
      the bounded canvas, not by a human looking at it.
      **Correction, from #102:** that hit-test oracle was worthless.
      `GetGuiObjectsAtPosition` returns nothing for content inside a `CanvasGroup` — and
      nothing for the synthetic controls either — so "no minimap descendant found
      outside the panel" was measuring the query's blindness, not the fix. The bounded
      canvas stands; the clipping claim does not.

- [x] 102. **The map was a mirror image of the world.** A screenshot settled it: the
      player standing on the right of the starter island, drawn on the left of their own
      minimap. Not the rotation — the projection.
      `MapRender.Project` mapped world +X to the right *and* world +Z upward, on the
      reasoning that +Z is north and screen Y grows downward so north belongs at the top.
      Both halves of that are true and the conclusion was still wrong: flipping one axis
      and not the other is a reflection. Every pin, every island and every building had
      been drawn on the wrong side of the player since the map existed. It hid on the
      Map screen, where nobody knows which side of an unfamiliar city they are on, and
      became obvious the moment a minimap put the player in the middle of it.
      The check that settles the orientation: an identity `CFrame` in Roblox faces -Z
      with its `RightVector` at +X, so a character seen from above facing up the screen
      has +X to the screen's right, which puts **+Z down**. North is a label; not being
      mirrored is a fact. The projection drops the flip, and the minimap's heading
      becomes `-deg(atan2(look.X, -look.Z))` to match — up the panel is now -Z.
      Also fixed while there: the minimap was a pale grey box because every feature was
      washed 62% toward white, the same as the big paper board it inherited that from.
      `DrawFeatures` takes a wash override, the minimap uses 0.2, and its ground is the
      HUD's own dark backdrop rather than paper, so water, land and buildings are three
      different colours instead of three off-whites.
      Verified in a Studio play session, and this time with an oracle that has teeth. For
      five camera headings, every destination pin the real code drew was carried through
      the real pivot rotation and compared against ground truth — the pin's true offset
      resolved onto the camera's own right and forward vectors. **New code: 5/5 pins
      correct at every heading, worst alignment 1.000.** The same measurement re-derived
      for the old projection and old heading formula: **0/5, 0/5 and 1/5, with alignments
      down to -0.998** — pins pointing the exact opposite way. Still unwatched: Studio's
      renderer has been stalled for four sessions, so the wash and the dark ground are
      chosen, not seen.

- [x] 103. **An opaque minimap, and one sentence deleted from thirty-five signs.**
      The minimap was still reading as two pictures on top of each other. Every other
      HUD panel is glass over the world, which is right for text — a city faintly behind
      a number costs nothing — and wrong for a map, where anything showing through is
      indistinguishable from something drawn on it. The panel was 25% transparent and the
      water drawn on it another 10%, so a dark roof passing behind the corner came
      through both and read as terrain. The panel and its window are now fully opaque on
      the HUD's own dark ground. The redraw also gained a re-entrancy guard and a sweep
      of any stray canvas, so two maps stacked on the pivot is impossible by
      construction rather than merely unlikely.
      **The machine signs lost a line.** Each one printed what the stat is FOR — "14
      damage a hit" — which is a fact about the player, not about the machine, so all
      thirty-five signs in the city printed the same sentence. Thirty-four of those are
      clutter standing in the middle of the world, and the Info screen already answers
      it once in the place a player goes to ask. The sign is three lines now — name,
      stat and rate, how to get on — and shrank from 90 to 70 pixels to match.

- [x] 104. **The floor was two floors.** "The map looks overlap, look at the floor" was
      never about the minimap. The hub's plaza is a 180-stud pavement disc lying on a
      470-stud ground disc and **both top faces were at exactly y=1.0000**, so the
      renderer had no way to choose between them and tore the whole plaza into a
      flickering checkerboard. A screen capture of the ground shows it plainly; nothing
      in the generator looked wrong, because every walkable surface is *meant* to top out
      at `FLOOR_TOP` so a machine placed there stands flush.
      The rule now has a direction. `GROUND_SINK` (0.05) drops the base layers — the hub
      ground, the island decks, the district grounds and lobes — a twentieth of a stud
      below `FLOOR_TOP`, far too little to step on and far more than the depth buffer
      needs. `SURFACE_LIFT` (0.04) is its mirror, for a paved surface laid on another:
      the interiors' `Floor1` sits on `SitePavement` and now clears it.
      **`validate_no_coplanar_floors`** stops it coming back. It projects every flat
      visible part onto the ground as a real rotated rectangle — not a bounding box,
      which reports two neighbouring slabs in a rotated building as overlapping and a
      disc as having no width at all — buckets them by height, and fails the build on any
      pair sharing a top face within a hundredth of a stud over more than a few square
      studs. It caught `SitePavement` against `Floor1` immediately after the hub was
      fixed, which is the whole argument for having it.
      **The vitals box is gone.** It sat in the middle of the screen carrying the health
      bar and two permanent sentences — how to mount a machine, and what the left mouse
      button would do — which said the same thing whether or not a machine or an enemy
      was anywhere near, so they stopped being read in the first minute and kept the
      centre of the screen for the rest of the session. The dock already names the muscle
      the click trains and the machines say "Hold E" on their own signs at the moment it
      is true. Health is a bar in the bottom-left corner, and `_refreshVitals` is nine
      lines instead of sixty.
      Verified by looking at it: screen captures of the plaza before and after, from a
      standing angle and from overhead. Before, the ring around the plaza is ripped into
      striped fragments; after, it is one clean paved disc. `validate_gym.py` passes with
      3927 instances and the new rule armed.

- [x] 105. **Grounded again, and a health bar you can read at a glance.**
      #104 fixed the tearing by sinking the ground half a twentieth of a stud, and got
      the direction wrong: the ground is what things stand on, so every lamp post and
      bench on it started hovering. The lift moved to the surface laid *on top* instead —
      `SURFACE_LIFT` on the plaza, the site pavement and the launch pads, twice over for
      an interior floor that sits on pavement that sits on ground. Anything standing on
      those is now bedded four hundredths of a stud into them, which nobody can see,
      where hovering four hundredths above them is exactly the kind of thing that gets
      noticed.
      Chasing that turned up an older one. **`PLAZA_TOP` was `FLOOR_TOP + 0.8`** and had
      been for a long time — a height the plaza has never had — so the benches, the coach
      and the leaderboard plinth had all been floating **0.72 studs** in the air, small
      enough to read as a rendering quirk and large enough to see standing next to one.
      It is now the plaza's actual surface. A raycast sweep of everything at ground level
      within 240 studs of spawn reports no unexplained gap left; what remains is machine
      internals held up by their own frames, which is what a roller on its posts is
      supposed to do.
      **The health bar shows both halves.** It was one red block whose length you had to
      judge against a dark track. `UI.Bar` takes an optional colour for the empty part, so
      health is green for what is left and red for what has been taken — at 79/100, 79%
      green and 21% red, and the split tells you the number before the caption does.

- [x] 106. **A refusal only speaks when it has something to say.** The screen filled with
      "Not ready yet." Since the punch moved onto left-click, every click of a held mouse
      button asked the server for a hit, and every one inside the 0.6s cooldown got a
      rejection back — which #99 had helpfully routed to the toast strip. The player was
      being told, several times a second, a thing the cooldown had already said by
      refusing.
      `CombatService:Activate` now returns a third value: whether the refusal is worth
      hearing. A safe zone or a barrier is — it is a rule you can act on. "Not ready
      yet", "No target" and "Too far away" are not; they are the ordinary texture of
      holding a button down, and the server no longer sends them at all. The decision
      sits with the code that knows why it refused rather than with a string match at
      the other end.
      `CombatController:Attack` also stops asking when it already knows the answer,
      keeping a local copy of the cooldown. The server still re-checks — the worst a
      client that strips this achieves is asking for hits it will not get — but it means
      a held button sends one request per cooldown instead of one per click, which also
      keeps the remote clear of its own eight-a-second limit.

- [x] 107. **Enemy health, in the same two colours as your own.** The whole hook of this
      game is that other players interrupt your training, so the most useful thing to
      know about someone across the plaza is how close they are to going down — and the
      only thing on screen was Roblox's built-in plate: a hairline that appears once
      somebody is already hurt, in a red that reads as *empty* on a player at full
      health. **`NameplateController`** switches the default off
      (`HealthDisplayType.AlwaysOff`) and draws a real one over every other player's
      head: their name, and a `UI.Bar` in the same green-over-red as the bar in the
      corner of your own screen. One visual language — green is what is left, red is
      what has been taken, wherever it appears.
      It carries the numbers as well as the length, because Chest pushes max health into
      the thousands and "half a bar" stops meaning a fixed amount of damage very early
      on. Occluded by walls like the machine signs, since seeing health through a
      building is a wallhack the game would be handing out for free, and dropped past
      150 studs where it is unreadable anyway. Event-driven off `HealthChanged` and
      `MaxHealth` rather than polled: a plate changes a handful of times a minute, and
      the alternative is recomputing every plate on the server every frame. MaxHealth is
      watched precisely because training Chest mid-fight would otherwise leave a player
      at full health drawn as wounded until their next hit.
      Verified in a play session by driving the real `_attach` path against a live rig:
      the plate adorns the head at 140x36 with MaxDistance 150 and AlwaysOnTop false,
      both default displays report off, the fill is (88,202,106) over a (239,83,80)
      track, and it reads 1.00/"100 / 100" at full, 0.40/"40 / 100" after damage and
      1.00/"200 / 200" once MaxHealth doubles — not 0.40 — with `_clear` removing it
      cleanly. The local player correctly gets no plate. Not covered: the two-player
      join path, which needs a Studio local server this session cannot launch.

- [x] 108. **Training says exactly what it paid, and the menu follows the HUD sketch.**
      Machine feedback used to be either absent or reconstructed on the client from a
      zone attribute and token-upgrade level. That estimate could not see the full
      modifier stack, the live combo, or a gain clipped by the stat cap, so the number
      over the player could disagree with the profile it claimed to describe.
      `TrainingService` now sends a `TrainingGain` only after `StatService:AddStat`
      returns the amount that actually landed. `EffectsController` turns it into an
      original world-space card above the local avatar: the muscle's procedural icon,
      `+amount Stat`, and the equivalent `/ SEC` rate, rising and fading in a bounded
      stack. The client grants nothing and guesses nothing.
      The navigation now matches the supplied wireframe's hierarchy: one bottom-right
      **MENU** button opens a dark three-tab **INFO / SHOP / SETTINGS** panel; the five
      muscle hotbar remains bottom-centre; Rank has its own bottom-left route; the
      compact power/reputation roster stays top-right; and the main goal sits beneath
      it instead of overlapping it. Info has a player portrait and the five-stat
      multiplier ladder with confirmation. Shop groups the live server catalogue into
      VIP/passes, immortal potions, token dumbbells, and Robux supplements. Settings has
      server-whitelisted, persisted Music/SFX toggles plus the VIP daily claim; disabled
      SFX now actually silences the shared effects path. Required-power machine signs
      also carry the warning badge and honest `+Stat/s` copy from the reference without
      warning on ungated starter machines.
      Verified with StyLua, Selene (zero warnings), strict Luau LSP analysis, every pure
      self-test, generated-gym and balance validation, `git diff --check`, and a clean
      5.3 MB Rojo place build. Visual Studio playtesting remains the next human check.

- [x] 109. **The five muscles become the cartoon identity of the interface.** The first
      pass had the right routes but still looked like a dark admin panel: Rank lived by
      health rather than by the action dock, Info needed a scrollbar to reveal Legs,
      and Shop presented products as full-width catalogue rows. The requested hierarchy
      is now literal. Rank is a chunky sixth card immediately left of the five bottom
      stat slots, and the entire group shares one baseline. The stat slots grow to
      thumb-sized, outlined, saturated cards with a bright top shine, circular key
      badges, dark name bands, and the original animated 3D muscle figures; selection
      changes the card gradient, badge, outline, and figure ink as one state rather than
      merely filling a background.
      Info disables scrolling entirely. A rank-coloured profile hero fits above three
      fixed rows: Arms/Chest, Back/Core, then Legs beside a total-build summary. Every
      muscle owns a large round pictogram, current value, multiplier, gameplay effect,
      and a two-line upgrade control without pushing another muscle below the fold.
      Shop is rebuilt as responsive two-column card grids with separate saturated visual
      families for VIP/passes, immortal potions, token dumbbells, and Robux
      supplements. Each card has an original procedural glyph, short description, and
      full-width price state; the existing server catalogue still decides availability,
      ownership, pricing, and grants.
      `UI.CartoonCard` and four shared palette colors keep the outline/gradient/highlight
      language reusable rather than duplicating it per page. Narrow screens lift health
      above the enlarged centred dock to avoid overlap. Roblox's current `UIGridLayout`
      documentation was checked for the product-grid behavior and constraint support.
      Verified with StyLua, Selene (zero warnings), strict Luau LSP analysis, every pure
      self-test, generated-gym and balance validation, `git diff --check`, and a clean
      5.3 MB Rojo place build. A human Studio screenshot pass is still required to judge
      the subjective final colors and optical spacing.

- [x] 110. **Rank joins the actual top-right roster, and Info reads as five rows.** The
      earlier interpretation placed Rank beside the bottom muscle dock. It now sits
      immediately left of the custom player/power/reputation roster, shares its top edge,
      opens the existing Ranks page, and hides with that roster when Tab is pressed. The
      duplicate bottom Rank card and its narrow-screen health workaround are removed.
      Info now mirrors the five-slot muscle pattern literally: Arms, Chest, Back, Core,
      and Legs each own one full-width, equal-height row. The profile hero and five rows
      fit the fixed viewport without scrolling or replacing a muscle with a summary
      card. Gotham Bold/Medium, larger high-contrast values and effects, compact icons,
      and one readable single-line upgrade button per row replace the cramped two-column
      typography.
      Verified with StyLua, Selene (zero warnings), strict Luau LSP analysis, every pure
      self-test, generated-gym and balance validation, `git diff --check`, and a clean
      5.3 MB Rojo place build. A human Studio screenshot pass remains the final optical
      check because Studio is not available in this workspace.

- [x] 111. **Quests become a standalone, honest and readable surface.** Opening Quests,
      Map or Ranks now hides the unrelated Info/Shop/Settings strip and gives the page
      that vertical space. The old three cramped text lines are replaced by full-width
      quest cards with a pictogram, clear title and description, reward badge, and
      labelled progress bar. Gym Rat no longer counts the four quarter-second
      `StatChanged` payments from manual training as four whole reps: it measures the
      actual Power awarded, so its visible progress rises with the visible Power total.
      Schema v2 resets only the old inflated Gym Rat progress/completion when an
      existing save loads.
      The shared Heading, Body and Numeric faces now all use the same Gotham Bold seen
      on the readable QUESTS button. Text-button strokes explicitly use border mode,
      preventing their outlines from turning small tab, purchase and upgrade copy into
      dark blobs. Shop presentation sorts VIP before Fast Travel while leaving the
      server-owned catalogue and purchasing rules intact. Product-truth and playtest
      documents record the new behavior.
      Verified with StyLua, Selene (zero warnings), strict Luau LSP analysis, every pure
      self-test, generated-gym and balance validation, `git diff --check`, and a clean
      5.3 MB Rojo place build. Studio remains the required final visual and interaction
      check.

- [x] 112. **Info stat icons explain effects instead of resembling body-part blobs.**
      The five small glyphs were reviewed against current interface-icon guidance:
      one familiar concept, a streamlined silhouette, consistent optical weight, and
      no detail that disappears at the 32-pixel effective drawing size. Arms is now a
      four-knuckle punching glove; Chest is a health heart; Back is a durability shield;
      Core is a bullseye; and Legs is a running shoe with motion rails. All five remain
      original, scale-based Frame drawings with no uploaded or third-party assets. The
      same keys continue to drive the existing 3D muscle figures in the bottom dock,
      while gain popups inherit the clearer flat symbols.
      Verified with StyLua, Selene (zero warnings), strict Luau LSP analysis, every pure
      self-test, generated-gym and balance validation, `git diff --check`, and a clean
      Rojo place build. Studio remains the final optical check at desktop and mobile
      sizes.

- [x] 113. **The five-stat dock and Info speak one icon language.** The Legs shoe still
      produced an ambiguous silhouette, so it is replaced by a direct speed arrow with
      three motion rails. The bottom dock no longer swaps the five flat stat symbols for
      a separate collection of miniature 3D figures: Arms, Chest, Back, Core and Legs
      now use exactly the same glove, heart, shield, target and speed-arrow drawings in
      Info, the persistent dock and gain feedback. Selection still inverts the shared
      glyph against the stat-coloured tile, and each glyph's lightweight idle/training
      tween now targets its current named parts rather than the retired anatomical art.
      Verified with StyLua, Selene (zero warnings), strict Luau LSP analysis, every pure
      self-test, generated-gym and balance validation, `git diff --check`, and a clean
      Rojo place build. Studio remains the final optical check at desktop and mobile
      sizes.

- [x] 114. **Muscle numbers and their visible effects advance together.** Arms and
      Chest now grant direct one-for-one bonuses above clearly separated avatar bases:
      +1 Arms is +1 raw punch damage, and +1 Chest is +1 current and max health. Legs
      is also +1 stud/second to both sprinting and flight until the existing 64/120
      physical safety ceilings; its Info row shows the two earned bonuses rather than
      hiding them inside total velocities. Back and Core deliberately remain contested
      reduction and retaliation percentages.
      Chest and Legs effects now apply on the same `StatChanged` event as the stored
      muscle instead of waiting for the old one-second vitals poll. Chest preserves
      missing health, so even an injured player sees the same +1 in current and maximum
      health. Direct Arms scaling is paired with proportional power-gap protection so
      massive players still need several hits against a beginner rather than inheriting
      the old unsafe 25% damage floor. Manual input remains server-clocked hold-to-train:
      clicking five times in a second cannot manufacture five reps, but every point the
      server awards now moves its matching effect at the documented rate.
      Verified with StyLua, Selene (zero warnings), strict Luau LSP analysis, every pure
      self-test (including explicit +1/+5 mappings), generated-gym and balance
      validation, `git diff --check`, and a clean Rojo place build. Studio remains the
      final live health-bar, sprint and flight feel check.

- [x] 115. **Percentage muscles have visible, enforceable ceilings.** A fresh avatar's
      punch now starts at 1 damage rather than 8, while every trained Arms point still
      adds exactly one. Back and Core keep the logarithmic progression required by an
      exponential-stat game, but their safety rules are no longer hidden magic numbers:
      Back is capped at 50% resistance and Core at 35% reflection. One hundred points
      therefore gives roughly 16% best-case Back resistance and 6% Core reflection—not
      immunity—and further training advances with diminishing returns toward, never
      through, the caps. Back remains contested against the attacker's Arms, and Core
      only reflects a hit the defender survives.
      The Info rows now show the live percentage with one decimal place beside the hard
      cap, and their descriptions explain the relevant combat condition. Named formula
      constants drive both mechanics and copy; a dedicated `RetaliationRate` removes the
      old UI trick of calculating reflection from a sample 100-damage hit. Hostile-input,
      100-point and astronomical-stat self-tests assert neither percentage can reach
      100%. Verified with StyLua, Selene (zero warnings), strict Luau LSP analysis,
      every pure self-test, generated-gym and balance validation, `git diff --check`, and
      a clean Rojo place build. Studio remains the final optical and combat-feel check.

- [x] 116. **The full map becomes a dedicated navigation surface.** Clicking the
      minimap now opens `FullMapController`'s wide modal rather than a map-sized
      `ScrollingFrame` nested inside MenuController's vertically scrolling page. The
      canvas owns wheel zoom, +/−/reset controls, mouse drag and touch drag directly;
      scrolling up zooms in, scrolling down zooms out, and there is no parent page that
      can steal either gesture. The complete paper map and all 35 colour-coded circles
      remain visible, while the menu tabs and old Train list stay off this surface.
      Selecting a circle preserves the current pan/zoom, highlights only the new pin,
      and refreshes a fixed sidebar with the machine, muscle, rate, access and Power
      requirement. **Track** is permanently separate and free. **Teleport** is visibly
      locked behind Fast Travel, opens its purchase prompt for non-owners, changes to a
      Power lock when appropriate, and updates in place after a successful gamepass
      purchase. `TravelService` still validates ownership, Power, combat state and the
      destination on every request, so none of the client presentation grants travel.
      Menu/full-map mutual exclusion prevents stacked modals, and map-open analytics
      follows the new controller signal. Product-truth and playtest contracts now
      describe the two-action flow and the wheel-direction regression.
      Verified with StyLua, Selene (zero warnings), strict Luau LSP analysis, every pure
      self-test, generated-gym and balance validation, `git diff --check`, and a clean
      Rojo place build. Studio remains the required mouse-wheel, touch, purchase-prompt
      and 35-pin optical check.

- [x] 117. **The full map stops closing on drag and its circles identify themselves.**
      The dark full-screen scrim is now a visual `Frame`, not a giant invisible
      `TextButton`, so releasing a mouse/touch pan at the edge cannot be interpreted as
      an outside click. The dedicated **X**, **Escape**, and **M** controls remain the
      only close paths. The 35 destination circles no longer sit directly on top of
      near-identical venue coordinates at overview zoom: destinations sharing a real
      neighbourhood are sorted deterministically and spaced around its geographic
      centre, while tracking and teleporting retain each machine's exact world
      position. Every circle now carries both an unambiguous two-letter muscle code and its
      abbreviated gain multiplier, including locked pins, so colour is reinforcement
      rather than the only explanation. Product-truth and playtest contracts cover the
      drag-release regression, default-zoom separation, labels, and five-pin Hub case.
      Verified with StyLua, Selene (zero warnings), strict Luau LSP analysis, every pure
      self-test, generated-gym and balance validation, `git diff --check`, and a clean
      Rojo place build. Studio remains the required mouse, touch, scaling, and 35-pin
      optical check.

- [x] 118. **The map quiets down and points to one useful next workout.** The complete
      city drawing now sits beneath a dark-slate wash, and all non-recommended pins use
      restrained versions of their muscle colours. One gold-ringed circle remains the
      clear focal point: `FullMapController:_recommend` finds the player's lowest raw
      muscle value, resolves ties in the five-stat dock order, and chooses that muscle's
      highest multiplier currently unlocked by total Power. The recommendation opens
      selected, identifies itself in the sidebar and bottom map status, updates when
      training changes the weakest muscle or Power unlocks a better tier, and never
      changes the server's travel authority. Manual selections keep a deliberately thin
      light outline so they remain locatable without competing with the recommendation.
      Cluster spacing grew with the focal pin, preserving the no-overlap contract.
      Product truth and playtests now define the darkness, single-highlight rule,
      weakest-stat calculation, tier selection, and deterministic ties. Verified with
      StyLua, Selene (zero warnings), strict Luau LSP analysis, every pure self-test,
      generated-gym and balance validation, `git diff --check`, and a clean Rojo place
      build. Studio remains the required visual hierarchy and live-recommendation check.

- [x] 119. **The map highlights a training tier, not a favourite muscle.** The first
      recommendation pass overreached: a large gold Arms circle at equal starter stats
      looked like the game wanted players to train only Arms. The weakest-stat
      recommendation and oversized gold marker are removed. The map now derives one
      current multiplier from total Power and keeps all five muscles in that tier at
      their full colours—×1 at spawn, then ×2 through ×64 as each threshold unlocks.
      Earlier unlocked tiers and future locked tiers remain labelled and clickable but
      subdued. Opening the map no longer preselects an arbitrary Arms destination;
      clicking any circle adds only a thin selection outline and does not alter the
      five bright tier pins. The sidebar and map footer call this the **current Power
      tier**, and live profile updates repaint only when the accessible multiplier
      changes. Product truth and playtests replace the one-muscle recommendation
      contract with equal five-muscle tier emphasis. Verified with StyLua, Selene (zero
      warnings), strict Luau LSP analysis, every pure self-test, generated-gym and
      balance validation, `git diff --check`, and a clean Rojo place build. Studio
      remains the required brightness and tier-transition check.

- [x] 120. **Every muscle pays on one clock and every local Power display agrees.**
      Exercise `RepInterval` remains an animation choice—Treadmill can move at 0.5s and
      Deadlift at 1.2s—but `TrainingService` now converts each definition back to its
      normalized per-second base rate and awards every machine exactly once per second.
      Combo advances on that shared tick, so fast animations cannot build it sooner.
      Manual hold training also moves from four 0.25s slices to one one-second payout
      and is disabled while mounted, removing the hidden machine+mouse double award.
      The top-left HUD and Info page already consumed the immediate private profile;
      the local top-right roster row now overlays its one-second public roster snapshot
      with that same profile Power, eliminating the screenshot's 42/41/42 disagreement
      without broadcasting every player's entire roster on every stat change. The full
      map's slate overlay becomes twelve percentage points more opaque while its current
      tier pins remain above and undimmed. The balance extractor exports the authoritative
      one-second tick, the simulator pays and advances combo on it, and all published
      pacing tables are regenerated (active 1-hour Power 95.8K→100.9K; 24-hour Power
      11.03B→11.40B). Product truth and playtests now require one visible payout per
      second across every muscle, no mounted stacking, three-way local Power agreement,
      and the darker map. Verified with StyLua, Selene (zero warnings), strict Luau LSP
      analysis, every pure self-test, generated-gym and balance validation, a deterministic
      24-hour simulation, `git diff --check`, and a clean Rojo place build. Studio remains
      the required real-time cadence, display synchronization, and map-contrast check.

- [x] 121. **Training rates are additive and exact, feedback replaces instead of stacks,
      and the map legend belongs to the map.** The universal unmounted rate is now one
      stat per second. A mounted station adds its printed location/equipment bonus rather
      than replacing that base, so an x1 starter pays +2/s and an x4 station pays +5/s
      before owned multipliers. Station labels show both EQUIP and TRAINING. The old hidden
      2%-per-tick combo produced fractional stored stats and made whole-number displays
      alternate +1/+2; it is now one explicit x2 milestone at 50 uninterrupted ticks,
      reported in the gain card. Manual training uses a per-hold one-second clock and an
      explicit mouse-release stop, and both manual and machine paths send the same typed
      server-authored popup for all five muscles. `EffectsController` permits only one
      live training card and finishes it in 0.78s, guaranteeing the next tick never
      overlaps it. The full map replaces leaky CanvasGroup clipping with a hard clipping
      Frame and parents the muscle legend to the zoom/pan canvas, so an enlarged sheet
      cannot cover the sidebar and its legend no longer floats at the old screen point.
      The shared formula, balance extractor/model, product truth and manual playtests are
      updated. Verified with StyLua, Selene, strict Luau analysis, pure self-tests,
      generated-gym/balance validation, deterministic simulation, `git diff --check`,
      and a clean Rojo build; Studio remains required for visual timing and clipping QA.

- [x] 122. **The full-map legend stays visible and zoomed geometry stays inside.**
      Parenting the five-muscle legend to the moving canvas made it correctly move—and
      therefore disappear—as soon as the canvas panned under a zoom focus. A normal
      clipping Frame also did not contain Roblox's rotated map-feature GuiObjects, which
      painted pale buildings and land across the header, sidebar and world HUD. The
      legend is fixed navigation chrome on `MapBoard` again. The map viewport is now a
      non-scrollable `ScrollingFrame`: its native rectangular scissor is used only for
      rendering, while the dedicated controller retains complete ownership of wheel,
      mouse-drag and touch input. The outer modal also clips descendants, and Sibling
      Z-index groups put the map below the fixed legend, zoom controls, title and sidebar.
      Product truth and the visual playtest now require the legend at top-left and zero
      geometry outside the map rectangle at every zoom/pan position. Verified with
      StyLua, Selene, strict Luau analysis, pure self-tests, generated-gym and balance
      validation, `git diff --check`, and a clean Rojo build; Studio remains the required
      proof for Roblox's native rotated-Gui clipping behavior.

- [x] 123. **Map containment moves from container hope to direct-child geometry.** The
      screenshot after #122 proved that even a non-scrollable `ScrollingFrame` does not
      clip rotated GuiObjects nested beneath an enlarged intermediate canvas: the legend
      stayed fixed, but land, buildings, cluster circles and pins still escaped all four
      sides. `FullMapController` now creates every MapRender feature, training pin, spawn
      label and player marker as a direct viewport child. A stored normalized position/
      size record reproduces the former canvas transform for each item on zoom and pan;
      cluster offsets and pin sizes remain screen-readable while feature footprints scale.
      Only the plain paper and dark wash remain enlarged direct rectangles. Roblox's
      native scissor is therefore the immediate parent of every potentially rotated or
      rounded shape, eliminating the descendant-clipping failure rather than covering it
      with masks. Product truth and edge-focused playtests are updated. Verified with
      StyLua, Selene, strict Luau analysis, pure self-tests, generated-gym and balance
      validation, `git diff --check`, and a clean Rojo build; Studio remains the visual
      proof for all four edges at maximum zoom.

- [x] 124. **Opt the place into Roblox's rotated-GUI clipping renderer.** A second Studio
      screenshot proved #123 still leaked every non-zero-rotation building even when it
      was an immediate child of the clipped viewport. Roblox's current rollout keeps
      rotated clipping disabled for existing places unless
      `StarterGui.ClipsDescendantsSupportsRotation` is explicitly Enabled; under the
      legacy renderer, hierarchy changes cannot make `ClipsDescendants` crop rotated
      Frames. `default.project.json` now owns that saved place setting. The Rojo build
      serializes it as RolloutState token 2, activating the engine path that clips the
      rotated features against the map square while leaving fixed legend and controls
      alone. Product truth and the Studio playtest call out the required setting.
      Verified with StyLua, Selene, strict Luau analysis, pure self-tests, generated-gym
      and balance validation, `git diff --check`, a clean Rojo build, and inspection of
      the built rbxlx property.

- [x] 125. **Full-map containment becomes renderer-independent.** A third maximum-zoom
      Studio screenshot proved the rollout opt-in still did not contain rotated map
      Frames in this place. `MapViewportMath` now calculates each item's complete
      rotated axis-aligned bounds in viewport pixels, and `FullMapController` keeps the
      item hidden whenever that bound touches any of the four edges. Items also start
      hidden until the first non-zero viewport layout, eliminating the opening-frame
      flash. This is intentionally stricter than partial clipping: no Roblox renderer
      path can draw a feature that the controller has made invisible. The pure self-test
      reproduces the important case—a 45-degree square whose unrotated box fits but
      whose rotated corners cross the edge—and verifies it is rejected. Product truth
      and the edge playtest now describe the software containment rule. Verified with
      StyLua, Selene, strict Luau analysis, all pure self-tests, generated-gym and
      balance validation, `git diff --check`, and a clean Rojo build.

- [x] 126. **Make every bottom stat card a real +1/s training control.** The dock cards
      previously changed selection without owning the press, while the global mouse
      release stopped the server clock before its first one-second tick. Each Arms,
      Chest, Back, Core and Legs card now owns its mouse/touch hold and locks the trained
      muscle for that hold. A GUI hit-test prevents the same card press from also becoming
      a world-space training click or Arms attack. The authoritative server clock and
      standard replacement gain card remain unchanged, so each completed base interval
      awards exactly one point and displays `+1 Muscle` without client-side stat math.
      Live Studio holds of 1.15 seconds verified Arms 41→42, Chest 31→32, Back 32→33,
      Core 33→34 and Legs 34→35; live GUI inspection read `+1 Chest` and
      `1 / SEC · BASE TRAINING`. Verified with StyLua, Selene, strict Luau analysis, all
      pure self-tests, generated-gym and balance validation, `git diff --check`, and a
      clean Rojo build.

- [x] 127. **Sculpt a Gym-League-style final form and identify the muscle being trained.**
      Full in-class growth now cross-fades the visible rectangular R15 body into 15
      overlapping torso/waist/arm/hand/leg shells while preserving the original rig as
      its invisible hitbox. A broad upper torso, narrower midsection, compact waist and
      continuous ellipsoid limbs replace the old spherical body blobs and cut-off limb
      cylinders. Over that mass sit deltoid caps, separate biceps/triceps, paired rounded-
      band pecs, a ten-piece trap/rhomboid/lat/erector back, six abs with obliques, and
      quad/hamstring/calf contours. The anterior shapes were corrected to Roblox
      avatar-front −Z, fixing pecs, abs and quads previously hidden behind the body. Each group
      still listens only to its own progress since the last physique change, so the
      player builds back from lean without losing lifetime stats. Machine and manual
      training publish the authoritative active stat; the local avatar receives a faint
      white wash on the supporting body part and a stronger white fill on that stat's
      sculpted contours. Manual release and machine stop clear it locally before the
      network round trip. Live Studio verified lean at 0 shells/0 contours, isolated Arms
      at 6 shells/8 contours with an untouched torso, and full growth at 15 shells/34
      contours. Arms/Chest/Back/Core/Legs highlight 18/6/14/13/16 pieces respectively,
      with zero remaining after stop. Selene has zero warnings, all pure self-tests and
      world validation pass, and strict analysis reports only existing UI/FullMap issues.

- [x] 128. **Combat gets a framework the abilities can be config in.** Abilities were
      already open/closed on the server — a file in `CombatService/Abilities/` is
      discovered at startup — but the client was not: `CombatController` hardcoded one
      ability id, one cooldown mirror and one bind, so the second ability would have
      needed a second copy of all three. `AbilityConfig` becomes the manifest both
      realms read (id, key, cooldown, HUD glyph, colour), is deliberately free of the
      Roblox API so `scripts/selftest.luau` can check it, and names E, C, Space and
      LeftShift as reserved so no ability can silently fight the training prompt.
      `CombatController` now binds every row in it and `HudController` draws one slot
      per row with a cooldown sweep. Combat also gains three reusable primitives it had
      no form of: `GetTargetsInRadius` (all targets, not the nearest, providers
      included via an optional `FindAllInRadius`), `ApplyKnockback` (the game's first
      impact physics, a short-lived `LinearVelocity`, refused for safe-zone and immortal
      players and never dismounting a training victim), and a `RegisterDamageModifier`
      registry so a defensive move can have the last word on damage without a branch
      inside `ApplyDamage`. Dash moves from Q to C to free the key.

- [x] 129. **A procedural VFX system, because the game had none.** Nothing in the
      workspace had ever flashed, cracked or shaken — `EffectsController` was damage
      numbers and silent sounds. `VfxConfig` declares effects as layered data (ring,
      flash, shards, burst, shake, impact beat, scorch, trail) and `VfxController`
      builds them at runtime from Roblox primitives under `CurrentCamera`, so nothing
      replicates and a crater costs one client one frame. Everything is ours by the
      project's asset rule: engine-bundled `rbxasset://` particle textures and
      `Enum.Material.ForceField`, no upload. Effects are timed against the strike clip
      that owns them, so retiming an animation moves its crater with it. The impact beat
      is named for what it does rather than how — a true hit-stop cannot freeze a
      procedural animation without desyncing it from server damage timing, so the camera
      holds and the FOV punches instead. Studio verified the slam crater builds 22
      shards, 2 rings, 2 bursts and a scorch; the first pass was retuned after a
      screenshot showed dinner-plate slabs and dust thick enough to hide the fight.

- [x] 130. **Ground Slam, Hard Punch and Block.** Q is a leap and a smash: one contact
      two thirds through a 1.15s clip, damage falling off linearly to the rim, and
      everybody inside launched. R is one telegraphed heavy — nearly half its clip is
      wind-up, which is the entire reason Block has something to react to; the self-test
      asserts it stays slower to land than a jab. F is a held guard owned by
      `BlockService`: generous when outmatched by design (a defensive move that stops
      working when you need it is not a move), draining on time and on damage absorbed
      at a rate scaled to the victim's own health so it survives the same number of hits
      at every point on the curve, and shattering into a three-second lockout if
      emptied. The guard dome is deliberately not an effect but a state — the first
      build made it one and shipped a barrier that flashed for 0.38s while the guard was
      still up — and it is shrunk rather than faded away, because ForceField draws its
      own shell and ignores `Transparency` entirely. Verified live in Studio: all three
      fire from their keys, the bar sweeps, the meter drains red and breaks, and the
      dome renders around the character.

- [x] 131. **Flight gets an animation, and the body earns the right to tilt.** Flight
      had none: FlightController puts the humanoid on PlatformStand and drives a
      LinearVelocity, so Roblox's freefall clip kept playing and the avatar read as a
      standing body sliding through the air. That is also why the controller held the
      body rigidly upright — its own comment said a rig with no flight animation looks
      like a falling body when pitched — so the pose is what removes the workaround
      rather than layering on it. `FlightConfig` holds three silhouettes (upright
      hover, leaning glide, near-horizontal superhero cruise with the leading fist
      out), deliberately not a `PoseConfig` entry because a Pose cycles on a machine's
      rep interval and flight blends on speed. `FlightPoseController` consumes them on
      PreSimulation, modelled on `TrainingPoseController`, and clears every joint to
      identity on landing or death. The controller now pitches from vertical velocity
      and banks from how fast the heading is swinging, both clamped and eased.
      Flight was also the one body state nobody else could see: `FlightAllowed` said
      who *may* fly and nothing said who *is*, so a remote flier was unmarked. A
      `FlightChanged` remote and a `FlightState` attribute close that, carrying coarse
      bands rather than a per-frame float — the local flier blends from its own
      velocity and never reads the attribute, so the coarseness costs the only person
      who could notice it nothing. VFX: four contrails that ride the speed blend in
      width, lifetime and heat, camera speed lines, a takeoff ring, a landing dust puff
      pointedly lighter than a slam, a one-shot sonic boom with hysteresis, and
      speed-scaled field of view folded into the existing camera hook. The flight
      update runs on Heartbeat rather than RenderStepped, which a Studio session proved
      matters — a backgrounded window throttles RenderStepped to zero. `StrikeConfig`'s
      self-test had been written and never called from anywhere; it and FlightConfig's
      now run at Studio boot, since both build poses from Vector3 and the CLI cannot
      require them. Verified live: the cruise silhouette applies to the rig, hovering
      eases back upright, landing releases every joint and every trail, and contrails
      sit disabled at rest and near-maximum at speed.

- [x] 132. **Walking and running stop being Roblox's.** Locomotion was the last
      animation in the game that was not ours — the stock Animate script playing
      Roblox's uploaded walk and run clips — and it is the animation players see most:
      training is a pose at a machine, flying is occasional, fighting is bursts, and
      running is every other second of the session. `GaitConfig` holds a heavy
      gym-bruiser walk and sprint as `PoseConfig.Pose`-shaped cycles, so
      `PosePlayback.AlphaAt` drives them unchanged. Almost nothing new was needed:
      `JointMotion.Phase` already existed for limb opposition and its own comment cited
      "a running stride", and `StairClimber` was already a walk cycle in all but name,
      so its phase structure (hips half a cycle apart, knees lagging by a fifth, arms
      opposite the same-side leg) is what these are built on. Ankles are included, which
      `FlightConfig` omits — a flier's feet trail and nobody looks, a runner's feet are
      what touch the ground.
      Unlike flight, **no replication was needed at all**: `AssemblyLinearVelocity` and
      `Humanoid.WalkSpeed` already replicate, so every client derives every other
      character's gait from what it can already see. No remote, no attribute.
      The one thing `GaitController` could not copy from `TrainingPoseController` is its
      driver. That controller resets `startedAt` when the rep interval changes, which is
      right for a machine and catastrophic here, because the interval changes every
      frame as speed varies — it would restart the cycle sixty times a second and the
      legs would stand still while the body slid. The phase is accumulated instead, and
      accumulated from distance covered, so slowing down shortens the steps rather than
      moon-walking. Lean and vertical bob live in the controller rather than the poses:
      lean has to grow smoothly with speed instead of switching on with the sprint
      silhouette, and the bob runs at twice the stride frequency because a body rises
      once per step and a stride is two steps.
      Priority 7 makes it the weakest of the four pose controllers — it writes first, so
      training, strikes and flight all overwrite it — with explicit guards doing the
      same job directly. VFX: footfall dust fired on the cycle's own footfall phases,
      which is only possible because the cycle is ours, plus a sprint kick with
      `FlightBoom`'s hysteresis and ground speed lines turned well down from flight's.
      Verified live: hips in opposition, knees lagging, arms opposing legs, sprint
      driving to −107° knees against a walk's −52°, measured root lean matching
      `Formulas.RunLean` exactly, footfall and sprint effects spawning, and the gait
      standing down for flight, training and strikes and releasing to Roblox's idle.

- [x] 133. **The punch lands on somebody.** `Punch` was the only strike in the game with
      no VFX at all, and the victim of one showed no sign of being hit — a number
      appeared on their screen and their body did not move a joint. In a game whose hook
      is interrupting somebody mid-training, the person being interrupted was the one
      character in the fight not reacting.
      The fix is architectural before it is cosmetic. Every effect until now hung off the
      *actor* — a strike stamp, a guard, a flight state — but an attacker's swing is
      stamped before the server knows whether it will connect, so anything driven off it
      fires on a whiff. A Hard Punch thrown at empty air was already flashing a full
      impact against nothing. `CombatService` now stamps the **victim** with `HurtAt` and
      `HurtImpact` when damage actually lands, and impacts are driven from there;
      `HeavyImpact` moved off the swing onto that path, and mobs are stamped too.
      Escalation is an explicit weight rather than a function of damage, because for
      evenly matched players a jab is about two per cent of a health bar and every
      contact of a combo would have landed in the same band. `Punch` states 0.3 / 0.45 /
      0.8 across its three contacts, a heavy states 1, and a slam states its own falloff.
      `Formulas.ImpactTier` maps those to Light / Solid / Crushing, and the self-test
      asserts the combo's mapping so a retune cannot silently flatten it.
      `FlinchConfig` holds three victim poses, upper body only so a flinch never stops a
      fleeing player's legs, blended in fast and out slow. `VfxConfig` gains a graded
      `ImpactLight`/`Solid`/`Crushing` family and a new `Starburst` element — the manga
      impact frame, a ring of camera-facing neon spikes, on the finisher only. Taking a
      hit also pulses a screen vignette, deliberately a GUI frame rather than a
      `Highlight`, because `StationHighlightController` already documents that Roblox
      stops honouring Highlights past a few dozen and is using fourteen of them.
      Whether a flinch interrupts your own swing turned out not to be expressible as a
      controller priority: measured in Studio, a flinch stamped mid-swing won regardless.
      So it is a stated rule — a crushing hit interrupts, a lighter one does not — which
      is a better rule anyway, since "the flinch always loses" would have meant two
      players fighting each other never visibly reacted at all.
      `Punch` deliberately gains no knockback: contact range is 24 studs and the slowest
      knockback is 40 studs a second, so shoving on the first contact would carry the
      target out of reach of the other two and turn the combo into a one-hit move.
      Verified live: punching air produces the swing and zero impact effects, the three
      weights map to the three tiers with neck snaps of −6.9°/−16°/−30° and the starburst
      only on the last, jabs and crosses lose to your own swing while a finisher
      interrupts it, and a full combo peaks at 14 effect parts.

- [x] 134. **One click, one punch.** The normal punch was one click that played a
      0.9-second clip landing all three contacts by itself: the player pressed once and
      watched. The three-hit combo the HUD advertised was something the game did to you
      rather than something you did. Now each click is one swing, and clicking again
      inside a 0.6-second window chains jab → cross → finisher before wrapping back to
      the jab; stop, and the next click starts over.
      `StrikeConfig` gains `PunchJab`, `PunchCross` and `PunchFinish` and the old
      three-contact `Punch` strike is gone, so there is one definition of a jab rather
      than two that can drift. The poses are unchanged — these are the same coils and
      contacts the old combo walked through, regrouped one swing at a time, each now
      returning to neutral because a swing has to be able to be the last one. The
      finisher is longer and most of the extra length is recovery, so reaching the end of
      a chain visibly costs something.
      Damage is untouched in total. Each swing keeps its 25 / 30 / 45 per cent share, and
      three clicks span roughly the same 0.9 seconds, so DPS and time-to-kill are exactly
      where they were. The chain state lives inside `Punch.luau` in a **weak-keyed**
      table: an ability has no `PlayerRemoving` hook, that belongs to `CombatService`, and
      reaching in for one would put punch-specific knowledge into a system that
      deliberately has none — while a plain table keyed by `Player` would leak an entry
      per player for the life of the server.
      `StrikeController` gained a blend. It used to clear every joint to identity and
      start each clip from its own first pose, which was invisible while a strike only
      ever began from a body at rest; chained swings interrupt each other mid-recovery,
      and a click on the contact frame would have snapped a fully extended arm from 102
      degrees to zero in one frame. Each swing now eases from wherever the joint actually
      was — which improves every strike, not just the punch.
      The cooldown is deliberately *shorter* than a swing's clip (0.3 against 0.34) so the
      next click cuts the previous recovery. That broke the existing
      `Cooldown >= Duration` self-test's coverage silently — it only checks ids that
      match a strike, and no strike is called `Punch` any more — so the punch gets an
      explicit chain-aware assertion instead, pinned from both directions and against the
      remote's 8/sec rate limit.
      Verified live against a goblin: one click throws one swing, four fast clicks give
      jab, cross, finisher, jab, letting the window lapse resets to the jab, each swing
      lands exactly one hit, the impact weights arrive 0.30/Light, 0.45/Solid,
      0.80/Crushing, and a chained click reads 91° → 102° → 94° on the shoulder instead
      of snapping to zero.

- [x] 135. **The sprint was leaning backwards and windmilling.** #132 was authored blind —
      Studio's screen capture has been unresponsive all session, so every angle was
      reasoned from `PoseConfig`'s documented axes and verified only numerically. The
      numbers were right; two of the conventions behind them were not.
      **Root X is negative-forward.** That is not what the limb convention suggests, but
      every pose already in the game follows it: FlightConfig's glide is −26 and its
      cruise −62, and a strike's coils are positive while its contacts are negative,
      because a coil loads the body back and a contact drives it forward. `Formulas.RunLean`
      returned a *positive* value, so the character sprinted tipping backwards, further
      back the faster it went. The sign now lives in the formula rather than in a caller's
      memory, which is where it went wrong.
      **Shoulder Z is arm width**, and the sprint was wider than the walk. PoseConfig's
      lat pulldown uses 145 for arms straight out and `StairClimber`, the walk cycle this
      gait was built from, uses 10; the sprint had 16-18 against the walk's 12-14, so it
      held its arms further out than a stroll while swinging them through a 114 degree
      arc. Walk drops to 9-10 and sprint tucks to 5-6, with the arc trimmed to 104.
      The reason a blind mistake survived is that nothing tied the gait to the poses that
      already had it right, so `GaitConfig.RunSelfTest` now requires `FlightConfig` and
      asserts the two agree about which way forward is, plus that a sprint tucks its arms
      closer than a walk. Those encode the relationships rather than the numbers, and the
      first is the one check that would have failed on the shipped build — no amount of
      numeric verification could surface it, because every value was internally consistent.
      Verified live: walk leans -4.00 degrees with shoulder |Z| 9.99, sprint leans -16.82
      with |Z| 6.33. Screen capture is still unresponsive, so this is confirmed consistent
      with the working poses rather than confirmed to look right.

- [x] 136. **The gait becomes anime.** Re-authored from "heavy gym-bruiser" to an anime
      walk and run, in three parts.
      **Timing first.** `StrikeConfig`'s header already says "the anime read comes from
      the timing far more than the angles" — a cartoon motion holds at full extension and
      crosses between poses in two frames — and the gait was running on a pure cosine, the
      most symmetric and most *realistic* curve available. Anime poses on that curve still
      read as realistic. A third `MotionStyle`, `Snapped`, runs the cosine through the
      `smootherstep` helper already local to `PosePlayback`, so limbs dwell near their
      extremes and transit fast. Deliberately not a literal hold, which would read as
      dropped frames.
      **Three silhouettes instead of two.** A light bouncy upright walk, a shonen sprint
      with long strides and high knees, and a Naruto dash whose whole identity is the arms
      — swept back, elbows locked, barely cycling. `GaitConfig` asserts the dash keeps its
      shoulders negative at *both* ends of the cycle where the walk swings through zero,
      which is the difference between arms that trail and arms that pump.
      **The blend is now absolute, not per character.** It used to measure against each
      character's own `WalkSpeed`, which meant everybody sat at 100% the moment they held
      Shift — a fresh player jogging at 24 studs a second got the identical flat-out ninja
      run as somebody with forty Legs doing 64. Measured against the global 64-stud
      ceiling, speed means the same thing for everyone and **the dash is something Legs
      earns**. The lean also went quadratic and deepened to 40 degrees so the deep end
      arrives late, and the bob inverted — bouncy walk, gliding dash — which is the
      reverse of a real gait and required renaming its constants, since MIN/MAX had become
      lies.
      **A third convention bug, fixed structurally.** `FlightConfig` pairs Root -26 with
      Neck +20 and -62 with +46: the neck cancels the lean so the head stays level. The
      sprint had Neck -6 against a -18 lean, so it stared at the floor. Rather than
      hand-tune it again — hand-tuning is what produced all three of these bugs — the
      controller now derives the neck counter-rotation from the same number it leans the
      root by, and the self-test asserts no gait pose writes a head pitch at all.
      Verified live: walk leans -4.0 with the shoulder swinging -30..+33; a fresh sprint
      leans -5.0 with -58..+54 and -117 knees; top speed leans -37.1 with the shoulder at
      -75..-56, both ends behind the body. The neck cancels the lean to within 0.05
      degrees at every speed. Screen capture is still unresponsive, so this is verified
      numerically and against the conventions rather than visually.

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
| Core fantasy | 35 locations, seven unique exercises and exact +1/s–+64/s tiers per muscle, athletic muscle growth, Legs sprint/flight, PvP, reputation | A new player is not taught or directed through the fantasy |
| World | Massive bridge-free scattered archipelago, walkable water, interiors, third floors and skyline training, vector map, streaming-aware travel | The 35-pin map and long water routes still need human readability evidence |
| Progression | ranks, tokens, multipliers, two daily quests, one one-shot quest | no balanced first-hour path, mastery, weekly goals, comeback loop, or post-endgame purpose |
| Combat | authoritative Punch, damage, kills, bounties, safe zones; interruption settled as kill-only (#96) | only one ability — Slam/Dash remain planned; paid-peace fairness still open (Phase 26) |
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

- [x] 137. **Build artifacts stop being version-controlled.** `scripts/__pycache__` was
      tracked, so every run of a build script produced a spurious diff, and `default.rbxl`
      was sitting untracked in the root waiting to be committed by accident. Both are now
      ignored and the `.pyc` is untracked.

- [x] 138. **Your rank becomes a title people can read above your head.** `TitleService`
      turns the ranks in `RankConfig` into a *selectable* label rather than an automatic
      one: earning a rank unlocks its title, and the player picks which unlocked title to
      wear. It replicates as three plain Player attributes (`TitleId`, `TitleName`,
      `TitleColor`) so `NameplateController` and `TabBarController` render it without
      either of them requiring the service, and NPCs get the same attributes so a
      nameplate never has to ask whether it is looking at a player.

- [x] 139. **You pick the weight on the bar, and it decides the set.** Training was one
      fixed rate per machine; `WeightConfig` gives every district a bare-bar 0 kg state
      and ten authored increases above it. The world multiplier still owns the exponential
      curve — load is a smaller within-district bonus, so a heavier plate is never a way
      to skip a zone. Each step has its own stat requirement, and mastering a muscle's
      final load opens *that same muscle* in the next district, never a different one.

- [x] 140. **Legs buy you a dash, not just a top speed.** The dash is real physics at 78
      studs a second, which meant dashing through a crowd scattered it — a way to fling
      people off machines without throwing a punch, which is exactly the interruption rule
      #5 exists to prevent. `DashService` fixes it with a collision group rather than
      anything in the mover: dashing parts move to `Dashing`, which collides with the
      world and with nothing alive. It has to be server-side because collision groups
      replicate from the server and the shove is simulated on both machines. The client
      declares its own dash state, which is safe because the flag grants nothing except
      the ability to *not* push people.

- [x] 141. **Each district gets its own sky and light.** `LightingConfig` makes the grade
      data. The look was a warm, saturated, high-noon grade that washed distance to white
      and left asphalt reading as light grey; it is now GTA V — desaturated, cold shadows
      against warm light, blacks that reach black, and haze with weight rather than milk.
      `AtmosphereController` applies it per zone at runtime and is the authority, with the
      `Lighting` block in `default.project.json` mirroring `Base` so the Studio edit view
      and the first frame of a session are not a different game.

- [x] 142. **Quests become one endless rotation instead of a daily log.** Upper body,
      lower body, monsters, repeat forever — exactly one active at a time, with goals and
      rewards growing 1.6x a loop (the kill step more slowly, since a kill costs travel and
      a fight rather than time on a machine). This made the engine *smaller*: the daily
      model needed a UTC-midnight reset, a completions table and a "once" marker, all of
      which existed to answer "is this available again yet". A cycle never asks that — the
      active step is a position, not a date. Every quest's listener stays wired including
      the inactive ones, and `report` discards anything that is not the active quest, which
      is the single place the one-at-a-time rule lives.

- [x] 143. **Tokens live in MultiplierService, so CurrencyService goes.** A separate
      service holding one balance that only one system spent was indirection with no
      second caller. `BountyService` now credits through `MultiplierService` directly.

- [x] 144. **The muscle you are working lights up while you train it.** A highlight driven
      off `EquipmentConfig`'s muscle mapping, so a new machine gets the effect from its
      config row and `TrainingMuscleHighlightController` never learns another exercise.

- [x] 145. **The balance model catches up with the weights and the cycle.** The simulator
      and its extracted inputs were still modelling a game with no selectable load and
      three fixed daily quests, so every projection it produced was for a build that no
      longer existed.

- [x] 146. **The truth files describe the game that actually exists.** `PLAYTEST.md` was
      the launch gate and could not be run as written: it asserted 26 server systems and 20
      controllers (actually 32 and 37), one combat ability (actually three), four products
      (actually eleven), and quest ids that had been deleted. A launch gate that fails on
      its own stale facts teaches you to ignore it, which is worse than not having one.
      `PRODUCT_TRUTH.md` and `ALPHA_PROTOCOL.md` carried the same claims.

- [x] 147. **`./scripts/check.sh` passes again.** Step 1 of `PLAYTEST.md` is "all checks
      pass", and it had not been true for a while: six `--!strict` errors and a shadowed
      local survived in `UI`, `BodySkinConfig`, `BodySkinPainter`, `BodyLoftController` and
      `FullMapController`. All six were annotation gaps rather than logic bugs — an
      untyped `ROLE_ATTRIBUTES` and `validRegions`, `x ~= nil` against a non-nilable type,
      an unannotated `bounds` parameter — but a gate that always fails is a gate nobody
      reads, and it would have hidden a real error the day one appeared.

- [x] 148. **Impacts get layers, variants and a mix that ducks for them.** The previous
      pass filled thirteen ids and called it audio; one file per event is what makes a
      game sound cheap. A `SoundSpec` now carries `Variants` (several ids, one picked per
      play — reps and footsteps machine-gun otherwise, however much pitch jitter they
      get), `Layers` (sub-specs played together: a slam is a concrete transient, a sub you
      feel rather than hear, and the grit it throws up), `Group`, `Spatial` with rolloff,
      and `Cooldown`.
      **The mix is the part that does the real work.** `SoundBus` builds
      Master → Music / Ambience / Sfx / Ui once, and hangs a `CompressorSoundEffect` on
      Music and Ambience whose `SideChain` is the Sfx bus. Combat now pushes the music
      down by itself — nothing scripts it, nothing knows a fight is happening, and no
      sound had to be made louder to be heard over another. An `EqualizerSoundEffect` does
      the same job in frequency, giving up the music's low-mids so impacts have somewhere
      to sit. It is code rather than `default.project.json` because both the bus tree and
      the sidechain are instance references, which a Rojo project file cannot express.
      Also: `ContentProvider:PreloadAsync` on every id at startup, because the first punch
      of a session was silent while the asset streamed. `ContentProvider` had never been
      used in this codebase at all.

- [x] 149. **Every button in the game clicks, not the six that opted in.** `UiClick` was
      hand-wired onto six buttons across two controllers, so every other button in the
      game was mute — being heard was opt-in and nobody opted in. `UI.Pressable` is the
      one choke point every button already goes through, so the click belongs there.
      `UI.luau` lives in ReplicatedStorage and must not depend on a client controller, so
      it exposes `SetPressListener` and EffectsController fills it in; the six hand-wired
      calls are gone, along with MenuBarController's now-unused EffectsController handle.

- [x] 150. **The five sounds nothing was playing now play.** `Knockout`, `SlamWindup`,
      `SlamImpact`, `Purchase` and `Footfall` were fully configured and had **zero call
      sites** — pasting ids into them would have changed nothing.
      `SlamWindup` is renamed `SlamCharge` to match the cue name in `StrikeConfig`, and
      that rename is the mechanism rather than tidying: VfxController now plays the sound
      whose name matches the cue it is already drawing, so audio and visuals can be
      authored independently and still land on the same frame, and a future cue is audible
      for free. Footfall rides beside its dust in `PlayFootfall`; Purchase fires on the two
      buy paths in MenuController; Knockout comes off `humanoid.Died`.
      **This is also what made combat audible from outside.** Those handlers were already
      watching *every* character, because hit, guard and flight are attribute-driven and
      attributes replicate — so passing an emitter to each call was enough to hear an
      attacker behind you. The planned server broadcast turned out to be unnecessary: the
      replication needed already existed, and reusing it costs no new remote, no bandwidth
      and no trust surface. The Footfall cooldown is keyed per emitter for the same
      reason — a global key would let the nearest runner swallow everybody else's steps.

- [x] 151. **A soundtrack, and combat music that warns you.** `MusicEnabled` had been in
      the profile, the settings menu and the save file for months, wired to nothing —
      worse than a missing feature, because the player concludes the game is broken.
      One exploration track, one combat track that takes over on any hit and hands back
      six seconds after the last one, and a global ambience bed. Combat gets a whole track
      rather than a layer because fights here start without warning: a player locked into
      a machine cannot see who is behind them, and the music changing *is* the warning.
      Both tracks are created once and left playing for the session; a switch moves their
      volumes past each other and never starts or stops a Sound, so the combat track is
      already in its own bar when it fades up and the theme does not restart on the way
      back. The fade is a **Heartbeat clock, not TweenService** — a direct reading of the
      warning in `EffectsController:_showTrainingGain`: a tween captures its start value at
      `Play()` and a second tween on the same property cancels the first, which is exactly
      what "fade A down, fade B up, get interrupted halfway" does. Stepping toward a target
      each frame is interruptible by construction.

- [x] 152. **Three volume sliders replace two toggles that half worked.** `MusicEnabled`
      and `SfxEnabled` become `MasterVolume` / `MusicVolume` / `SfxVolume`, 0-100, driving
      the SoundGroup volumes so the mix is tunable live without a republish. Migration v9
      carries the old choices over — off becomes zero, on becomes the *authored* level
      rather than 100, so a returning player hears the game as designed rather than louder
      than everyone else — and explicitly clears the retired booleans, because Reconcile
      only ever adds keys and a forgotten one rides along in every save forever.
      `UI.Slider` is new and shared, shaped like `UI.Bar`. Its `OnChanged`/`OnCommitted`
      split is the load-bearing part of the API: dragging fires every frame, `Net` rate
      limits the settings remote to four calls, and `_refresh` would destroy the slider
      under the finger still dragging it — so the drag writes straight to the mix and only
      the release reaches the server.

- [x] 153. **A cosmetic controller could blank the whole client, and did.** Pressing Play
      gave a default blocky avatar, a default blue sky and no HUD — not a sound bug in
      effect, but the entire client failing to start.
      **The mistake.** `SoundBus` set `SoundGroup.SoundGroup` to nest the buses. That
      property does not exist: the class has exactly one member, `Volume`, and groups nest
      by *parenting*. `luau-lsp` reported it and it was silenced with a `:: any` cast —
      overriding the type checker to make a build go green is what turned a compile error
      into a runtime one. The cast is gone and nothing in that file needs `any`.
      **Why it cost the whole game.** `Loader.Ignite` called `error()` on any failed
      `Init`, which aborted ignition before the `Start` loop ran — so every controller was
      initialised and *none* was started: no UI built, no lighting grade applied, no body
      mesh. `Start` failures were already isolated with `warn`; `Init` now matches. A
      broken system loses its own feature and nothing else. The tradeoff is accepted and
      recorded in the file: a half-initialised system carries on, so a dependency it never
      resolved can resurface later as a confusing nil instead of as one loud failure.
      **A second bug found while auditing for the same class of error.**
      `emitter:GetDebugId()` in the footfall cooldown is PluginSecurity and cannot be
      called from a LocalScript; it had never executed only because MusicController
      (priority 6) died before EffectsController (priority 5) reached `Start`. The
      cooldown is now a weak-keyed table indexed by the emitter Instance, which is legal,
      collects despawned characters, and builds no string on the most frequent sound in
      the game.
      **And one caught only by running it.** Rewriting `SoundBus.Get` lost its `or "Sfx"`
      default, so every world sound routed to Master — where the sidechain compressors
      have nothing to duck against, silently disabling the ducking for sixteen of the
      twenty sounds. `check.sh` was green throughout all of this: the self-tests run
      outside Roblox, where `SoundGroup` does not exist. The lesson is the process one —
      a green static check is not evidence that the game starts, and this pass is verified
      by `Ignited 38 systems / 0 failures` and a bus assertion over every configured sound.

- [x] 154. **The combat audio stops being foley and starts being designed.** The sounds
      were bad, and for a specific reason worth recording: they were chosen by reading
      catalogue descriptions, because whoever writes this config cannot hear it. That
      produced a ground slam that was **a recording of a table falling over**, a block
      that was **a golf club hitting a pipe**, a block break that was **medieval
      manacles**, and four legacy `rbxasset://sounds/` defaults — `victory.wav`,
      `bass.wav`, `electronicpingshort.wav`, `switch.wav` — which every Roblox player
      recognises instantly and which made the whole game read as unfinished.
      **The real constraint, now named.** Roblox's free Pro Sound Effects catalogue is a
      *foley* library: props, doors, vehicles, room tone. There is no explosion set, no
      impact-design set, no UI set. Searching it harder was never going to produce a
      better ground slam, because a better ground slam is not in it. What it does have is
      good raw material — the "Fight – Hits / Meaty Thud" family is genuinely the right
      recording for a punch, and the Steel Door family (big hollow slams with long
      rattling decay) is the right one for everything heavy.
      **So the jump came from processing, which is how expensive audio is made anyway.**
      A `SoundSpec` now carries an `Effects` chain, and the game had been using none of
      the nine DSP units Roblox exposes. Two do most of the work: `Distortion` adds the
      harmonic bite that separates a hit from a thud, and `PitchShift` drops the body of a
      sound *without* slowing it — `PlaybackSpeed` does both, which is why the heavy punch
      used to be the sluggish one. Chains are restricted to the rare big moments and
      `RunSelfTest` refuses them on Footfall, Rep, UiClick and BlockAbsorb rather than
      trusting nobody adds one.
      **A layering bug only running it could find.** Layers do not declare `Spatial`, so a
      spatial impact was emitting its transient from the character and its sub flat from
      the listener — pulling the two apart in the stereo field, which is exactly the
      smearing the layering exists to prevent. Layers now inherit the parent's placement
      unless they override it. Verified live: a Hard Punch emits three sounds from the
      root at matching rolloff, and instance counts return to baseline afterwards.
      **And the actual fix for the root cause.** `AuditionController` (F9, Studio-only,
      gated like DevService) lists every sound with its layers and DSP, plays it exactly
      as the game does, and plays each alternate from `SoundCandidates` dry so a recording
      can be judged as itself rather than through a chain. The guessing loop failed twice;
      this puts someone who can hear inside it.

- [x] 155. **A corrupt schema version could lock a player out of their own save.**
      `Migrations.Apply` read `tonumber(data.SchemaVersion) or 1` and looped straight off
      it, so a stored version of `0`, a negative, a fraction like `3.5`, a string or a
      boolean indexed a step that does not exist and **threw inside the join path** — at
      `DataService.luau:105`, after the profile loaded but before it was registered. That
      player could not get in, repeatedly, with their profile still sitting in the
      datastore. The version is floored and clamped now, so anything below the first step
      means "migrate from the beginning" — which is also the right answer for a profile
      that predates versioning.
      **Steps are isolated, and a failed one is deliberately not stamped.** That second
      half is the one that matters: a profile marked current with only half its steps
      applied is corrupt *permanently*, because every later join skips what it still
      owes. Leaving it unstamped means the next join retries from where it stopped, so a
      bad deploy costs sessions rather than saves. DataService now kicks rather than
      letting a session run on half-migrated data and write the partial result back over
      a good save.
      **None of this was reachable in Studio**, which is the point: `USE_MOCK_IN_STUDIO`
      means every save in this project's history died with its session, so the live path
      had never once executed. Verified by feeding `Apply` the eight profile shapes a real
      DataStore can return — six of them used to throw, and a rollback case stamped far in
      the future is correctly left untouched.

- [x] 156. **A bad volume in a save no longer takes the audio down.** The three volume
      reads used raw arithmetic and comparison — `(settings.MasterVolume or 100) / 100`
      and `... <= 0` — both of which *throw* on a non-number rather than falling back. A
      corrupt or tampered profile would have broken audio init on exactly the saves least
      able to afford another problem. `SoundBus.ReadVolume` centralises it because there
      were three such sites and the fourth would have got it wrong.

- [x] 157. **The playtest gate records what was actually verified, not what was assumed.**
      Its client ignition count was stale again (37, actually 39 after MusicController and
      AuditionController). Section 1 is now ticked — and only section 1 — with every box
      read out of a live session rather than inferred: 32 server systems, 39 client, three
      abilities, eleven AssetId-0 warnings, zero station warnings, zero non-DataStore
      errors, 35 tagged zones, `check.sh` green and `validate_gym` at 35/35 against build
      `319220b972df`. The evidence block says plainly what that run does *not* prove: a
      machine can confirm the game boots correctly, and cannot confirm it is any good.

- [x] 158. **The shop sells something real.** Seven of the eleven products carried
      `AssetId = 0`, which is not a cosmetic gap: `PurchaseService` deliberately refuses to
      register a zero-id product, so every Robux card in the shop rendered "COMING SOON"
      and the whole Robux half of the economy was decorative. The three gamepasses (VIP,
      Fast Travel, Auto Load), both immortal potions, Pre-Workout and Protein Shake now
      carry their live ids from the Creator Dashboard. The four token packs stay at `0` on
      purpose — they have not been created yet, and the unavailable path is what should
      show until they are.
      `ShopIcons.luau` carries the uploaded artwork for those products plus the two
      currencies, and `Icons.Draw` consults it before falling back to the drawn glyph. That
      fallback is the point: a key whose upload has not happened renders exactly what it
      rendered before, so the artwork can land one id at a time without a broken frame in
      between. The asset rule in `CLAUDE.md` gains the same carve-out the body mesh has —
      our own images may be uploaded, the Toolbox still may not.

- [x] 159. **The dashboard sets the price, not the code.** #158 wired the live `AssetId`s
      and stopped there, which left every card quoting a number Roblox would not charge:
      VIP was advertised at 199 R$ against a real 699, Fast Travel 149 against 299, the
      1 day potion 79 against 199. Six of seven were wrong, and copying today's numbers
      into the modules would only have moved the drift to the next dashboard edit.
      `ProductInfo` caches `MarketplaceService:GetProductInfo` behind a 300s TTL, warmed
      off the request path at startup because that call yields and is rate limited. It
      never yields itself and never throws: a failed lookup falls back to the module's
      `RobuxPrice`, which is now documented as a fallback rather than a price.
      The same call carries `IconImageAssetId`, so the artwork attached to each product on
      the dashboard *is* the shop's artwork — no second copy to keep in sync, and the
      uploaded images shrink to the two currencies in `ShopIcons`. The token-priced
      supplements borrow their Robux twin's picture, because a Pre-Workout bought with
      tokens is the same tub; only Meal Prep, which has no product, keeps a drawn glyph.
      Verified live: catalogue returns 19/19/29/199/299/699/699 with an icon each, the
      four uncreated token packs return their fallback price and no icon, and a bogus
      asset id degrades to the fallback instead of erroring the shop.

- [x] 160. **Boosts are bought with Robux, not tokens.** The shop sold the same three
      supplements twice: once for Robux and once for Tokens priced in *minutes of income*,
      a rule that existed only so the two prices could not drift apart as physique classes
      doubled token income. Selling a boost for the currency the game hands out for free
      undercut the Robux half of the shop, so the token shelf is gone: `ShopConfig` and
      `ShopService` are deleted, `PurchaseShopItem` and `GetShopPrices` are off the wire,
      and Meal Prep — which never had a Robux twin — goes with them.
      Pre-Workout and Protein Shake now describe their own effect (3x/180s, 2x/600s) in
      their product files, since the config that held those numbers existed to keep two
      sellers of one item in agreement and there is only one seller now. The supplements
      shelf is recognised by an explicit id set rather than by "has a ShopConfig entry".
      Tokens keep exactly one sink: the five per-stat doubling paths.

- [x] 161. **A pass shows its price even to someone who owns it.** The card had one line of
      text for both price and state, and `OWNED` won — so every gamepass looked free to
      anybody who had bought it, the developer testing in Studio included, which is how
      the missing price was found. The price moves to its own label in the card's top-right
      and is drawn from the catalogue row regardless of what the button says; the button
      is now just `BUY` / `OWNED` / `COMING SOON`.
      Clicking START TRAINING also stopped firing `RankUp` — a metal hit with a 2.4 second
      reverb tail — at the exact moment the music and ambience fade in behind the curtain.
      Three loud things at once is what a player hears as one loud thing.

- [x] 162. **The immortal potion says how long is left.** A player bought an hour or a day
      of immunity and was told once, in a toast, at the moment of purchase; after a rejoin
      the shield's remaining length was unknowable, which is precisely what you need before
      deciding to stand in the open. A badge to the right of the summary panel shows
      `IMMORTAL {duration}` while the potion runs and hides itself at zero.
      No new remote: `ImmortalUntil` is an absolute epoch already riding every
      `ProfileChanged` push, so the client ticks it locally on a one-second clock. It
      formats with `NumberFormat.Duration`, the same function the purchase toast uses, so
      the badge and the toast cannot disagree.

- [x] 163. **The price rides the buy button.** #161 put it in the card's corner because
      `OWNED` was occupying the button, which is the one place a price is actually read.
      It goes back: the button says `BUY · R$ 699` whenever the product can be bought, and
      the corner label survives only for the cards whose button is already spent on `OWNED`
      or `COMING SOON`. A price is therefore always on the card and never on it twice — and
      the buyable cards get their full name row back, so "Immortal Potion (1 Hour)" stops
      truncating.
      Recorded because it will be asked again: a gamepass reading **OWNED in Studio is
      Roblox's answer, not a bug**. `UserOwnsGamePassAsync` returns true for all three
      passes for the account whose id is this place's `game.CreatorId`, and false for an
      unrelated user — a creator owns their own passes and cannot buy them. Every real
      player sees the buy button.

- [x] 164. **VIP is something other players can see.** The pass sold "2x every stat & vip
      title" and the title half did not exist — every title in the game was one of the nine
      power ranks, and VIP bought a multiplier and a daily potion that nobody else could
      notice. VIP is now a **selectable** title: it sits in the same list, unlocked by
      owning the pass instead of by Power, so an owner chooses between it and the rank they
      trained for rather than having one taken away.
      It lives in a second `specials` list rather than among the ranks, because `Get()`
      walks the ranks to decide what a player *is* — a VIP entry at `MinPower = 0` would
      have broken the ascending-order assertion and then handed the title to every player
      at zero power, pass or no pass. `RankConfig.IsUnlocked` takes an ownership predicate
      so the same rule serves both sides: the server asks MarketplaceService, the client
      reads the `VipOwned` attribute the grant sets.
      `TitleService` asks each title its own question and, importantly, still demotes: the
      old check compared Power, which a VIP title's `MinPower = 0` would always pass, so a
      refunded pass would have left the title on forever. The ownership call yields, so the
      saved title is published first and corrected a moment later rather than leaving a
      blank plate. In the selector, a locked VIP row says `GET VIP` and opens the Roblox
      prompt — the shop is one press away and an inert LOCKED button would waste that.
      The nameplate glow is a one-pixel stroke, not two: at 14px a two-pixel halo in the
      text's own colour closed the counters of the letters and "VIP" read as a gold blob.

- [x] 165. **Protection reads next to health, and the daily says when it returns.** The
      immortality badge from #162 sat beside the power strip captioned `IMMORTAL 57:33` —
      a word next to a potion bottle is the picture written out twice, and it was in the
      corner that must not reflow when a badge appears. It moves above the health bar,
      left edge and width shared with it, and shows the glyph and the bare time. Both
      answer the same question, so a player checking one is already looking at the other.
      The VIP daily claim button now counts down instead of inviting a press the server
      would refuse. The wait is the rest of the current UTC day — the exact rule
      `VipService.today()` implements — and not a rolling twenty-four hours, which would be
      a longer promise than the pass makes. `VipLastClaimDay` already rides the profile
      push, so the countdown costs no traffic. Its one-second loop exits on
      `IsDescendantOf(game)` rather than a Parent check: the settings page is rebuilt on
      every open, a destroyed row still reports its old parent, and without that guard each
      visit would leave another loop writing to a button nobody can see.

- [x] 166. **The immortality badge is a shield and a number.** What #165 actually put above
      the health bar was a white block next to a timer: the Potion glyph was drawn in
      `UI.Dark.Text`, near-white, at 24px, so the bottle's silhouette vanished into its own
      colour. It is now the same 🛡 the player list already puts beside an immune name —
      one symbol for one rule, wherever it appears, which is the only reason to mark it in
      two places.
      The `UI.Panel` went with it. A panel is a glass fill, a border and 10/12px of padding,
      which is also why the badge's offsets looked wrong — everything inside was inset by
      that padding. Two glyphs do not need a box drawn around them, and the health bar
      directly below already gives the corner an edge to align to. Both labels carry a text
      stroke instead, the trick the nameplate labels use for the same reason: pink on a
      bright sky is unreadable without an outline.

- [x] 167. **Token packs are sized in hours, not in tokens.** The worry was that multipliers
      would make a pack's number meaningless. They do not, and writing down why is most of
      this item: `AwardClassScaled` multiplies a pack by the buyer's physique class, so the
      figure in the module is a **Natural-quoted** one and the pack is worth the same
      stretch of progress at every stage. Two identities fall out of that, and they are
      what a pack should actually be tuned against — a pack is `TOKENS / 4` minutes of
      play, and because multiplier costs double at the same rate class income doubles, a
      pack of X buys `log2(X / 100 + 1)` successive multiplier levels whether a Natural or
      a Mythic buys it.
      Measured against that, the old ladder topped out at 6.7 hours for 299 R$, which is
      thin for a top tier. It is now Small/Medium/Large/Huge at 250 / 750 / 2,000 / 5,000
      tokens — about 1, 3, 8 and 21 hours of play, roughly 1.8, 3.1, 4.4 and 5.7 doublings
      — at 49 / 99 / 199 / 399 R$. Still not a route to the cap: one muscle costs 26.2M
      tokens to max and all five cost 131M, and those numbers scale with nothing.
      The modules are renamed to their sizes, because a file called `TokenPack400` that no
      longer grants 400 is how names rot, and the cards say the hours rather than a raw
      number a Mythic buyer would see multiplied by 512. All four keep `AssetId = 0`: they
      still do not exist on the dashboard, and the startup warning count (four, not eight)
      is what proves no orphaned module survived the rename.

- [x] 168. **A pack card names the number it will actually pay.** #167 sized the packs in
      hours and left the tokens invisible: the module carries a Natural-quoted figure,
      `AwardClassScaled` multiplies it by the buyer's class, and nothing on the card ever
      said what would land in the balance. A Mythic buying the Medium pack receives
      384,000 tokens, and the only way to learn that was to read the source.
      `Types.Product` gains an optional `TokenGrant`, the four packs declare it, and the
      catalogue row quotes `TokenService:ClassScaled(player, grant)` — the scaling split
      out of `AwardClassScaled` so the two now share it. That sharing is the point: a card
      that promises one number while the grant computes another is exactly the failure this
      arrangement rules out, the same reason a price and the charge for it are never
      worked out twice.
      Quoted server-side because the server owns the class; the client only formats it,
      with the same `NumberFormat.Format` the HUD counter uses, so `384K` means the same
      thing in both places.

- [x] 169. **A pack's quoted payout follows the class the frame it changes.** #168 quoted
      the figure server-side, which meant it was only as fresh as the last catalogue round
      trip. The row now carries the Natural-quoted `TokenGrant` and the client scales it
      through `MuscleClassConfig.ScaleTokens` — the same function `TokenService:ClassScaled`
      now calls, so the quote and the grant still cannot disagree. The shop already
      re-renders on every `ProfileChanged` push, so a physique transformation moves the
      number with no RPC in between.
      That re-render exposed a fault worth more than the feature: `GetProductCatalogue`
      called `UserOwnsGamePassAsync` once per gamepass with no caching, and it runs on
      every profile push — a token tick, a rep. A player who left the shop open while
      training was firing three uncached web requests a tick at Roblox's rate limiter.
      Ownership is now cached for 60 seconds per player per pass, cleared outright when a
      purchase completes so a fresh buyer sees `OWNED` immediately, and dropped on
      `PlayerRemoving` so the table does not grow with the session. A *failed* lookup is
      deliberately not cached: holding a VIP out of their own pass for a minute because one
      request timed out is worse than asking again.
      Measured: a catalogue call after the TTL lapses costs 84ms, the one immediately after
      it 50ms.

- [x] 170. **The ground slam stops clattering.** The table was never actually removed. The
      lead had been swapped to a steel door hit and the comment above the entry said so,
      but `rbxassetid://9126090979` — which `SoundCandidates` describes in its own words as
      "table falling on concrete (the old one)" — was still mixed in as a layer at half
      volume. A table on concrete is a handful of small wooden knocks spread over two
      seconds; under a steel hit that is not weight, it is noise with the wrong grain, and
      it is what the slam still sounded like.
      The layer is cut and the sub raised from 0.9 to 1 to carry what it was pretending to
      add. The pitch, distortion and reverb are deliberately untouched: those are what
      would make a slam sound *warbly*, not clattery, and changing four things at once when
      only one of them can be heard makes the next report impossible to act on.
      The lesson is the comment now carried in the file: **check the layer list.** A lead
      swapped without pruning what is mixed under it leaves the old sound audible while the
      entry looks correct, and a comment claiming otherwise is how it survived two passes.
      No licensing change — all three remaining ids are the same ProSoundEffects recordings
      already in use, and this only removes one.

- [x] 171. **The token packs go on sale.** #167 sized them in hours and #168 taught the card
      to quote what it will actually pay, but all four still carried `AssetId = 0`, which
      `_loadProducts` reads as "does not exist yet": four startup warnings, `Available =
      false`, a `COMING SOON` card that cannot be clicked, and a `PromptProduct` that
      refuses. The dashboard products now exist, so the ids are pasted in — Small
      3709886043, Medium 3709886078, Large 3709886119, Huge 3709886164 — and every one of
      those gates opens on that one field.
      No shop or receipt code changed, and that is the point: the buy button, the live
      price label, the class-scaled `≈ N TOKENS` line and the `PurchaseId`-keyed idempotent
      grant were all built to work the moment an id was real. A feature that needs edits in
      five files to turn on was not finished when it was written.
      Managed pricing is deliberately **off** on all four. With it on, Roblox may move the
      price per region or per experiment, and a pack whose whole pitch is "this many hours
      for this many Robux" cannot have the second half drift underneath the first. The
      module's `RobuxPrice` stays at 49/99/199/399 as the pre-warm fallback only — the
      figure on the card comes from `ProductInfo`, which reads the dashboard at runtime.
      The header comments that said the id "must be set from the Creator Dashboard" are
      rewritten rather than left, because a stale instruction to do something already done
      is how the next reader concludes the file is broken.

- [x] 172. **The supplements say what they are doing.** #169 gave the immortal potion a
      badge because a shield of unknown length is the one thing you need to know before
      standing in the open. The Protein Shake and Pre-Workout had the same hole and a
      shorter fuse: a Pre-Workout burns in three minutes, and the only thing that ever
      told you it was running was the toast at the moment of purchase.
      They now sit in the same corner — 🥤 `x2` and ⚡ `x3`, the multiplier at TextSize 20
      and the clock at 16, because what a player checks mid-set is *whether* they are
      boosted; how long is the follow-up question, and sizing them the other way round
      makes the badge read as a timer with a decoration rather than a buff with a timer.
      Three pinned badges do not work — each hard-coding its own Y offset is fine for one,
      but hiding the middle one leaves a hole — so the shield moved into a bottom-aligned
      `UIListLayout` and the rows re-flow instead.
      **They stack, and the badge now says so.** `GetMultiplier` has always been a product
      over live modifiers, so both at once was already x6; nobody could see it. A `⚙ x6
      TOTAL` row appears once more than one boost is live, and hides at one, where it would
      only restate the row above it. Leaving players to multiply two chips in their head is
      how a stacking bonus goes unbought.
      **The bug found on the way is the bigger half.** Boosts lived only in the in-memory
      `StatService` table, which is dropped on `PlayerRemoving` — buy a ten-minute shake,
      disconnect at two, and you paid Robux for nothing. A visible countdown would have
      made that worse, vanishing mid-count. `BoostUntil` is now an absolute epoch map on
      the profile, exactly as `ImmortalUntil` already was, restored into the modifier stack
      on `ProfileLoaded`; the profile is the durable record and the modifier table is a
      cache. That is also what lets the badge tick with no remote of its own — it rides
      the existing ProfileChanged push, which is the whole reason the immortality badge
      was free to build.
      Re-buying now **extends** rather than resets, matching `ImmortalityService:Grant`.
      It used to overwrite, silently binning the nine minutes you had already paid for.
      `GrantGlobal` returns false when the write fails so ProcessReceipt leaves the receipt
      unconsumed and Roblox retries, rather than charging for a boost that never landed.
      Permanent boosts stay off the profile on purpose: those are gamepasses, re-granted
      each join from the ownership check, and persisting them would give a revoked pass a
      second life.
      The numbers moved to `BoostConfig` in ReplicatedStorage, because the HUD has to read
      a multiplier and a glyph and a client cannot require a product module. A third
      supplement is now a row in that table plus a product module — neither the HUD nor
      BoostService names a boost, they both iterate it.
      Row order is sorted by multiplier, not hash order. `for id in BoostConfig.Boosts`
      put the rows in a different sequence from one session to the next, which is exactly
      the kind of instability a player reads as a bug.

- [x] 173. **The VIP daily claim moves to the card that sold the pass.** It was a row in
      the Settings tab, which is not where anyone goes after buying VIP. It now sits beside
      the VIP card's own button in the shop: `OWNED` and `CLAIM` share the action row,
      split horizontally because the card is 108px and the description already runs to
      y=70 — there is no second band to put a button in without resizing every cell in the
      grid. `productCard` takes an optional `secondary`; nil renders exactly what the other
      eleven products rendered before, which is the only acceptable blast radius for a
      change to the one function every card goes through.
      Only an **owner** sees it. Offering CLAIM to someone who does not own the pass is an
      invitation to be refused. Which products carry a daily lives in a `DAILY_CLAIMS`
      table rather than an `if product.Id == "Vip"` branch, so a second entitlement is a
      row there and nothing else.
      **The "18 hours" was not a bug.** The daily resets on the UTC calendar day —
      `VipService.today()` is `os.date("!%Y-%m-%d")`, and the header has always called the
      trade deliberate: claim at 23:59 and you can claim again at 00:01. Eighteen hours was
      the honest time to the next UTC midnight. What was wrong was the wording: `READY IN
      18:00:00` reads as a broken twenty-four hour timer because it never says what it is
      counting toward. It now says `RESETS 18:00:00`. The rule is unchanged and the comment
      explaining it moved with the code, which is what stops the question being re-asked.
      **The bug found on the way is the one worth keeping.** `_renderShop` yields on
      `GetProductCatalogue`, and `_refresh` clears the body and re-renders. A profile push
      landing during that round trip cleared the body under a render that was still in
      flight; the stale render resumed and appended its shelves to the new page, and the
      shop came back with every shelf twice. Claiming is the reliable way to hit it — it
      marks the profile dirty *and* refreshes — but any push at the wrong moment would
      have done it, and this was latent long before the claim button existed.
      Fixed with a `renderGeneration` counter bumped on every clear: a yielding page
      captures it on entry and drops what it built if the number moved underneath it.
      `_renderLeaderboard` yields the same way and gets the same guard. Verified in Studio
      by claiming and counting sections — four, not eight.

- [x] 174. **The settings page stops lying about the controls, and the sliders earn their
      place.** Two jobs on one screen.
      **The controls text was wrong in almost every clause.** It claimed `F punches` — F is
      Block, and Punch is the left mouse button with no key at all (`AbilityConfig.luau:71`
      says so on purpose). It claimed `Q flies` — Q is the ground slam, and flight is a
      double-tapped Space gated on Power. It claimed holding the mouse trains the selected
      hotbar muscle, a feature whose buttons are destroyed the frame they are built
      (`HudController.luau:700-704`). It called Shift a sprint hold when it is a toggle, and
      it never mentioned C, R, Escape or Tab.
      None of that was a typo. It is what a screen does when it restates a config in its own
      words: the config moves and the sentence does not. So the sentences are gone. Combat
      rows are generated from `AbilityConfig.Ordered()` — `DisplayName` for the action,
      `KeyCode` for the cap, `LMB` where the key is nil, `(hold)` where `Kind == "Hold"` —
      and movement keys come from `MovementConfig`. A rebound ability is on this page with
      no edit, and a wrong key here now requires the game itself to be wrong.
      Presented as keycaps in a two-column grid, with `KEY_CAPTIONS` translating enum names
      into what players call them: nobody is looking for a key called LeftShift. The row
      grows with `AutomaticSize` rather than the old hard-coded 112px, because a list that
      comes from a config can gain an entry.
      **`1`-`5` are deliberately not listed.** They still call `_select`, but it only paints
      `slotButtons`, which is cleared when the dock is destroyed — so the keys do nothing
      visible. Documenting a dead key is worse than omitting it. The dead `_select` /
      `_beginManualTraining` / `_trainPing` path is left standing for a separate change.
      **The sliders got the polish.** They were already drag sliders; what they lacked was
      any sign of being draggable. A bare filled bar reads as a progress meter — something
      the game is telling you — rather than a control. So: a stroked knob riding the fill,
      a three-stop gradient and a top-edge shine borrowed from the HUD stat chips, a track
      stroke so the empty half still reads as part of the control, hover and press scaling
      on the existing `PRESS_IN`/`PRESS_OUT` curves rather than a new easing, and a `%` on
      the readout, which said `72` and could have meant anything. Knob travel is inset by
      its own radius so it sits inside the trough at 0 and 100 instead of hanging off.
      **Fixed a leak while in there.** `UserInputService.InputEnded` was connected once per
      slider at construction and never disconnected, so every rebuild of the settings page
      leaked a listener for the session. It is bound on the way down and dropped on the way
      up, so no global listener exists at all while nobody is dragging.
      **Wheel-to-nudge was built and then removed.** Every slider here lives on a scrolling
      page, so the wheel both moved the value and scrolled the list under it — measured, one
      notch of three went to the page. A control that quietly changes a player's audio while
      they scroll past it is worse than one that only answers to a drag. The comment saying
      so stays in the file, or it gets added again.
      Verified in Studio by dragging: 70% to 30%, one server write on release (`UpdateSetting`
      is rate limited to four), the value still 30% after leaving the tab and returning.
