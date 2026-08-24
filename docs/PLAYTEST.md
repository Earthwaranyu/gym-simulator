# Playtest & Launch Checklist

Everything static is already enforced by `./scripts/check.sh` — build, lints, and
`--!strict` types, plus `python3 scripts/validate_gym.py` for the generated world. This
file covers what only a running game can answer.

Counts and behaviors here are taken from [`PRODUCT_TRUTH.md`](PRODUCT_TRUTH.md) v16. If a
step below contradicts that file, the step is stale — fix it.

Run a **two-client Studio playtest** (Test → Clients and Servers → 2 players) unless a
step says otherwise.

---

## Evidence status

**Verified in a live Studio session (2026-08-07, MCP-driven, single player), against the
*previous* 9–10 station gym:** server boot, module self-tests, proximity auto-training,
combo and token accrual, muscle deformation, all five ScreenGuis, analytics funnel and
economy events. Two real bugs were found that way — a DataStore error aborting server
boot, and gym zones tagged on floor slabs so tokens never accrued.

**Explicitly *not* carried forward.** The world has since been rebuilt twice (commits
`57edbb3`, `9830780`) and now again into a **35-location, seven-tier coastal mainland
with one tier per yard along a single promenade**. Flight is enabled from spawn and
training interruption is **kill-only**. Every
box below is therefore unchecked: the old session is context, not evidence.

**Two standing caveats from that session.** Poses were verified by *measuring* joint
positions, not by watching them — `screen_capture` does not work while playing, so the
animations still want a human's eyes. And proximity prompts never render in an MCP-driven
session, so the hold-E mount path has **never** been exercised by any automated run.

**Never verified at all:** anything needing two players (PvP, kill-dismount, kill feed,
bounties), real DataStore persistence, Robux purchases, flight and Fast Travel at scale,
and whether any balance number feels right.

---

## 1. It boots

- [ ] `wally install` then `./scripts/check.sh` — all checks pass.
- [ ] `python3 scripts/validate_gym.py` reports **35 destinations / 35 usable stations, 7 tiers × 5 muscles / 35 unique exercises** and a build hash.
- [ ] `rojo serve`, connect the Studio plugin, press Play.
- [ ] Output shows `[Loader/Server] Ignited 32 systems` and `[Loader/Client] Ignited 37
      systems`. A lower number means a system failed to load silently.
- [ ] Output shows `[DevService] Studio session — dev commands are ACTIVE`. This warning
      must **never** appear on a live server.
- [ ] Output shows `[CombatService] Loaded 3 abilities` — Punch, Ground Slam and Hard
      Punch. Dash is its own service, not an ability.
- [ ] No red errors in Output. No station warnings — every one of the 35 destination
      models must resolve its definition, all three physical copies, their `TrainAnchor`
      spots, and one prompt per copy.
- [ ] Expected warnings, and only these:
  - `[DataService] Studio session using the MOCK store` — see step 7 before launch.
  - `[PurchaseService] "..." has AssetId 0` — one per product, eleven total, see step 8.
  - `[LeaderboardService] Studio session` — global boards need API access.

## 2. Training loop

- [ ] On a fresh profile, mount each Muscle Beach machine. The selector begins at
      `BARE / 0 KG`; no held plate or weight-stack slice is visible.
- [ ] On Alternating Dumbbell Curls, the player holds only the chrome iron handles
      at 0 kg. The list reads `+10 KG` through `+100 KG`; choosing a row swaps both
      ends to that complete symmetric Olympic plate configuration.
- [ ] Confirm the selector states whether the displayed number means `EACH HAND`,
      `MACHINE RESISTANCE`, or `TOTAL ADDED LOAD`.
- [ ] Train until another load becomes available. The guidance names its exact kg and
      its preset row turns green with the word `RECOMMENDED`; after selecting it, the
      guidance shows the exact muscle-stat requirement for the next step.
- [ ] Confirm unavailable rows state `NEED … ARMS/CHEST/
      BACK/CORE/LEGS`, and the current row says `CURRENT` without relying on colour.
