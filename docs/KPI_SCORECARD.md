# KPI Scorecard — v1 (2026-08-08)

The one scorecard. If a number is not on this page it does not get optimized, and if it is
on this page it has an owner, a source, a cadence, and a decision it feeds.

Counts and shipped-feature claims come from [`PRODUCT_TRUTH.md`](PRODUCT_TRUTH.md).
Instrumentation status comes from `AnalyticsService.luau` as it exists today — most rows
are **NOT WIRED**, and #98 (analytics contract v2) is the item that fixes that. Nothing
here may be reported as a measured result until its row reads WIRED.

## Product brief

**What this is.** An open-world gym-training game where stats scale into the trillions and
PvP is live inside the gym: the differentiator is that another player can end your training
set. Interruption is **kill-only** — a hit hurts, only death dismounts you — so attacking a
trainer is a commitment, not a drive-by tax.

**Who it is for.** Roblox simulator players who want visible, exponential growth, plus the
subset who want that growth to be contestable by other players.

**The loop we optimize.**

> accurate promise → first delight → meaningful goal → social story → return → share → repeat

**What we will not trade for a number.** Player safety, truthful merchandising, and
non-payer/PvP-victim retention outrank revenue. A change that lifts an average while
harming any of these cohorts is a revert, not a win.

## Roles

This is a single-maintainer project today, so every "owner" below resolves to the project
owner. The column still exists because the *review* it names differs: the owner wears a
different hat for each block and reviews each on its own cadence. Split these to real
people as soon as there is more than one.

| Role | Scope |
|---|---|
| **Acquisition owner** | store page, creatives, source quality |
| **Onboarding owner** | first ten minutes, tutorial, first choice |
| **Loop owner** | session shape, progression, combat balance |
| **Social owner** | co-play, invites, shareable moments |
| **Economy owner** | currencies, products, receipts, fairness |
| **Reliability owner** | crashes, memory, frame rate, servers, saves |

## Cadences

| Cadence | What happens |
|---|---|
| **Daily** | reliability board only: crash-free rate, OOM exits, receipt errors, save failures. Any breach is same-day. |
| **Weekly** | full scorecard review; every experiment gets a keep/revert call; cohort splits are read, not just averages. |
| **Per release** | gate check before any staged rollout widens. |
| **Monthly** | re-baseline internal gates against the live Creator Dashboard similar-experience benchmarks and retire the guesses below. |

## The gates

These are **starting internal gates, not Roblox promises or industry facts.** Replace each
with the live similar-experience benchmark once there is enough traffic. Sourced from the
Phase 18 roadmap section in `CHECKLIST.md`.

| Funnel | Gate |
|---|---|
| First delight | p50 join→first rep ≤30s; onboarding completion ≥75%; 5-min survival ≥65%; 10-min survival ≥45% |
| Retention | D1/D7/D30 ≥ benchmark; working stretch 20% / 8% / 3% |
| Engagement | median session ≥15 min; ≥3 distinct activity types per healthy session; 7-day play days/user ≥2 |
| Social | intentional friend play in ≥20% of sessions; invite acceptance ≥8%; 7-day co-play days/user ≥0.35 |
| Discovery | qPTR ≥ benchmark with honest creatives; judge each source by downstream D7, not clicks |
| Monetization | 100% idempotent grants; no meaningful D1/D7 or non-payer/PvP-victim regression after a store change |
| Reliability | crash-free ≥99.5%; OOM exits <0.1%; p95 join→interactive ≤10s; p50 ≥55 FPS on the low-end mobile tier; healthy heartbeat at capacity |

## Metric definitions

Status: **WIRED** = emitted by `AnalyticsService` today · **PARTIAL** = emitted but
incomplete or unvalidated · **NOT WIRED** = must be added by #98.

### Acquisition — *Acquisition owner, weekly*

