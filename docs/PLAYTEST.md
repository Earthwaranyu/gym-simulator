# Playtest & Launch Checklist

Everything static is already enforced by `./scripts/check.sh` — build, lints, and
`--!strict` types, plus `python3 scripts/validate_gym.py` for the generated world. This
file covers what only a running game can answer.

Counts and behaviors here are taken from [`PRODUCT_TRUTH.md`](PRODUCT_TRUTH.md) v8. If a
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
`57edbb3`, `9830780`) and now again into a **35-location, seven-tier massive city**. Flight
is enabled from spawn and training interruption is **kill-only**. Every
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
- [ ] `python3 scripts/validate_gym.py` reports **35 stations, 7 tiers × 5 muscles / 35 unique exercises** and a build hash.
- [ ] `rojo serve`, connect the Studio plugin, press Play.
- [ ] Output shows `[Loader/Server] Ignited 26 systems` and `[Loader/Client] Ignited 20
      systems`. A lower number means a system failed to load silently.
- [ ] Output shows `[DevService] Studio session — dev commands are ACTIVE`. This warning
      must **never** appear on a live server.
- [ ] Output shows `[CombatService] Loaded 1 abilities` — **one**, not three. Slam and Dash
      are deferred.
- [ ] No red errors in Output. No station warnings — every one of the 35 stations must
      resolve its definition, its `TrainAnchor` spots, and its prompt.
- [ ] Expected warnings, and only these:
  - `[DataService] Studio session using the MOCK store` — see step 7 before launch.
  - `[PurchaseService] "..." has AssetId 0` — one per product, four total, see step 8.
  - `[LeaderboardService] Studio session` — global boards need API access.

## 2. Training loop

- [ ] Walk up to any station. A "Hold E to …" prompt appears. **Still the one step with no
      automated evidence behind it at all** — prompts do not render in MCP sessions.
- [ ] Hold **E**. You are placed on the machine, locked there, and start repping.
- [ ] You spawn in the safe-zone bubble, not loose on the gym floor.
- [ ] The trained stat climbs in the HUD; total power climbs with it.
- [ ] The combo readout rises the longer you stay on.
- [ ] **Hold E again** to dismount. Then remount and **press Space** — that must also
      dismount you (`StopTraining`). Then remount and **jump** — same. All three paths work
      and the combo resets on each.
- [ ] **Watch the pose on all five playable exercises.** Angles in `PoseConfig` are the
      thing most likely to look wrong: you should lie *on* the bench not through it, hang
      *from* the bar not above it, and limbs should bend the way a body bends. Tune in that
      one file.
- [ ] Fill a multi-spot station to capacity with several characters. The next player is
      refused with "in use", and the billboard counts down free spots.
- [ ] Billboards show each machine's stat and its per-second rate.
- [ ] Locked stations read "Locked" with their power requirement until you meet it.
- [ ] Your muscles visibly thicken as stats climb. **Watch the joints at high scale** —
      limbs stay in their sockets and the character stands on the floor rather than sinking.

## 3. PvP and the hook

The rule under test: **a hit does not dismount; only death does.**

- [ ] Player B presses **F** near player A. A takes damage; both see feed lines.
- [ ] Hit A *while A is training*. A **stays on the machine**, keeps repping, and keeps the
      combo. Only the health bar moves. If A pops off on a hit, `CombatService` has
      regressed to the old stagger behavior.
- [ ] Keep hitting until A dies. **Now** A is dismounted, the combo resets, and the kill
      feed fires. This is the whole game — if committing to the kill does not feel worth it,
      that is a balance finding for step 10, not a bug.
- [ ] A mounted player cannot dodge — B can walk up and swing freely, and A is genuinely
      stuck rather than sliding under the hit.
- [ ] A hit **grounds** a flying victim; they cannot simply fly off mid-fight.
- [ ] A respawns after ~4s with stats, cash, and tokens **fully intact**.
- [ ] Both players' kill/death counts update in the tab bar.
- [ ] Inside the spawn safe zone, damage is nullified for attacker and victim both.
- [ ] Kill the same victim twice inside 2 minutes: the second kill lands but pays no cash
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
- [ ] Traverse the expanded world edge to edge. The connected visible land should span
      roughly 4,868 × 4,471 studs, with every road, district, machine and sky platform
      horizontally contained by the 6,200 × 5,600 `WorldFoundation`. Falling into the
      surrounding water lands on the hidden rock catcher instead of the void.