- [ ] Check free weights at +10, +20, +30, +50, and +100 kg. Plate pairs are symmetric,
      the heaviest plates are nearest the grip/bar, and colors match the authored
      denominations: 25 red, 20 blue, 15 yellow, 10 green, 5 white, 2.5 red.
- [ ] On every selectorized cable machine, choose a non-zero load. The selected stack
      plates rise together and return smoothly once per repetition; unselected plates
      remain parked and hidden.

- [ ] Walk up to any station. A "Hold E to …" prompt appears. **Still the one step with no
      automated evidence behind it at all** — prompts do not render in MCP sessions.
- [ ] Hold **E**. You are placed on the machine, locked there, and start repping.
- [ ] Start a three-player local server. Put all three players on different copies of
      one muscle court at once; each prompt mounts its own copy, each load animation
      stays on that copy, and each player dismounts beside the copy they used.
- [ ] Try to put a fourth player on a dumbbell rack, pull-up rig, or any other court.
      Every visible equipment copy has exactly one prompt/seat: three copies means
      exactly three simultaneous players, never extra invisible capacity.
- [ ] Visit the rear-right shop in all seven active campuses. Each has exactly one
      Shopkeeper; holding **E** shows `Browse Shop` and opens the existing Shop tab.
- [ ] You spawn in the safe-zone bubble, not loose on the gym floor.
- [ ] The trained stat climbs in the HUD; total power climbs with it.
- [ ] Time the floating stat awards on a fast animation (Stair Climber, 1.3s), a
      middle animation, and the slowest (Deadlift, 2.2s). All three award once at the
      end of each visible exercise cycle. The amount is proportional to its duration,
      so their measured per-second progression remains equal. Repeat across all five muscles.
- [ ] Hold each of the five bottom stat cards while unmounted, using mouse and touch.
      The pressed stat popup lands once per completed visible rep; its amount equals
      that rep's duration at x1, preserving exactly +1 per second before owned multipliers,
      even if selection changes during the hold. Holding world-space left mouse trains
      the selected card by the same rule. Release before the next second: no delayed
      reward appears. Mount a machine without releasing: only the machine award
      continues, with no second manual payout stacked on it.
- [ ] Mount an x1 starter machine normalized to 1/s with no owned multiplier. Every
      tick adds exactly +1; the manual +1 does not stack underneath it. At 10 kg the
      load bonus reaches 2x, seamlessly matching the next district's 10 kg minimum.
- [ ] For one muscle, progress from 1 to 10 kg. At 100 of that stat its next district
      opens; the other four muscle routes stay locked until their own stat reaches 100.
- [ ] Type `/autoload` in Studio. Ownership and Auto Load both turn on and the selected
      load follows the server recommendation each tick. Type it again to turn both off.
- [ ] Watch one uninterrupted set. Ticks 1–49 stay at the same whole rate; tick 50
      activates the clearly labelled full-set x2. There are no fractional 2% steps and
      no unexplained alternating +1/+2 changes in the visible stat.
- [ ] Repeat machine and manual training across Arms, Chest, Back, Core and Legs. Every
      muscle gets the same icon-coloured `+amount Muscle` card. Each card is gone before
      the next one-second tick; force closely timed packets and verify the new card
      replaces the old instead of stacking above it.
- [ ] Keep Info open during several training ticks. After every tick, top-left Power,
      Info Power and the local top-right roster Power show the same number—never N,
      N and N−1. Other players may still refresh on the public one-second roster clock.
- [ ] The combo readout rises the longer you stay on.
- [ ] **Hold E again** to dismount. Then remount and **press Space** — that must also
      dismount you (`StopTraining`). Then remount and **jump** — same. All three paths work
      and the combo resets on each.
- [ ] **Watch the pose on all 35 exercises.** Angles in `PoseConfig` are the
      thing most likely to look wrong: you should lie *on* the bench not through it, hang
      *from* the bar not above it, and limbs should bend the way a body bends. Tune in that
      one file.