| Metric | Definition | Source | Status |
|---|---|---|---|
| qPTR | qualified play-through rate as Roblox defines it | Creator Dashboard | external |
| Qualified plays by source | qualified plays split by acquisition source | Dashboard + `source` event field | NOT WIRED |
| Source quality | D7 of each source's cohort, not its click volume | joined + D7 by source | NOT WIRED |

### First delight — *Onboarding owner, weekly*

| Metric | Definition | Source | Status |
|---|---|---|---|
| Join → first rep | seconds from `Joined` to `FirstRep` | funnel, needs timestamps | PARTIAL (steps fire, timing not captured) |
| Join → first upgrade | seconds from `Joined` to `FirstMultiplier` | funnel | NOT WIRED (step declared, never fired) |
| Join → first flight | seconds to first flight toggle | new event | NOT WIRED |
| Onboarding completion | share of new players finishing the #109 path | new events | NOT WIRED (path does not exist yet) |
| 5-/10-minute survival | share of sessions still active at 5 / 10 min | session end event | NOT WIRED |

### Engagement and retention — *Loop owner, weekly*

| Metric | Definition | Source | Status |
|---|---|---|---|
| D1 / D7 / D30 | Roblox-defined return rates | Dashboard | external |
| Median session length | p50 session duration | session end | NOT WIRED |
| Activity variety | distinct activity types per session (train / fight / travel / quest / shop / map) | custom events | NOT WIRED |
| Rank pacing | time to each rank crossing | `RankReached` custom event | WIRED (no timing) |
| Interruption rate | training sets ended by death, per player-hour | new event | NOT WIRED |
| PvP-victim churn | D1/D7 of players killed ≥N times in their first session vs those not | kill + session events | NOT WIRED |

### Social — *Social owner, weekly*

| Metric | Definition | Source | Status |
|---|---|---|---|
| Intentional co-play sessions | share of sessions with a friend present by intent | friend-context event | NOT WIRED |
| Invite conversion | invites accepted / invites sent | new events | NOT WIRED (no invite system) |
| 7-day co-play days/user | per-user days with intentional co-play | Dashboard + events | NOT WIRED |

### Economy and monetization — *Economy owner, weekly (receipts daily)*

| Metric | Definition | Source | Status |
|---|---|---|---|
| Token source/sink balance | tokens granted vs spent per player-hour | `LogEconomy` | PARTIAL (source wired, sinks incomplete) |
| First purchase | time and step of first paid conversion | funnel `FirstPurchase` | NOT WIRED (step declared, never fired) |
| Payer rate / ARPDAU / 7-day spend days | standard payer metrics | Dashboard | external |
| Grant idempotency | granted-exactly-once rate; target **100%** | receipt journal (#105) | NOT WIRED |
| Non-payer guardrail | D1/D7 of non-payers before vs after any store change | cohort split | NOT WIRED |

### Reliability — *Reliability owner, daily*

| Metric | Definition | Source | Status |
|---|---|---|---|
| Crash-free sessions | ≥99.5% | Dashboard | external |
| OOM exits | <0.1% | Dashboard | external |
| p95 join → interactive | ≤10s | client timing event | NOT WIRED |
| p50 FPS, low-end mobile | ≥55 | client perf sample | NOT WIRED |
| Server heartbeat at capacity | healthy at target player count | server sample | NOT WIRED |
| Profile save success | saves succeeded / attempted; any failure is same-day | `DataService` | NOT WIRED |
| Receipt errors | pending or unknown receipts; target zero | #105 journal | NOT WIRED |

## Decision rules

1. Finish the P0 truth, telemetry, onboarding, fairness, mobile, data, and performance
   gates before any public acquisition spend.
2. Every experiment has one hypothesis, one primary metric, guardrails, a deterministic
   cohort, a minimum observation window, and a pre-committed keep/revert rule.
3. Always split new vs returning, payer vs non-payer, solo vs social, platform, locale, and
   PvP-victim. An average must never conceal a harmed group.
4. Never buy traffic to diagnose a product problem.
5. A metric with status NOT WIRED cannot be cited in any decision. Wire it or drop the
   claim.