- [ ] Open the map. It is a **light** board, not a dark one, and every district, road
      and building is legible against it. All **35** locations are present and
      selectable; zoom, pan, and selection survive a refresh.
- [ ] Every pin shows both its muscle letter and location multiplier. x1 pins are open;
      locked x2–x64 pins remain readable rather than disappearing into the paper.
- [ ] Run and fly through scenery — containers, palms, bollards, kerbs. None of it
      blocks you. Buildings, ground and platforms still do.
- [ ] **Without the Fast Travel pass**, pick any destination. You are NOT moved: a
      beacon appears over it with a live distance, an arrow points to it whenever it is
      off-screen, and the menu closes. Walk/fly there and confirm it clears itself
      within ~26 studs with an "Arrived" toast.
- [ ] Turn around — the arrow must point behind you, not at the mirrored side of the
      screen.
- [ ] Die while tracking. The beacon survives the respawn (it is rebuilt on the new
      camera).
- [ ] **With the pass** (`/fasttravel` in Studio), the same button teleports instead,
      including across the map, and you land intact and mounted to nothing.
- [ ] Die mid-flight and mid-travel. You respawn cleanly with no stuck camera, no residual
      velocity, and no half-applied travel.

## 4b. Finding a machine (Train tab)

- [ ] Open the menu → **Train**. It opens on the muscle you are furthest behind on.
- [ ] Click each of the five bottom muscle buttons. Exactly seven named locations appear
      for each muscle, and the matching Train chip is selected.
- [ ] Each muscle list reads x1, x2, x4, x8, x16, x32, x64; usable locations appear first
      and locked entries show the correct power shortfall.
- [ ] The right-side **MAIN GOAL** card defaults to the training objective (`Gym Rat`), shows
      live progress/reward, and its **QUESTS** button opens the complete quest list. It must
      not choose the multiplayer knockout objective for a fresh solo player.
- [ ] Free/busy counts are live: have a second player mount a machine and confirm the
      count drops within ~2 seconds without reopening the panel.
- [ ] While you are training, that station reads **YOU ARE HERE** and its button says
      "Here".
- [ ] Close the panel and confirm the polling stops (no further `GetSpotStatus` traffic).
- [ ] Locked entries show the shortfall in power, not a Go button.

## 4d. Body and growth

- [ ] Every player looks identical on spawn: no shirt, no accessories, one skin tone,
      dark shorts (the R15 UpperLegs) over bare shins. Join with an avatar wearing a
      hat and confirm it does not appear.
- [ ] Train **one** muscle and confirm only its parts grow: Chest → UpperTorso only,
      Arms → both arms only, Legs → both legs only, Core → LowerTorso only.
- [ ] Train Chest and Back together — UpperTorso takes the larger of the two, and does
      not compound into a runaway size.
- [ ] At full growth the body is a **taper, not a box**: chest clearly wider than waist,
      arms visibly longer than they are thick. If any limb looks like a disc or the
      torso like a crate, `PhysiqueConfig`'s weights regressed.
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
- [ ] Press **M** → Upgrades. Buy a multiplier. The value **doubles** (1x → 2x → 4x) and
      is shown through `NumberFormat`, not as `2.00x`. The stat's rate visibly increases.
- [ ] Quests tab shows progress for the three shipped quests (`DailyReps`,
      `DailyBounties`, `FirstMillion`); completing one awards tokens with a toast.
- [ ] Shop tab: buy a Protein Shake with cash and confirm the boost applies and expires.
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
      repeat: leave and rejoin, and confirm stats, tokens, multiplier levels, cash,
      reputation, kills, and quest progress all return.
- [ ] Immortality: grant a potion, rejoin, confirm the remaining time survived.
- [ ] Confirm `PlayerData` is the store name you want. Renaming it later abandons every
      existing save.
- [ ] Publish and rejoin a live server to confirm session locking: a second server either
      transfers cleanly or kicks with a data-session message — never duplicate progress.

## 8. Before launch — monetisation

Nothing is purchasable until these are filled in. **All four ids are currently `0`.**

- [ ] Create the dev products and gamepasses in the Creator Dashboard.
- [ ] Paste each `AssetId` into the matching file in `PurchaseService/Products/`:
  - `ImmortalPotion1Hour.luau` — 19 R$
  - `ImmortalPotion1Day.luau` — 79 R$
  - `VipGamepass.luau` — 199 R$
  - `FastTravelGamepass.luau`
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