- [ ] Walk between all three physical copies of dumbbell curls, pull-ups, and several
      ordinary machines. Every copy's own prompt and billboard reads `1/1 free`.
      Mount one: only that copy becomes `0/1 free`; the other two remain `1/1 free`.
      A second player is refused at the occupied copy but can mount either free copy.
- [ ] Billboards show each machine's stat and its per-second rate.
- [ ] Locked stations read "Locked" with their relevant muscle requirement until met.
- [ ] Free-weight discs, dumbbell heads and cable-stack slices visibly respond to the
      selected load. Pull-ups/dips/rope work use a belt and hanging chain; sit-ups and
      back extensions hold a plate at the chest; weighted push-ups/planks carry a back
      plate. Nothing remains parked at the rack once it should be attached to the body.
- [ ] Your muscles visibly thicken as stats climb. **Watch the joints at high scale** —
      limbs stay in their sockets and the character stands on the floor rather than sinking.

## 3. PvP and the hook

The rule under test: **a hit does not dismount; only death does.**

- [ ] Player B presses **F** near player A. A takes damage; both see feed lines.
- [ ] The local bottom-left health bar is visibly large and its centered current/max
      values remain readable. Other players' overhead bars are also large enough to
      read both values during combat; test ordinary, million, and billion-scale HP to
      confirm suffixes fit without clipping.
- [ ] Hit A *while A is training*. A **stays on the machine**, keeps repping, and keeps the
      combo. Only the health bar moves. If A pops off on a hit, `CombatService` has
      regressed to the old stagger behavior.
- [ ] Keep hitting until A dies. **Now** A is dismounted, the combo resets, and the kill
      feed fires. This is the whole game — if committing to the kill does not feel worth it,
      that is a balance finding for step 10, not a bug.
- [ ] A mounted player cannot dodge — B can walk up and swing freely, and A is genuinely
      stuck rather than sliding under the hit.
- [ ] Stand within 18 studs at the side of or slightly behind another player and click
      without aiming the camera at them. The nearest living player is hit. Repeat with
      the client target briefly unavailable; the server fallback still acquires the
      nearby player instead of producing an empty swing.
- [ ] A hit **grounds** a flying victim; they cannot simply fly off mid-fight.
- [ ] Set both players to 1K Arms/Chest/Back/Core. Equal defense neither blocks nor
      reflects: the punch lands for the full 1K against 10.1K HP.
- [ ] Against 1K Arms, verify documented Back bands: 1K blocks 0%, 1,001 through
      9,999 block 10%, and 10K blocks 100%.
- [ ] Against 1K Arms, verify documented Core bands: 1K reflects 0%, 1,001 through
      9,999 reflect 10%, and 10K fully nullifies the direct hit. The full counter is
      at least `100 + Core`, bypasses Back, and does not reflect again.
- [ ] Give defender `/power 1000` and attacker `/power 0`. The defender has 200 Core;
      the attacker's one-damage punch is nullified and returns 300, instantly killing
      their 100-HP character. The defender receives reflection KO credit.
- [ ] Reflected damage bypasses the attacker's Back and cannot trigger another Core.
      Let it kill the attacker and confirm the defender receives KO credit and one
      Fight Token (unless the anti-farm window suppresses the reward).
- [ ] A reflected hit shows `REFLECTED` / `CORE RETURN`, but never displays the reflected
      numeric damage as a floating number.
- [ ] A respawns after ~4s with stats and tokens **fully intact**.
- [ ] Both players' kill/death counts update in the tab bar.
- [ ] Inside the spawn safe zone, damage is nullified for attacker and victim both.
- [ ] Kill the same victim twice inside 2 minutes: the second kill lands but pays no Fight Tokens
      and no reputation, and shows "no reward for farming".

## 4. Movement, flight, and travel

