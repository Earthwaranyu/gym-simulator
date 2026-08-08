# Instrumented Alpha Protocol — checklist #102

**This document is the only part of #102 that can be written without players.** The
sessions themselves have to be run by humans on real devices; nothing in this repo can
produce that evidence, and no later claim about "how it feels" is allowed to cite
anything but a filled-in copy of this sheet.

Run it, fill in the Results section, commit the filled copy as
`docs/alpha/<date>-<platform>.md`, and only then treat the first beta targets in
[`KPI_SCORECARD.md`](KPI_SCORECARD.md) as evidence-backed rather than guessed.

## Baseline being measured

Freeze these before the first session. Every later comparison is against this row.

| What | Value |
|---|---|
| Commit | checklist #111 build (record the final commit in each filled sheet) |
| World build hash | `580b192a698f` (35 stations, 35 unique exercises, 2012 instances) |
| Interruption rule | kill-only |
| Abilities | Punch only |
| Products | all four `AssetId` still `0` — nothing purchasable |
| Model prediction, active player | first upgrade 2.5m, first rank 13.7m, second tier 5.8m |

If any of these changed, note it in the filled sheet. A session run against a different
world is a different baseline.

## Sessions to run

Three platforms, minimum. Each is a **fresh account or wiped profile** — a returning
player cannot measure a first session.

| # | Platform | Input | Length | Notes |
|---|---|---|---|---|
| 1 | Desktop | keyboard + mouse | 20 min | the path everything was built against |
| 2 | Phone | touch | 20 min | flight is keyboard-only today; expect this to fail |
| 3 | Console or desktop + pad | gamepad | 20 min | same expectation |
| 4 | Two desktops | keyboard | 15 min | the PvP session — see below |

Session 4 is the only one that can test the hook. One player trains; the other attacks.
Swap roles halfway.

## What to capture

Do not rely on memory for any of this.

**Recorded automatically** (read back from analytics after the session — every one of
these is wired as of #98): `Joined`, `Moved`, `FirstRep`, `FirstMultiplier`,
`FirstFlight`, `PromptSeen`, `MapOpened`, `TrainingStarted`/`Ended`, `Interruption`,
`Death`, `Kill`, `SessionEnd` with activity count, `DeviceInput`, `Locale`.

**Captured by hand**, because nothing can infer them:

1. **Timings** — stopwatch from spawn to: first input, first prompt read, first rep,
   first upgrade, first flight, first death. Compare against the model's predictions in
   the baseline table above.
2. **Confusion moments.** Every time the player stops, backtracks, opens a menu and
   closes it without acting, or asks a question. Write the *question they asked*, not
   your interpretation of it.
3. **Deaths** — what killed them, whether they understood why, and whether they came
   back to the same machine.
4. **The exit.** Whatever the player was doing in the 30 seconds before they stopped
   playing, and what they said when asked why. This is the single most valuable line on
   the sheet and the easiest one to forget to record.
5. **Traces.** Studio's MicroProfiler for frame time, the Developer Console for memory
   and network, on the lowest-end device available. Capture at spawn, mid-training, and
   while flying across districts.

## Questions to ask afterwards, in this order

Ask them open-ended first; a leading question gets you the answer you fed it.

1. What was this game about?
2. What were you trying to do just now?
3. Was there anything you wanted to do and could not work out how?
4. *(only after the above)* Did you notice you could fly? Buy upgrades? Travel?
5. Would you come back tomorrow? What for?

## Known expectations going in

State these before running, so a confirmed expectation is not mistaken for a discovery:

- **Flight is keyboard-only.** Touch and gamepad sessions are expected to fail the
  flight step entirely. That is #135's problem, and this session is here to size it.
- **There is no onboarding.** Nothing tells a new player what to do; the Coach path is
  #109 and does not exist. Expect the "what was this game about?" answer to be vague.
- **The map shows all 35 locations at once.** Expect it to be overwhelming; #114 exists
  because of that expectation, and this session is what confirms or kills it.
- **Nothing is purchasable.** Any store interaction ends in "not available yet".

## Results

*(Empty until the sessions are run. Do not fill in from prediction.)*

| Metric | Model predicted | Session 1 | Session 2 | Session 3 |
|---|---|---|---|---|
| Join → first rep | — | | | |
| Join → first upgrade | 2.5m | | | |
| Join → first flight | — | | | |
| Reached second tier | 5.8m | | | |
| Session length before disengaging | — | | | |
| Distinct activities | — | | | |
| p50 FPS | — | | | |

**Confusion log:**

**Exit reason:**

**Frozen first beta targets** (fill from results, not from the gate table):
