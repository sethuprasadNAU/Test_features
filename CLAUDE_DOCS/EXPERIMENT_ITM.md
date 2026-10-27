# Experiment — Longley-Rice ITM propagation on device

**Status:** Not started. Parked deliberately — Phase 10 first.
**Branch:** `experiment/itm-propagation` (do not do this work on `main`).
**Plan file:** this one. **Do not add these tasks to `DEVELOPMENT_PLAN.md`** —
two branches editing that file means merge conflicts in prose.
**Commands:** prefix `itm-*` so they cannot collide with numbered phase tasks.

---

## What this is, and what it is not

**It is a feasibility spike.** The question is narrow: *can Longley-Rice ITM run
on an iPhone fast enough to be worth integrating into TriTrack?* The deliverable
is a number and a recommendation, not a feature.

**It is not an integration.** Nothing here touches the app's UI, data model, or
existing viewshed. If the numbers come back bad, the whole branch is deleted and
nothing is owed.

**Why it might matter.** Today's viewshed answers "is there line of sight."
ITM would answer "what signal level would I expect" over irregular terrain —
which is a substantially better question for VHF telemetry, and would let the
app reason about non-detections rather than only detections.

## The prior decision that shapes everything

**Do not build a separate throwaway test app.** It is the obvious move and it
would produce a misleading answer.

ITM's own arithmetic is cheap. The expensive part is almost certainly
**terrain-profile extraction** — every path needs elevation samples along a
great circle, which means tile lookup, bounds handling and interpolation across
`lib/viewshed/dem_tile_store.dart` (467 lines) and
`lib/viewshed/elevation_grid.dart`. A standalone test app would stub that out,
benchmark the cheap half, and return an optimistic number.

**So: benchmark the two halves separately, and benchmark the profile extraction
against real tiles in the real app.**

## Structure

Two pieces, deliberately:

1. **A standalone Flutter/Dart package** holding the ITM kernel and its own
   correctness tests and microbenchmarks. Developed and tested on its own,
   no TriTrack dependency. This is the risky, self-contained part.
2. **A benchmark integration test inside TriTrack**, on the branch, that feeds
   that kernel **real terrain profiles from real tiles** and times the whole
   path. No UI, no wiring, no feature.

`integration_test/` already exists and runs on hardware — task 10.50 built it
for the ATS check. Reuse that harness; do not build a new one.

---

## Tasks

### ITM-0 — Write down what "fast enough" means, before measuring
**Status:** Not started
**Model:** Opus — this is the decision the rest of the spike is graded against.

**Do this first and commit it before any benchmark runs.** Otherwise the spike
grades itself against whatever it happens to produce, which is the same shape as
this project's most persistent defect class.

State a number for each case that would actually be used:

- **A single path** (one receiver position, one hypothesized animal position).
- **A bearing fan** — one position, many azimuths.
- **A coverage raster** over a project extent. State the grid dimensions
  assumed; a 500 × 500 grid is 250,000 path calculations and the number is
  meaningless without the dimensions beside it.

For each: what latency is acceptable, whether it may run in the background, and
what the user is doing while it runs. **A field app on battery, in the cold,
with a screen the user is waiting on, is a different bar from a desktop.**

Also state the failure condition — the result at which the recommendation is
"don't integrate this." Write it down now so it cannot move later.

### ITM-1 — Choose the implementation approach
**Status:** Not started
**Model:** Opus — the choice changes the performance result by an order of
magnitude and is expensive to reverse.

Two candidates:

- **Pure Dart port** of the reference model. Simple build, no platform work,
  slower, and carries real risk of porting bugs in a numerically fiddly model
  where a wrong answer looks plausible.
- **FFI to NTIA/ITS's reference C++ implementation.** Faster, avoids porting
  bugs by using the authoritative implementation, but adds per-platform build
  configuration and a native dependency to a project that currently has none of
  either.

Weigh honestly, including the maintenance cost of a native dependency on a
project one person maintains. **Record the reasoning**, not just the verdict.

**Whichever is chosen, the benchmark must measure the approach that would
ship.** Benchmarking a Dart port and then shipping FFI, or the reverse, answers
a question nobody asked.

### ITM-2 — Build the kernel package with correctness tests
**Status:** Not started
**Model:** Sonnet, given ITM-1's decision.
**Depends on:** ITM-1

A standalone package. No TriTrack dependency, no UI.

- **Correctness before speed.** ITM has published reference cases; validate
  against them. A fast wrong answer is worse than no answer here, because a
  propagation prediction that is confidently incorrect will be used to decide
  an animal is not present.
- Microbenchmarks for the kernel alone, on desktop, so there is a baseline to
  compare the device number against.
- **State the model's own limits in the package's README** — ITM has defined
  validity ranges for frequency, distance and terrain, and telemetry work will
  sit near some edges of them.

### ITM-3 — Benchmark terrain-profile extraction against real tiles
**Status:** Not started
**Model:** Sonnet
**Depends on:** nothing — **can run before ITM-1 and ITM-2, and probably should.**

**This is the task most likely to decide the outcome, and it needs no ITM code
at all.** Time the existing path — `dem_tile_store.dart`, `elevation_grid.dart`,
whatever `viewshed.dart` already does to sample a line — for:

- one profile;
- a fan of profiles from one origin;
- the number of profiles a coverage raster would need.

Do it on device, in `integration_test/`, against real cached tiles at a real
project extent — not synthetic data, and not on desktop.

If profile extraction alone blows ITM-0's budget, **the answer is known and the
kernel work is unnecessary.** That would be a good outcome for a day's work.

### ITM-4 — End-to-end benchmark on hardware
**Status:** Not started
**Model:** Sonnet
**Depends on:** ITM-2, ITM-3

The real measurement: kernel plus profile extraction, on a physical iPhone, in a
release build, at ITM-0's three cases.

- Report a distribution, not a single number — best, median, worst.
- Report **battery and thermal behavior** on the raster case if it runs long
  enough to matter. A field app that computes a coverage map and leaves the
  phone hot and half-drained has failed even if the wall-clock number passes.
- Report the split between kernel and profile extraction, so the next decision
  knows which half to attack.
- **Do not tune anything yet.** The first honest number is worth more than a
  tuned one; optimisation targets follow from knowing where the time went.

### ITM-5 — Recommendation
**Status:** Not started
**Model:** Opus
**Depends on:** ITM-4

Against ITM-0's stated bar, written before the numbers existed: integrate,
integrate with constraints, or drop.

If the recommendation is to integrate, say what integration would actually cost
— it touches the viewshed path, which is core, and that is a `DEVELOPMENT_PLAN.md`
phase to be planned properly, not an extension of this spike.

**"Drop" is a legitimate and cheap outcome.** The point of a spike is to buy
that answer for days instead of months.

---

## Working notes

- **Merge back or delete early.** A branch touching the viewshed path while
  `main` moves is where this goes wrong. If the spike stalls, delete the branch
  and keep this file.
- **Use a separate Cowork conversation** for this work, so context does not bleed
  into the Phase 10 thread.
- At the start of any session where both branches are live, check
  `git branch --show-current` before doing anything.