- [ ] Flight is available **from spawn** — no unlock gate.
- [ ] Ordinary walking stays at 16. Hold **LeftShift** to sprint: a fresh player reaches
      24 and Legs increases it toward the 64 cap. Releasing Shift returns to 16.
- [ ] **Q** toggles flight. **Double-tapping Space** while grounded also takes off.
      **Space** ascends and **LeftControl** descends once airborne — confirm a double-tap
      in the air does not land you, and that Space still dismounts a machine.
- [ ] Flight follows the camera: pitch down and hold forward, you dive; pitch up, you
      climb. Velocity should track the camera's look direction, not the horizon.
- [ ] The character stays **upright and facing its heading** the whole flight. Any
      tumbling or continuous spin means the `AlignOrientation` regressed.
- [ ] Clip a building mid-flight and confirm it does not start the rig rotating.
- [ ] Higher Legs visibly raises both sprint and flight speed. Fresh flight is 40 rather
      than the old 140-stud launch; even maximum Legs never exceeds 120.
- [ ] Fly between distant districts with StreamingEnabled on — machines must not pop in
      late. If they do, raise `StreamingMinRadius` in `default.project.json`.
- [ ] Walk the promenade from spawn to the far end without flying. One landmass, one
      paved path, sea on the left the whole way. Visible land spans 5,200 × 2,600 studs
      inside the 10,000 × 9,000 foundation.
- [ ] Confirm each yard holds exactly one multiplier tier — all five muscles of that
      tier and nothing else — and that the tiers ascend as you walk east: Iron ×2 at
      x=600, then ×4, ×8, ×16, ×32 every 600 studs, Storm ×64 at x=3,600.
- [ ] Stand in one yard. Five mats alternate either side of the painted lane, cover
      blocks around each, chain-link fence on both long sides, gate arches at both ends.
      A trainee must stay visible and shootable from the path and from the next mat.
- [ ] Step down the shore stairs and walk on the water. The character stands at root
      Y≈-4.5 on Glass, can sprint 16→24+ with Shift, and can climb back out at either
      of the two step flights without flying.
- [ ] Try to reach the Storm deck on foot. There must be no ramp, stairs or shore steps:
      it floats at 300 studs over the end of the promenade and only flight gets there.
      Fly at its open ends fast enough to overshoot — the ForceField rails must stop you
      rather than dropping you 300 studs.
- [ ] Look up from the launch ring at the end of the path. The beacon mast and lamp must
      make the deck findable without already knowing it is there.
- [ ] Dive into the water while flying. The avatar must stop with its root at or above
      Y=-4.5, never pass beneath the surface, and remain flying/controllable.
- [ ] Fly into every outer edge at maximum Legs speed. The persistent wall and safety
      envelope must keep X within ±4,790 and Z within ±4,290; the player cannot leave the
      ocean or fall into the void.
- [ ] Click the minimap. The full map opens as its own wide modal with **no**
      Info/Shop/Settings tabs, Train list, or vertically scrolling page around it.
- [ ] The map uses a clearly dark slate wash while every district, road and building
      remains legible. All **35** coloured location circles are present and
      selectable; locked locations remain visible rather than disappearing. Every
      circle shows an unambiguous muscle code and its exact multiplier (`AR ×1`,
      `CH ×8`, `CO ×16`, etc.).
- [ ] At the default zoom, pins sharing a neighbourhood form a tidy ring rather than
      covering one another. The five starter pins around the Hub are all individually
      readable and clickable before zooming in.
- [ ] Zoom at the centre and edges, then pan. The map sheet remains hard-clipped inside
      its left viewport and never covers the destination sidebar or modal chrome. The
      Arms/Back/Chest/Core/Legs legend stays fixed and readable at the viewport's top
      left at every zoom and pan position. No pale building, land or safe-zone shape
      appears outside the map rectangle—including shapes touching all four edges.
      Geometry crossing an edge is hidden before rendering, so this remains true even
      if Studio runs the legacy rotated-clipping path.
