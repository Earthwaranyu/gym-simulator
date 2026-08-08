# Playtest & Launch Checklist

Everything static is already enforced by `./scripts/check.sh` — build, lints, and
`--!strict` types, plus `python3 scripts/validate_gym.py` for the generated world. This
file covers what only a running game can answer.

Counts and behaviors here are taken from [`PRODUCT_TRUTH.md`](PRODUCT_TRUTH.md) v1. If a
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
`57edbb3`, `9830780`) from 10 machines to **55 stations / 15 variants / 11 zones**, flight
was enabled from spawn (`895d0e3`), and training interruption changed from hit-stagger to
**kill-only**. Every box below is therefore unchecked: the old session is context, not
evidence.

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
- [ ] `python3 scripts/validate_gym.py` reports **55 stations, 15 variants** and a build hash.
- [ ] `rojo serve`, connect the Studio plugin, press Play.
- [ ] Output shows `[Loader/Server] Ignited N systems` and `[Loader/Client] Ignited N systems`.
      Record both numbers here the first time you run it; a later drop means a system failed
      to load silently.
- [ ] Output shows `[CombatService] Loaded 1 abilities` — **one**, not three. Slam and Dash
      are deferred.
- [ ] No red errors in Output. No station warnings — every one of the 55 stations must
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
- [ ] **Watch the pose on every one of the 15 variants.** Angles in `PoseConfig` are the
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
- [ ] **Q** toggles flight, **Space** ascends, **LeftShift** descends. Confirm Space
      ascending in flight never conflicts with Space dismounting a machine (different states).
- [ ] Higher Legs visibly raises both run and flight speed.
- [ ] Fly between distant districts with StreamingEnabled on — machines must not pop in
      late. If they do, raise `StreamingMinRadius` in `default.project.json`.
- [ ] Open the map. All **55** locations are present and selectable; zoom, pan, and
      selection survive a refresh.
- [ ] Fast Travel to a location, including one across the map, and land intact and mounted
      to nothing.
- [ ] Die mid-flight and mid-travel. You respawn cleanly with no stuck camera, no residual
      velocity, and no half-applied travel.

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
- [ ] Zone gates: crossing a zone's power requirement lets its gate teleport you; below it,
      the gate refuses with a "needs X more power" toast. Spot-check at least three of the
      11 zones, including Ascendant.

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
- [ ] Walk and fly the full 55-station map at 10+ players and watch memory and frame time.

## 10. Balance questions only players can answer

These are guesses baked into `Formulas.luau` and `TrainingService`. None have been
validated against a real player, and #100 (the economy simulator) supersedes guessing here.

- [ ] Is the per-machine stat rate too slow or too fast for the first session?
- [ ] With interruption now kill-only, is attacking a trainer still worth the commitment —
      and is being killed mid-set annoying-funny or just enraging?
- [ ] Do the hits-to-kill on an equal opponent feel right, or is combat too long?
- [ ] Does a doubling multiplier against the `1.35^level` cost curve pace well past level 20?
- [ ] Does reputation swing too fast per murder / per justice kill?
- [ ] Are 55 stations across 11 zones legible, or is the map overwhelming? (This is what
      #114's progressive disclosure exists to answer.)
