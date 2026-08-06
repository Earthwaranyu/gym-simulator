# Playtest & Launch Checklist

Everything static is already enforced by `./scripts/check.sh` — build, lints, and
`--!strict` types. This file covers what only a running game can answer.

Run a **two-client Studio playtest** (Test → Clients and Servers → 2 players) unless a
step says otherwise.

---

## 1. It boots

- [ ] `wally install` then `./scripts/check.sh` — all checks pass.
- [ ] `rojo serve`, connect the Studio plugin, press Play.
- [ ] Output shows `[Loader/Server] Ignited N systems` and `[Loader/Client] Ignited N systems`.
- [ ] Output shows `[CombatService] Loaded 1 abilities`.
- [ ] No red errors in Output.
- [ ] Expected warnings, and only these:
  - `[DataService] Studio session using the MOCK store` — see step 6 before launch.
  - `[PurchaseService] "..." has AssetId 0` — one per product, see step 7.
  - `[LeaderboardService] Studio session` — global boards need API access.

## 2. Training loop

- [ ] Walk near the Bench Press. Training starts with no input.
- [ ] Chest climbs in the HUD; total power climbs with it.
- [ ] The combo readout rises toward x2.00 the longer you stand there.
- [ ] Walk away. Training stops and the combo resets.
- [ ] Billboards show each machine's stat and its per-second rate.
- [ ] Pull-Up Bar and Sit-Up Bench read "Locked" until 500 power; Treadmill until 2000.
- [ ] Your arms and chest visibly thicken as the stats climb.
- [ ] **Watch the joints** at high scale — limbs should stay in their sockets, and the
      character should stand on the floor rather than sinking. This is the part most
      likely to look wrong; it is item 28 and has never been seen running.

## 3. PvP and the hook

- [ ] Player B presses **F** near player A. A takes damage; both see feed lines.
- [ ] Hitting A *while A is training* knocks A off the machine for ~3 seconds and shows
      "Knocked off the machine!". **This is the whole game — if it does not feel
      annoying, tune `STAGGER_SECONDS` in `TrainingService`.**
- [ ] Kill A. A respawns after ~4s with stats, cash, and tokens **fully intact**.
- [ ] Both players' kill/death counts update in the tab bar.
- [ ] Stand inside the blue spawn bubble — damage is nullified for attacker and victim.
- [ ] Kill the same victim twice inside 2 minutes: the second kill still lands but pays
      no cash and no reputation, and shows "no reward for farming".

## 4. Progression

- [ ] Token counter rises roughly every 15s while alive on the gym floor.
- [ ] Stand in the safe-zone bubble or stay dead — tokens do **not** accrue.
- [ ] Press **M** → Upgrades. Buy a multiplier. The stat's rate visibly increases.
- [ ] Quests tab shows progress; completing one awards tokens with a toast.
- [ ] Shop tab: buy a Protein Shake with cash and confirm gains double for 10 minutes.
- [ ] Reputation drops toward Criminal after killing a peaceful player, and rises after
      killing someone already marked Criminal.
- [ ] Crossing 250,000 power lets the Iron Hall gate teleport you; below it, the gate
      refuses with a "needs X more power" toast.

## 5. Persistence

- [ ] Leave and rejoin within the same Studio session. Stats, tokens, multiplier levels,
      cash, reputation, kills, and quest progress all return.
- [ ] Immortality: grant a potion, rejoin, confirm the remaining time survived.

## 6. Before launch — data

- [ ] Set `USE_MOCK_IN_STUDIO = false` in `DataService`, enable Studio API access, and
      repeat step 5 against the **real** DataStore.
- [ ] Confirm `PlayerData` is the store name you want. Renaming it later abandons every
      existing save.
- [ ] Publish to Roblox and rejoin a live server to confirm session locking: joining a
      second server should either transfer cleanly or kick with a data-session message,
      never duplicate progress.

## 7. Before launch — monetisation

Nothing is purchasable until these are filled in.

- [ ] Create the dev products and gamepass in the Creator Dashboard.
- [ ] Paste each `AssetId` into the matching file in `PurchaseService/Products/`:
  - `ImmortalPotion1Hour.luau` — 19 R$
  - `ImmortalPotion1Day.luau` — 79 R$
  - `VipGamepass.luau` — 199 R$
- [ ] Restart and confirm the AssetId-0 warnings are gone.
- [ ] Buy each product **on a live server** and confirm: the grant lands, the barrier
      appears, and re-buying while active *stacks* the time rather than replacing it.
- [ ] Confirm VIP grants 2x stats on join, and that the daily potion can be claimed once
      and then refuses until UTC midnight.

## 8. Before launch — polish

- [ ] Paste real asset ids into `EffectsConfig.Sounds`. The game is deliberately silent
      until then; every entry with a blank id is skipped.
- [ ] Playtest with 10+ players and watch the server's script activity. The per-frame
      loops to watch are `TrainingService` (per player per frame) and `MuscleController`
      (per character per frame, client-side).
- [ ] Confirm StreamingEnabled does not pop machines in late — if it does, raise
      `StreamingMinRadius` in `default.project.json`.

## 9. Balance questions only players can answer

These are guesses baked into `Formulas.luau` and `TrainingService`. None have been
validated against a real player.

- [ ] Is ~670 stat/minute per machine too slow or too fast for the first session?
- [ ] Is a 3-second stagger annoying enough to be funny, or long enough to be enraging?
- [ ] Do 5–6 hits to kill an equal opponent feel right, or is combat too long?
- [ ] Is the 1.35^level multiplier cost curve too steep past level 20?
- [ ] Does reputation swing too fast at -12 per murder and +8 per justice kill?