- [ ] Scroll up over the board to zoom in and scroll down to zoom out. The page must
      never move because there is no page scroll. Verify the +, − and reset controls,
      mouse drag, touch drag, and touch-friendly zoom buttons as well.
- [ ] Drag the map repeatedly, including releasing the mouse over the panel edge and
      dimmed background. The map must stay open. Only **X**, **Escape**, or **M** closes it.
- [ ] On open, each muscle highlights its own highest unlocked tier. Set Arms to 100
      and leave the other stats at zero: Arms ×2 becomes current while Back, Chest,
      Core and Legs remain current at ×1. Earlier and future pins stay readable.
- [ ] Pan and zoom, then select several circles. Only the manually selected circle
      receives a thin light outline, and the sidebar updates without resetting the
      current map view. Selection must not change the per-muscle current-tier pins.
- [ ] The selected-location sidebar shows machine, muscle, gain rate, access type,
      required relevant muscle stat, and two distinct actions: **TRACK** and **TELEPORT**.
- [ ] Run and fly through scenery — containers, palms, bollards, kerbs. None of it
      blocks you. Buildings, ground and platforms still do.
- [ ] **Without the Fast Travel pass**, Teleport visibly reads
      **LOCKED · GET FAST TRAVEL**. Clicking it opens the purchase flow (or the
      configured-AssetId warning in development) and never moves the character.
- [ ] Click **TRACK** on that same destination. A beacon appears with a live distance,
      an arrow points to it whenever it is off-screen, and the map closes. Walk/fly
      there and confirm it clears within ~26 studs with an "Arrived" toast.
- [ ] Turn around — the arrow must point behind you, not at the mirrored side of the
      screen.
- [ ] Die while tracking. The beacon survives the respawn (it is rebuilt on the new
      camera).
- [ ] **With the pass** (`/fasttravel` in Studio), Track remains present and Teleport
      becomes a separate active button. Teleport across the map and confirm you land
      intact and mounted to nothing.
- [ ] With the pass, select a location above your Power. Track remains available but
      Teleport reads **LOCKED · NEED MORE POWER**; a forged Travel request is refused
      by the server too.
- [ ] Die mid-flight and mid-travel. You respawn cleanly with no stuck camera, no residual
      velocity, and no half-applied travel.

## 4b. Finding a machine (full map)

- [ ] Use the stat-coloured circles and legend to find exactly seven destinations for
      each muscle. The code identifies Arms/Chest/Back/Core/Legs and the second line
      prints the multiplier. Across each muscle they represent x1, x2, x4, x8, x16,
      x32 and x64.
- [ ] Select one location from every muscle. The sidebar icon, colour, machine name,
      gain rate and access description must all change to the selected destination.
- [ ] Unlocked circles use their muscle colour. Locked circles remain selectable and
      the sidebar shows the correct Power shortfall rather than an active Teleport.
- [ ] The right-side **MAIN GOAL** card defaults to the training objective (`Gym Rat`), shows
      live progress/reward, and its **QUESTS** button opens the complete quest list. It must
      not choose the multiplayer knockout objective for a fresh solo player.

## 4d. Body and growth

- [ ] Every player has the same asset-free uniform on spawn: no shirt or accessories,
      current physique-class body colour, and dark shorts (the R15 UpperLegs) over
      class-coloured shins. Join with an avatar wearing a hat and confirm it does not appear.
- [ ] Train **one** muscle and confirm only its parts grow: Chest → chest/UpperTorso,
      Arms → both arms, Back → upper-back/UpperTorso, Core → abs/waist, Legs → both legs.
- [ ] Definition follows the trained group: Arms creates deltoids/biceps/triceps/forearms;
      Chest creates paired pecs but no lats; Back creates lats/traps but no pecs; Core
      creates six abdominal blocks and obliques; Legs creates quads, hamstrings and calves.
- [ ] While training, only that anatomical group carries the white cue: the supporting
      R15 part is faint and its sculpted contours are bright. Releasing a dock card,
      pressing Space, dying, or otherwise leaving a machine removes every white highlight
      immediately; `TrainingMuscleHighlights` is absent or empty when idle.
- [ ] Train Chest and Back together — UpperTorso takes the larger of the two, and does
      not compound into a runaway size.
- [ ] At full growth the body is a **taper, not a box**: chest clearly wider than waist,
      arms visibly longer than they are thick. If any limb looks like a disc or the
      torso like a crate, `PhysiqueConfig`'s weights regressed.
- [ ] At lean progress, `MuscleDefinition` contains no shells or contours and every R15
      body part has `LocalTransparencyModifier == 0`. At full progress it contains 12
      `MuscleShellStats` parts and 28 `MuscleStatId` contours; the original rectangular
      torso and trained limbs are locally invisible beneath the rounded cosmetic shell.
- [ ] Veins fade in on arms and chest as scale passes ~1.35 and are absent on a fresh
      character — check a beginner has no `Veins` folder at all.
- [ ] Check the joints at full scale: limbs stay in their sockets, character stands on
      the floor rather than sinking.

## 4c. Machine visibility

- [ ] Stand anywhere with machines in sight. Each carries an outline in its muscle's
      colour and a glowing ring on the floor at its base.
- [ ] Open stations use their muscle colour; locked higher-tier stations are grey but visible.
- [ ] Outlines do **not** shine through buildings (DepthMode is Occluded). If the city
      looks like a christmas tree, that setting regressed.
- [ ] Run across the city and confirm marks hand off to nearby machines without
      accumulating — at most 14 outlines and 14 rings exist at once.
- [ ] Respawn and confirm rings/outlines come back rather than vanishing for the
      session.

## 5. Progression

- [ ] Token counter rises on a timer while alive on the gym floor.
- [ ] Stand in a safe zone or stay dead — tokens do **not** accrue.
- [ ] Press **M** → Info. The profile and five stat rows use the same flat dark card
      style as the other menu pages. Each row shows its current multiplier and a
      circular `+`, rather than a wide purchase banner.
- [ ] Click a stat's `+`. A centered confirmation names the next multiplier and exact
      token cost, with green confirm and orange cancel. Cancel spends nothing.
      With that muscle at 0, spend 10 tokens on Arms: only Arms changes x1 → x2 and
      its payout doubles; Chest/Back/Core/Legs remain x1. Buy Arms again to see x4.
      There is no Power or muscle-stat requirement—only the server-checked token cost.
- [ ] Press **M** → Muscles on Natural. Only Conditioned can be the next transform;
      later cards read order-locked. Below 10K total Power, Conditioned is Power-locked.
      At 10K with zero Fight Tokens, it becomes token-locked.
- [ ] Kill another player directly. The HUD and Info header gain exactly one Fight
      Token and show a reward toast. Kill that same player again inside the anti-farm
      window: the KO counts but pays no Fight Token. Repeat with a Core-reflection kill;
      the defender receives the token.
- [ ] Reach 10K Power, retain five Fight Tokens and some training tokens, and
      transform into Conditioned. All five stats and saved weights remain unchanged,
      the player stays where they stand, and exactly five Fight Tokens are spent.
      The body immediately uses Conditioned green and returns to a lean silhouette;
      its `MuscleProgress` values are all 0 and definition contours are gone.
- [ ] After transforming, train only Arms. Arms grows from lean toward its Conditioned
      cap while Chest, Back, Core and Legs stay lean. At 18K new Arms (one fifth of the
      90K Power gap to Defined), Arms reaches its visual cap and further Arms training
      increases combat Power without making the limb exceed the 2.2 safety cap.
- [ ] After transforming, Defined is the only next class and requires 100K total Power.
      Attempt a forged request for a later class: the server refuses the skip.
- [ ] Leave and rejoin. The earned physique and permanent muscle multipliers return.
- [ ] Quests page shows exactly **one** active quest from the rotation
      (`CycleUpperBody` → `CycleLowerBody` → `CycleMobHunt`); completing it awards tokens
      with a toast and immediately advances to the next step. Completing the last step
      wraps to the first with goals and rewards grown by one loop.
- [ ] Hold manual training for ten displayed Power. Gym Rat also rises by ten—not by
      event count—and machine, combo and multiplier gains match visible Power too.
- [ ] Shop tab: buy a Protein Shake with Robux and confirm the boost applies and expires.
- [ ] Reputation drops toward Criminal after killing a peaceful player, and rises after
      killing someone already marked Criminal.
- [ ] Each muscle's seven locations use seven different machine silhouettes and seven
      different poses. Fresh-profile billboards award exact base-location rates +1/s,
      +2/s, +4/s, +8/s, +16/s, +32/s and +64/s; spot-check every gate.

## 6. Leaderboards and roster

- [ ] Exactly **two** global boards render — Power and Kills — and populate with live data.
- [ ] The roster and kill feed update for both clients.

## 7. Before launch — data

- [ ] Set `USE_MOCK_IN_STUDIO = false` in `DataService`, enable Studio API access, and
      repeat: leave and rejoin, and confirm stats, tokens, multiplier levels,
      reputation, kills, and quest progress all return.
- [ ] Immortality: grant a potion, rejoin, confirm the remaining time survived.
- [ ] Confirm `PlayerData` is the store name you want. Renaming it later abandons every
      existing save.
- [ ] Publish and rejoin a live server to confirm session locking: a second server either
      transfers cleanly or kicks with a data-session message — never duplicate progress.

## 8. Before launch — monetisation

Nothing is purchasable until these are filled in. **All eleven ids are currently `0`.**

- [ ] Create the dev products and gamepasses in the Creator Dashboard.
- [ ] Paste each `AssetId` into the matching file in `PurchaseService/Products/`:
  - `VipGamepass.luau` — gamepass, 199 R$
  - `FastTravelGamepass.luau` — gamepass, 149 R$
  - `AutoLoadGamepass.luau` — gamepass, 99 R$
  - `ImmortalPotion1Hour.luau` — dev product, 19 R$
  - `ImmortalPotion1Day.luau` — dev product, 79 R$
  - `ProteinShake.luau`, `PreWorkout.luau` — dev products
  - `TokenPack200/400/800/1600.luau` — dev products
- [ ] Restart and confirm the AssetId-0 warnings are gone.
- [ ] Buy each product **on a live server** and confirm: the grant lands, the barrier
      appears, and re-buying while active *stacks* the time rather than replacing it.
- [ ] Confirm VIP grants its bonus on join, and that the daily potion can be claimed once
      and then refuses until UTC midnight.
- [ ] Confirm Fast Travel behaves correctly for a non-owner as well as an owner.

## 9. Before launch — polish

- [ ] Paste real asset ids into `EffectsConfig.Sounds`. The game is deliberately silent
      until then; every entry with a blank id is skipped.
- [ ] Playtest with 10+ players and watch server script activity. The per-frame loops to
      watch are `TrainingService` (per *mounted* player per frame), `MuscleController` and
      `TrainingPoseController` (both per character per frame, client-side).
- [ ] Walk and fly the full 35-location city at 10+ players and watch memory and frame time.

## 10. Balance questions only players can answer

These are guesses baked into `Formulas.luau` and `TrainingService`. None have been
validated against a real player, and #100 (the economy simulator) supersedes guessing here.

- [ ] Is the per-machine stat rate too slow or too fast for the first session?
- [ ] With interruption now kill-only, is attacking a trainer still worth the commitment —
      and is being killed mid-set annoying-funny or just enraging?
- [ ] Do the hits-to-kill on an equal opponent feel right, or is combat too long?
- [ ] Does a doubling multiplier against the `1.35^level` cost curve pace well past level 20?
- [ ] Does reputation swing too fast per murder / per justice kill?
- [ ] Can a first-time player understand the 35-pin map, find the next multiplier for their
      chosen muscle, and remember its landmark without reopening the map every minute?
