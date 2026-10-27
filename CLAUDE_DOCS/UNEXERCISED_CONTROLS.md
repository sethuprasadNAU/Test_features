# What in TriTrack has never once been executed

**A survey, taken 2026-09-01 by task 11.119 (which carries task 11.77). Nothing here
was fixed. The list is the deliverable.**

> ## Updated 2026-09-02 by task 11.125, which ran things
>
> **Task 11.125 exercised part of this list and its verdicts are edited in below**, each marked
> `Updated 2026-09-02`. The survey's own sentences are left standing beside them, because what
> they said was true when written and the point of this document is the difference.
>
> **The most important correction is to this document's own diagnosis.** It recorded
> `verify_11_49_server_reads.py` as red on *"the known Entry-28 baseline item awaiting Michael's
> §4.13 answer"*, and told Michael that one answer from him unblocked two of the three
> broken-control harnesses. **That was impossible and nobody had checked it.** He answered
> §4.13 on 2026-08-31; the instrument implemented the answer the same day, as a `note()`; and a
> `note()` cannot fail a run. **Run on 2026-09-02, the instrument's actual red was a
> `BASELINE DRIFT` on its single registered finding, R-2** — a refused requester's live read of
> a renamed project, which **task 11.79 closed on 2026-09-01** by freezing `project_name` onto
> the request row. The register still said the finding was open, so the run went red saying so.
> That is the register working exactly as designed, and the fix was one line.
>
> **The rule this leaves behind is in `CLAUDE.md` already and was broken here anyway: before
> repeating a recorded failure reason, check it against the code that produces the failure.**
> A wrong cause on a screen misdirects one person; a wrong cause in a status document
> misdirects every future reader, and this one misdirected two of them for two days.

> ## Updated 2026-09-04 — a control this survey did not think to doubt
>
> **`test/security/no_committed_secrets_test.dart` is in the default suite, runs on every push, and
> has been green throughout. It is also, in CI, scanning one commit.** Task 10.58 widened it from
> `git ls-files` to `git rev-list --objects --all` — every blob ever reachable from any ref —
> because a secret committed and later removed is still in every clone. **`offline-suite.yml`
> checks out with a bare `actions/checkout@v4`, whose default is a single commit.**
>
> **Its own guard against this is `expect(historicalBlobs.length, greaterThan(100))`, and a single
> tip tree clears that easily.** So the check reports success, in five minutes, having done almost
> none of the work it was widened to do — while the same check needs more than twelve minutes
> locally, where the history is real.
>
> **This is a fourth verdict beside the three below, and a nastier one.** Not *never executed*, not
> *executed on one machine by hand*, not *executed but never by its intended mechanism* — but
> **executed constantly, by the right mechanism, against almost none of its subject.** A survey
> that asks "has this run?" gets a clean yes here. **The question that would have caught it is
> "has it run against what it claims to cover?"** — and this document should ask that of everything
> in it. **Task 11.150 owns the repair.**
>
> **Task 11.155 carried that question to the other eight continuous-integration checkouts,
> 2026-09-04, and the answer was not about clone depth.** None of those jobs reads git history at
> all; one of them was paying for a full clone on a reason that turned out to be measurably false.
> **What two of them were narrowed by was the test runner's own exit code** — `flutter test` and
> `dart test` both exit 0 when every test they loaded was skipped, and when they loaded only some
> of the files they should have. So the weekly tile-credit job could have gone green having asked
> no provider anything, and the server suite could have gone green having run 2 of its 55 files.
> `scripts/assert_suite_scope.py` now asserts and prints, on both, what the run actually reached.
> **The generalisation worth carrying forward: "has it run against what it claims to cover?" is
> not only a question about the checkout. It is a question about the invocation.**
>
> **Task 11.156 applied it to the biggest one, 2026-09-04: the offline suite, which runs on every
> push.** `scripts/run_offline_suite.sh` ran a bare `flutter test` and echoed **PASS** on its exit
> code, and nothing anywhere said how many of `test/`'s files that was. Watched failing:
> `flutter test test/localization` prints *"All tests passed!"*, exits 0, and would have been
> reported as a pass over **7 of 250 test files**; the scope check now reddens it and names the
> 243 it missed. The suite's 15 legitimate skips are asserted as a **declared set** in
> `test/declared_skips.json` — each with a reason, failing in both directions — rather than as a
> count, because a count is 11.150's `greaterThan(100)` wearing a different hat. **Measured cost
> of the JSON reporter on 2,196 tests: smaller than the machine's own run-to-run spread**
> (111.3 s -> 106.4 s, then 81.7 s -> 84.8 s), so the gate is no slower in any way this could
> detect.

> ## Updated 2026-09-06 by task 11.174 — a test file that no automated run has ever executed
>
> **`test/features/more/server_config_screen_macos_test.dart` has never run in continuous
> integration, and after task 11.174 it still has not.** It is `@TestOn('mac-os')`, and it checks
> what the Server Settings screen tells somebody when Apple's own networking stack refuses a
> connection — a genuine `NSError` reaching the app through `package:cupertino_http`, which can
> only be constructed on a Darwin machine.
>
> **Asked directly, and the answer is nothing.** This repository has one macOS job,
> `build-check.yml`'s `apple:` — and it is `workflow_dispatch` only, it runs
> `flutter build ios --no-codesign` and `flutter build macos`, and it runs **no tests at all**.
> Every job that runs `flutter test` is `runs-on: ubuntu-latest`, where this file is never loaded.
> **Task 11.112 ran it by hand on Michael's Mac on 2026-09-01 and it has not been executed by any
> mechanism since**, other than by hand again on 2026-09-06 during task 11.174.
>
> **That verdict is now stated in the gate's own log rather than only here.** Before 11.174 the
> scope check counted this file as one that went missing and reddened the push gate. It now derives
> the exclusion from the file's own annotation and prints, on every Linux run,
> *"1 not loadable on this host by its own @TestOn (features/more/server_config_screen_macos_test.dart
> needs mac-os)"*. **A file nothing runs is now named in the log of the thing that does not run
> it**, every push, which is the weakest form of this document that updates itself.
>
> **It is verdict 1f's shape — run once by hand, on one machine — applied to a test rather than an
> instrument, and it is cheap to fix if anybody wants to**: a `runs-on: macos-latest` job doing
> `flutter test` would be billed at 10x, which is why nobody has. **Nothing is proposed here. The
> point is that "@TestOn kept it off the runner" and "@TestOn is why nobody notices it never runs"
> are the same sentence.**

This document answers one question asked of three populations:

| Population | The question |
| --- | --- |
| **Instruments** (`scripts/`) | Has this instrument ever been watched **detecting** its own subject being removed — as opposed to **aborting**, which is a different property? |
| **Controls** (the app, the server, the containers) | Has this control ever **executed at all**, anywhere, on any machine? |
| **Remedies** (what we tell a person to do) | Has this remedy ever been **followed by somebody it did not already work for**? |

**Why the question is "has it run", not "is it correct".** Three times now a control was
correct when written and was silently falsified by a later task — the audit purge demoted to
a role whose delete right had been deliberately revoked (11.79); a screen telling removed
members to wait for an invitation weeks after invitations were deleted (11.98); a documented
remedy that could not run in the shipped container (11.80's predecessor). **The common factor
is not the code. It is that the falsified thing was never run.** A control nobody exercises
cannot tell you it has stopped being true.

**A verdict here is not binary.** Following task 11.89's closing caveat, an item is
`NEVER RUN`, `RUN IN CI`, `RUN ROUTINELY`, or — the state most of this project's instruments
are actually in — **`RUN ONCE, ONE MACHINE, BY HAND`**. That third state is the cheapest one
to change, which is why it is ranked rather than footnoted.

---

## Method, and how it differs from task 11.88's

**11.88 asked "which gate instruments have never *passed* in CI", and answered it by reading
GitHub Actions run history.** It found two. That method can only see things a workflow already
runs, so by construction it cannot find a program nothing calls — which is exactly what the
audit purge was.

**This survey never reads run history to find candidates.** Four passes, each mechanical:

1. **Line coverage, three suites, run for this survey on 2026-09-01.**
   `flutter test --coverage` (1,909 tests, all pass), `dart test --coverage` in `server/`
   against a real Postgres (822 tests, all pass), and the same in
   `packages/tritrack_sync` (318 tests). Every zero-hit line was then filtered to lines whose
   text **refuses, deletes, expires, purges, revokes, bounds or validates** — the task's own
   definition of a control — and layout `clamp()` calls and `Delete` button labels were
   excluded by rule, not by taste. *A helper with no coverage is untested; a control with no
   coverage is a claim nobody has checked.*
2. **The population coverage structurally cannot see**: CLI entrypoints, scheduled loops,
   container healthchecks, compose- and database-level declarations, platform build config,
   and operator-invoked shell. Derived by listing `server/bin/`, every `healthcheck:` and
   `HEALTHCHECK`, every `GRANT`/`REVOKE`/`SET ROLE`, every `.sh`, and every entitlements /
   manifest / `Caddyfile` block — **then grepping the whole repository for each one's name to
   find its caller**, and grepping `TASK_COMMS.md` and `DEVELOPMENT_PLAN.md` for evidence a
   person ever ran it.
3. **Detection versus abortion, for `scripts/`.** The set of wire-speaking instruments is
   derived the way `gate_smoke_test.sh` derives it (an actual `from gate_wire import` plus a
   `preflight(` call), and the set with a detection proof is derived from
   `scripts/*_broken_control.py` and what each harness names.
4. **Remedies**, by extracting every imperative string in `lib/`, every `>&2` line in
   `scripts/` and `server/backup/`, and every "if X fails, do Y" section of the two READMEs,
   then asking of each: who does it *not* work for, and has anyone in that population ever
   followed it?

Run history was used **only to date items already found** — never to find one.

### Three method traps this survey hit, recorded so the next one does not

- **Per-suite coverage lies about a shared package.** `packages/tritrack_sync`'s own suite
  reports `membership_departure.dart` at **0%**, which looks like a dead control. It is not:
  it is exercised by `test/data/sync/membership_departure_test.dart` (24 cases) and
  `server/test/authz/leave_project_test.dart` (24), through the barrel export. **A symbol's
  coverage is the union across all three suites, and no tool here computes that union.** Four
  files flagged this way; all four resolved to false alarms once each exported symbol was
  grepped across every test tree.
- **A control can be covered by an instrument and not by a suite.** The team-size bound at
  `server/lib/src/projects/project_routes.dart:210` has zero test coverage, and
  `scripts/verify_11_9_team_surface.py:1206` attacks it on every gate run. Coverage alone
  would have reported it as never run.
- **A bare `docker compose up` starts more than the workflow's service list says.**
  `scripts/verify_c3_cleartext_defaults_stack.sh:36` runs `docker compose -f docker-compose.yml
  up --build -d` with **no service names**, so the `backup-scheduler` and `audit-retention`
  containers do start on every gate-instruments run. Reading the workflow files alone would
  have reported both as never executed.

---

## Population 1 — Instruments: watched to detect, or only watched to abort?

**26 instruments, derived from `scripts/` and `server/backup/`.** Runners (`run_*.sh`,
`server_up.sh`, `dev_*.sh`), shared libraries (`scripts/lib/`, `gate_wire.py`,
`gate_c_baseline.py`) and operational tools (`backup_db.sh`, `restore_db.sh`,
`backup_status.sh`, `audit_retention_status.sh`) are excluded — the last four are **controls**
and appear in population 2.

**The distinction that has been read as one property and is two.** `gate_smoke_test.sh`'s
self-test proves **abortion**: it forces a stale schema major and requires every wire-speaking
instrument to fail loudly rather than pass vacuously. That covers all 11 wire-speaking
instruments and is real. It is **not** evidence that any of them can detect the thing it
exists for.

### 1a. Watched to detect, by an external harness that deletes a real control — was 3, **now 5 (task 11.127, 2026-09-05)**

| Instrument | Harness | State on the runner, 2026-09-02 |
| --- | --- | --- |
| `verify_round8_server_surface.py` | `verify_round8_broken_control.py` | **green** |
| `verify_11_49_server_reads.py` | `verify_11_49_broken_control.py` | ~~**red**~~ **GREEN — Updated 2026-09-02 (task 11.125).** Run in full on a Mac: the healthy run is 187 checks clean, and all three broken variants flipped every attack they are required to flip (12/14, 9/13, 6/9 required, all satisfied). The red was one stale `BASELINE` entry, not the §4.13 question |
| `verify_11_9_team_surface.py` | `verify_11_85_broken_control.py` | ~~**red** (fails on the shared healthy-run precondition …)~~ ~~**STILL RED** — the `grant` variant patched the `_bidiFormatting` denylist clause, which task 11.89 deleted on 2026-09-02 when it replaced that denylist with an allowlist~~ **GREEN — 2026-09-05 (task 11.127).** Re-authored against the allowlist: the ten bidirectional formatting characters are added back to the permitted set, which is exactly what the deleted denylist held. Run in full on a Mac — all 17 required attacks flipped in the `owner` variant, all 12 in `grant` (including every one of the ten bidi names), all 6 in `mine`, and the same instruments came back clean against the real server |
| `verify_c1_row_naming.py` | `verify_11_127_broken_control.py` (`naming`) | **green, 2026-09-05** (task 11.127). Run in full on a Mac: healthy 14 checks, 0 failed; against a server where `_authorizeNaming`'s verdict is no longer acted on, **all 5 required reproductions flipped**, 5 consequences flipped with them, and 1 positive control broke as a broken server is expected to. **It took two runs** — the first exposed a defect in the instrument, see 1d |
| `verify_h3_existence_oracle_sweep.py` | `verify_11_127_broken_control.py` (`oracle`) | **green, 2026-09-05** (task 11.127). Healthy: 9 tables indistinguishable, 4 recorded findings, 0 unrecorded. Against a server that looks a row up without its project scope **and** lets a refusal say what it found, **all 9 flipped**. The required set is derived from the harness's own healthy run, so table ten is required to flip the day it lands |

~~**So today, one instrument out of twenty-six is demonstrably watched-to-detect on a machine
that is not Michael's Mac.**~~ **Updated 2026-09-05 (task 11.127): all five are green, and four
of the five were measured on Michael's Mac on that date. Whether they are green on a runner is
still a separate question and `broken-control-check.yml` is what answers it.**

All four harnesses verify their own patch text was found before trusting a variant
(`verify_round8_broken_control.py:248`), which closes the who-watches-the-watchmen question one
level down — **but that check runs at harness time, which is a ten-minute Docker job fired by a
path filter.** Task 11.89 deleted a patch target with a perfectly good refactor and **nothing
ran when the target changed.** `scripts/check_broken_control_patch_targets.py` now asks the same
question on every commit with no Docker, from
`test/documentation/broken_control_trigger_test.dart`: it derives the harness set from the same
filename glob, imports each one's `VARIANTS`, and requires every patch's text to appear exactly
once in the file it names. Watched red both ways on 2026-09-05 — with the historical harness
text restored, and with an ordinary-looking refactor of `row_validator.dart` from the owning
side.

### 1b. Constructs the broken world itself — 4 (weaker than 1a, not nothing)

These build the adversarial case inside their own run and require a refusal. Weaker than
deleting a control from the product, because the instrument still chooses the corpus — which
is precisely the gap task 11.71 found — but it is a real must-fail case.

| Instrument | Its internal negative case |
| --- | --- |
| `verify_i1_source_identity.sh` | step 6, *"NEGATIVE CONTROL — with the allowlist wrong, the bug must come back"*, and it fails the run if the negative arm does not reproduce |
| `verify_h6_archive_forgery.sh` | forges an archive satisfying every check `restore.sh` makes, and requires refusal |
| `backup_restore_drill.sh` | ten must-refuse steps (3, 6, 7c, 7c2, 7h–7j, 7m, 8, 10, 10c) |
| `verify_deployment_refusal_matrix.sh` | *"Ten that must refuse, two that must start"*, and it fails if no shape refuses or none starts |

### 1c. Has a detection proof that nothing ever runs — was 2, now 3. **Updated 2026-09-06 by task 11.90.** **This is the finding of this half.**

| Instrument | The proof it carries | Who runs it |
| --- | --- | --- |
| `verify_source_identity.sh` | `TRITRACK_PROBE_SELFTEST=blind-filter` and `=break-machinery` — two modes that break the probe and require it to notice. Its own header says *"Demonstrated failing: …"* | ~~**Nothing.**~~ **`gate_smoke_test.sh`, from 2026-09-02 (task 11.125).** Both modes run there now, through a new `run_detection_proof` helper that requires a *non-zero* exit **and** the specific line the right control prints when it catches the sabotage. The exit code alone was not enough: a sabotaged run exits 1 both when the control fires and when the run sails past undetected, and would exit 1 again with no Docker at all. Both were watched failing correctly on 2026-09-02 |
| `verify_instrument_unchecked_returns.py` | `--selftest`, which proves both halves live and prints `SELFTEST PASSED` | ~~**Nothing.**~~ **`gate_smoke_test.sh`, from 2026-09-02 (task 11.125)** — one extra line beside the bare run. Watched printing `SELFTEST PASSED: both halves demonstrated.` |

| `gate_timing_guard.py` | `--selftest` — **added 2026-09-06 by task 11.90**, and it is the newest member of this section rather than a newly-discovered gap. | **`gate_smoke_test.sh`, from 2026-09-06.** The guard it proves is the one that decides whether the gate's machine is quiet enough to measure a timing difference — **it was wrong for a year's worth of gates because it read the *direction* of the machine's wobble rather than its *size***, which is why R-3 existed |

The first two were demonstrated once, by hand, by the task that wrote them. **Both are cheap to
exercise** — one extra line each in `gate_smoke_test.sh` or the workflow.

### 1d. Watched to abort only — was 8, now 6. **Updated 2026-09-05 by task 11.127.**

All eleven wire-speaking instruments abort correctly under `GATE_SMOKE_SELFTEST=1`. That is
abortion, not detection: **an instrument that fails loudly when the world is wrong may still be
unable to notice the thing it exists for.**

Michael chose the top two of the ranked eight on 2026-09-05, and they are covered by a fourth
harness, `scripts/verify_11_127_broken_control.py`, run by
`.github/workflows/broken-control-check.yml`. **Marked individually rather than counted down**,
so the six that remain are nameable:

| Instrument | Detection proof | Rank and reason |
| --- | --- | --- |
| `verify_h3_existence_oracle_sweep.py` | **COVERED 2026-09-05** — `verify_11_127_broken_control.py`'s `oracle` variant. **The required set is derived from the harness's own healthy run** rather than listed, so a table added to `sync_tables.dart` is required to flip the day it lands | **1.** Widest claim in the project (*no table lets a stranger learn whether a record exists*, which §4.13's residual rests on) against the weakest evidence: no hand demonstration recorded in its header, and no positive control |
| `verify_c1_row_naming.py` | **COVERED 2026-09-05** — the same harness's `naming` variant, which stops `_authorizeNaming`'s verdict being acted on | **2.** The only live reproduction of C-1, the finding the gate was built around. Its header claimed a hand demonstration from three months ago naming no commit. Cheapest sabotage of the eight |
| `verify_d1_per_row_oracle.py` | **still none** | **3.** The same existence leak one level down — the per-row outcomes inside a `200`, which is where the leak came back after the status codes were made uniform |
| `verify_i4_email_forgery.py` | **still none** | **4.** The fix it watches has exactly one permitting branch, which is the easiest kind to delete cleanly and the easiest for a refactor to erode |
| `verify_c2_existence_oracle.py` | **still none** | **5.** C-2 itself. Below 3 and 4 only because three other instruments probe the same property, one of which now has a working proof |
| `verify_11_24_attribution.py` | **still none** | **6.** Already the best-defended of the eight: it requires legitimate requests to be *accepted* as well as attacks refused, so a server that refused everything cannot fake a clean run |
| `verify_c5_denial_audit.py` | **still none** | **7.** Highest-value property (C-5 was a *silently swallowed* database write) but the most delicate sabotage — it must reproduce a write that fails **and is swallowed**, not one that crashes |
| `gate_c_adversarial_pass.py` | **still none** | **8.** 1,087 lines, ~40 checks, its own committed baseline. A harness for it is a dozen variants, and most of what it re-runs is what 3–5 cover individually |

**What covering the top two found, and it is not what the task expected.** Both instruments had
a defect the proof exposed and nothing else would have:

- **`verify_c1_row_naming.py` could not survive its own reproduction.** Against a server with
  the naming invariant deleted, the project handover succeeds, so the attacker is no longer a
  member of the project they gave away, so their next pull is refused and carries no `rows` —
  and the script died on a bare `after["rows"]` subscript **in the middle of the reproduction**,
  before the 10.29 regression checks ran and before it could write its summary. The same line
  also accepted `owner == []` as "the stored owner is unchanged", which reads *could not look*
  as *found nothing wrong* — the confusion already closed in `backup_restore_drill.sh` and in
  `verify_c5_denial_audit.py`. Both fixed.
- **Eight of the nine tables `verify_h3_existence_oracle_sweep.py` calls indistinguishable are
  indistinguishable by construction, not by any refusal the server makes.** Measured: with only
  the opaque-outcome control deleted, exactly one table flipped — `Users`, the global one. For a
  project-scoped table the stranger's claimed key carries their own `project_id`, which has been
  *part of the primary key* since task 10.35, so the server looks up a key that does not exist
  and has nothing to disclose. The variant therefore deletes **both** controls, and which one is
  load-bearing for which tables is worth more than the flip.

**Cheap to exercise for the remaining six**: the plumbing is free — `broken_control_trigger_test.dart`
derives the harness set from the `*_broken_control.py` glob, and
`scripts/check_broken_control_patch_targets.py` derives the patch-target set from the same glob.
The work is the sabotages.

### 1e. A control exists but deleting it needs a signed rebuild — 3

`verify_ats_transport_security.sh`, `verify_session_store_keychain.sh` (both
**RUN ONCE, ONE MACHINE, BY HAND** — 2026-08-15 and 2026-08-27 on Michael's Mac, and the ATS
refusal twice on his physical iPhone), and `verify_merged_manifest_capabilities.sh`
(**RUN IN CI**, but see 2f.2 — only ever against the *debug* merged manifest).
**Needs a machine nobody has**: a GitHub runner has no Apple signing identity.

### 1f. Run once by hand, no negative control found — 2

`verify_tls_termination.sh` (7 checks, 2026-08-15, Michael's Mac — **cheap to exercise**, it
generates its own certificate) and `verify_c3_cleartext_defaults.py` / `_stack.sh`
(**RUN IN CI**; its assertions are largely reads of rendered compose — see 2e.1).

### 1g. The broken-control harnesses themselves — was 3, **now 4 (task 11.127, 2026-09-05)**

Self-pairing by construction: each requires a clean healthy run *and* a flipped broken run, and
each verifies its patch text matched. ~~**Two of the three are red on the runner right now**~~
**All four passed in full on Michael's Mac on 2026-09-05.** Their patch targets are additionally
checked on every commit by `scripts/check_broken_control_patch_targets.py` — see 1a.

### The comprehensive-search shape (11.77 item 3), checked for by name — **no live instances found**

The shape is an instrument whose final assertion is a search across a whole filesystem, log or
table, where *found nothing* is indistinguishable from *the corpus never reached it*. Checked
directly:

- `backup_restore_drill.sh:863` uses `find` over the backup directory — and **task 10.95 already
  hardened exactly this**: it asserts the directory exists before trusting an empty result,
  because the previous `ls -A .../*.part || true` read "I could not look" as "confirmed clear",
  which was reproduced with a control.
- `verify_c5_denial_audit.py:261` defines `every_row` so that an empty row list **fails** rather
  than passing vacuously, with the comment *"`all([])` is True — a check that reports PASS when
  there is nothing to check is the same silent success this finding was made of, and the first
  draft of this script had it."*

**Both known instances were found and closed by earlier tasks. This is a negative result and it
is worth as much as a positive one.**

---

## Population 2 — Controls: has it ever executed at all?

### 2a. The app (`lib/`) — 50 uncovered control lines, ~22 distinct controls

Derived from line coverage over the full 1,909-test suite. Every line below **has never
executed in any test.**

**The one that matters most: 9 of the 10 `on UnauthorizedMutation` handlers in the app have
never run.**

| Where | What a person sees when it fires |
| --- | --- |
| `project_setup_screen.dart:810, 913, 1058, 1121` | the refusal message when a viewer or contributor tries to change project settings |
| `tag_database_screen.dart:127, 190` | the refusal when they try to add or edit a tag |
| `projects_screen.dart:380` | the refusal on the projects list |
| `observation_sharing_screen.dart:282` | the refusal on the sharing screen |
| `observation_logging_screen.dart:1766` | the refusal while recording an observation |

Only `tag_database_screen.dart:437` has ever executed. **These are the user-visible half of the
role-aware write controls tasks 11.12 and 11.14 built** — the server refuses, and this is the
sentence the person reads. Nine of the ten have never been rendered. **Adjacent risk worth
naming and not resolving here: task 11.105 found that Riverpod 3 wraps provider errors, so a
typed catch at an awaited provider is unreachable. Whether any of these nine is dead for that
reason is not established by this survey and should not be assumed.** **Cheap to exercise.**

**The credential store's whole real half — `lib/data/auth/session_store.dart:143–204` — has
never executed.** `ensureWritable()`, `read()`, `write()` and `clear()` all sit at 0 hits;
every sign-in test substitutes an in-memory store. `clear()` is **the local half of signing
out**. The only thing that exercises the real keychain is
`scripts/verify_session_store_keychain.sh`, which no workflow runs (1e).
**Needs a machine nobody has in CI** — a signed Apple bundle; **cheap on Michael's Mac.**

**"Sign out everywhere" has never executed.** `server_config_screen.dart:554–560` — the call
that revokes other sessions and the sentence reporting how many were ended.
**Cheap to exercise.**

**An owner rejecting a join request has never executed.**
`membership_provider.dart:355–360` and `project_members_screen.dart:759`.
**Cheap to exercise.**

The remainder, each a refusal or a delete that has never fired:

| File:line | What it claims |
| --- | --- |
| `base_repository.dart:73` | refuses a malformed row name — the client half of the C-1 row-naming invariant |
| `migrations.dart:50, 107` | refuses to open a database it cannot migrate |
| `backup_archive.dart:91, 98, 144` | refuses a malformed restore archive (the K-1 untrusted-import surface) |
| `schema_migrator.dart:60` | refuses an archive from an unsupported schema major |
| `observation_share.dart:463, 479, 540` | refuses a malformed pasted share payload (the J-1 surface) |
| `shared_observation_importer.dart:561` | returns `refusedInvalid` for a share that fails validation |
| `unknown_columns.dart:403` | the delete inside the `UnknownColumnStore` guard (task 10.76) |
| `row_key_migration.dart:125` | the delete inside the row-key migration |
| `data_export_screen.dart:232` | the `refusedNotPermitted` branch on import |
| `observation_sharing_screen.dart:238` | `RowValidator.validate` on a tag before sharing |
| `sync_transport.dart:480` | a typed transport refusal |
| `auth_client.dart:215, 414` | refuses a malformed server response |
| `project_membership_repository.dart:613`, `sync_provider.dart:615`, `auth_provider.dart:281`, `compass_provider.dart:17` | four guard `StateError`s |
| `wmm_coefficients.dart:56, 70, 75` | refuses a corrupt magnetic-declination data file |
| `project_setup_screen.dart:450` | the GPS-fix timeout **(was recorded as :422; corrected 2026-09-03 — it was wrong before task 11.61 touched the file, and this table is read as a list of places to go and exercise, so a wrong line number sends the reader somewhere else)** |

**All cheap to exercise.**

**Three whole files have no coverage record at all:** `lib/main.dart`,
`lib/core/theme/design_tokens.dart`, `lib/widgets/placeholder_screen.dart`. None is a control.
**Five more are loaded but never executed:** `database_provider.dart`,
`sync_conflicts_provider.dart`, `sync_dropped_rows_provider.dart`,
`project_extent_picker_screen.dart`, `load_failure.dart`.

### 2b. The server (`server/lib/`) — one control, precisely

**Server coverage is genuinely good: every file is at 73% or better, and there is no
zero-coverage file.** That is a real result and it should be said plainly.

**`server/lib/src/projects/project_routes.dart:681` has never executed.** It is the branch of
`_requireOwner` that refuses — before authorization is even resolved — a project id that is
empty, longer than the maximum device-id length, or contains a control character. The
condition above it evaluates three times in the suite; **the refusal itself has fired zero
times.** Nothing in the server suite and nothing in any gate instrument sends a malformed
project id to an owner-only route: `verify_11_9_team_surface.py` sweeps all seven owner routes
but only ever with a real project id or a well-formed UUID. **Cheap to exercise.**

> **Updated 2026-09-02 (task 11.125): it executes now, and measuring it found something.**
> `server/test/integration/membership_and_joining_test.dart` sends a 201-character project id
> to an owner-only route as the owner of a real project, and requires the same refusal a
> fabricated project draws. **Two honest caveats, both measured rather than reasoned:**
>
> - **It is not a detection proof.** Deleting the whole guard and re-running leaves the test
>   green: an over-long id that reaches `ProjectAuthorizer.resolve` is refused there too,
>   because no such project is owned by anybody. What the branch buys is that attacker-chosen
>   bytes never reach a database statement, and nothing observable from outside distinguishes
>   that.
> - **The control-character arm cannot fire from a path at all.** A request for
>   `/projects/proj%00a/join-settings` arrives at `_requireOwner` as the eight literal
>   characters `proj%00a` — shelf hands the router the undecoded segment — so
>   `_hasControlCharacter` sees a percent sign and two digits. `project_routes.dart` explains
>   that arm by the bare 500 a NUL would cause in Postgres, and **from this direction there is
>   no NUL.** A second test pins the arriving shape so that a shelf upgrade which starts
>   decoding path segments fails there rather than being discovered later.

Three more never-executed lines, each with a caveat that lowers it:

- `project_routes.dart:210`, the `team_size_limit` bound — **no test coverage, but
  `verify_11_9_team_surface.py:1206` attacks it on every gate run.** Not a gap; recorded because
  the server suite alone would not catch its removal.
- `diagnostics_routes.dart`, the `limit` bounds on the **audit-event and traffic-log reads** — the
  diagnostics console is off by default and loopback-only, so the exposure is small, but the bound
  has never fired. **Cheap to exercise.** *(Line numbers dropped 2026-09-06: they were 174, 203,
  206, 207 and 218, and task 10.80's gate rewrite moved every one of them while the controls
  themselves were untouched. Same class as the `Dockerfile:61` citation the same day — a line
  number is a copy of a fact the file changes without telling anybody. Naming the read is the
  anchor that cannot rot.)*
- `sync_routes.dart:512`, the `purged_through_seq` field on a cursor-too-old error — the field a
  client needs to recover. **Cheap to exercise.**

### 2c. The shared package (`packages/tritrack_sync/`) — no findings

Four files report 0% in the package's own suite; all four are exercised by the app's or the
server's suite through the barrel export. See the method trap above. **Recorded as a checked
negative.**

### 2d. Entrypoints, schedulers and healthchecks

| Item | What it claims | Verdict | Cost |
| --- | --- | --- | --- |
| `server/bin/audit_retention.dart --once` | purges audit rows past §4.7's windows | **RUN ONCE, ONE MACHINE, BY HAND** — 11.79 ran it against a throwaway stack on Docker Desktop, *"not against your server, and not on Linux"* | cheap |
| `--schedule` (the `audit-retention` container) | sweeps without anybody remembering | **RUN IN CI, incidentally and unasserted** — started by `verify_c3_cleartext_defaults_stack.sh`'s bare `up`; nothing checks it did anything | cheap |
| `--check` **as a healthcheck** (`docker-compose.yml:407`) | exits 1 when the oldest surviving row is past its window plus grace | **NEVER RUN as a consumed signal** — no automated run lives long enough, and the only `{{.Health}}` read anywhere in the repository is postgres's | cheap |
| `--check` **as a program** | same | **RUN ONCE, ONE MACHINE, BY HAND** (11.79) | cheap |
| the role demotion to `tritrack_retention` | the purge runs as a role that may delete audit rows and nothing else — **this is 11.79's actual fix** | **RUN IN CI** — `server/test/security/retention_role_test.dart`, real Postgres, every push | cheap |
| `server/backup/schedule.sh` **success arm** | a backup happens without anybody remembering | ~~**UNKNOWN**~~ **ANSWERED ON THE BETA HOST, 2026-09-02, and the answer was a live fault.** CI still has no `TRITRACK_BACKUP_RECIPIENTS` and still takes the failure branch. On the server: **every cycle had failed since 2026-08-31** — `backup-scheduler` was running as uid 70 while `/backups` is owned by uid 1000, so it could not write, which is task 11.70's ownership problem arriving through the raw `docker compose` line rather than through `server_up.sh`. Michael diagnosed and fixed it by putting `TRITRACK_BACKUP_UID`/`GID` in the VM's `.env`; the scheduler is healthy and a fresh archive exists. **The success arm has now run on a real server** | cheap |
| the `backup-scheduler` healthcheck (`freshness.sh`) | the newest archive's age | **NEVER RUN as a consumed signal** — `interval: 15m` outlives every automated run, nothing reads that container's health | cheap |
| `server/backup/freshness.sh:44` `_is_genuine` | **a planted filename cannot make the freshness check green** — it requires minisign to verify the archive and the signed `archive=` field to equal the filename | ~~**NEVER RUN.**~~ **RUN, AND WATCHED TO DETECT — Updated 2026-09-02 (task 11.125).** `backup_restore_drill.sh` step 11 runs the real `tritrack-backup-freshness` three times against the archives the drill just wrote: with the verifying key it names the newest signed archive and says the age is verified; with a future-dated unsigned plant in the directory it ignores the plant and still names the genuine archive; **and with the key removed it believes the plant and labels the age UNVERIFIED** — which is the discriminator that makes the refusal above it evidence rather than coincidence. Drill green at 42 checks, 2026-09-02 | cheap — the drill already generates a minisign pair |
| `server/bin/server.dart` `exit(78)` | refuses to start on a configuration §4.1 forbids | **RUN IN CI** — `verify_deployment_refusal_matrix.sh`, 12 shapes | cheap |

### 2e. Container and compose declarations

| Item | What it claims | Verdict | Cost |
| --- | --- | --- | --- |
| Postgres has **no `ports:`** (`docker-compose.yml:24`) | the database is unreachable from the host | ~~**NEVER RUN as a live control.**~~ **MEASURED ON THE MACHINE — Updated 2026-09-02 (task 11.125).** `verify_c3_cleartext_defaults.py` now opens a real socket to port 5432 on both loopback and this host's LAN address, against the running shipped stack, and identifies what answers by the Postgres SSLRequest handshake so "a database is exposed" is not confused with "something else is on that port". Watched detecting: against a deliberately published Postgres it reports `postgres`, against the server's own HTTP port `something else`, against a closed port nothing | cheap — done |
| `${POSTGRES_USER:?}` etc., 6 required-variable refusals across 5 compose files | compose refuses to render without them | **NEVER RUN** — every path writes a `.env` first | cheap |
| `restart: unless-stopped` (5 services) | a schedule survives a reboot | **NEVER RUN** — nothing has killed a container and watched it return | cheap |
| `docker-compose.tls.yml:148` `0.0.0.0:80/443` **as shipped** | the proxy publishes on every interface | **NEVER RUN as shipped** — `verify_i1_source_identity.sh` and `verify_tls_termination.sh` both override it to loopback | wants a second host to mean anything |
| the uid-70 backup fallback (`server/backup/Dockerfile`, the `USER postgres` line) | who the backup container is when `TRITRACK_BACKUP_UID` is unset | **UNKNOWN** — every automated caller sources `scripts/lib/backup_user.sh` and bypasses it | needs Linux |
| `user:` on `backup`/`backup-scheduler`, `profiles: ["backup"]`, `ports: !override []`, `ENTRYPOINT []` | four declarations | **RUN IN CI** | cheap |
| **Absence:** no `read_only:`, `cap_drop:`, `security_opt:`, `pids_limit:`, `mem_limit:`, `cpus:` or `deploy.resources` in any of the five compose files | — | there is **no container-hardening or resource-bounding control in this project to exercise.** Recorded as an absence; whether one should exist is a planning question | — |

Every database-level control (`GRANT`/`REVOKE` to `tritrack_app`, the `REVOKE DELETE` on
`auth_audit_log` that task 10.83 added, `ALTER DEFAULT PRIVILEGES`, the `tritrack_retention`
and `tritrack_restore` roles, the single-row `CHECK` and task 11.10's partial unique index) is
**RUN IN CI** against real Postgres on every push. **Six items, all cheap, no gaps.**

### 2f. Operator-invoked shell and build config

| Item | What it claims | Verdict | Cost |
| --- | --- | --- | --- |
| `scripts/audit_retention_status.sh` | *"is this server still holding rows it said it would delete?"* in one word | ~~**NEVER RUN.**~~ **RUN IN THE GATE — Updated 2026-09-02 (task 11.125).** Michael confirmed he has never run it (*"not that I can remember"*), agreeing with the survey. It now runs inside `gate_smoke_test.sh` against that run's own stack, scoped by a new `COMPOSE` override so it cannot start an unrelated project's database to answer a question about the gate's. Watched answering on 2026-09-02: three classes reported, *"RETENTION IS BEING APPLIED — nothing on this server is past its window."* | cheap |
| `scripts/restore_db.sh` | verifies the archive's `.sha256` **on the host** before handing anything to the container, and refuses when the age identity file is absent | **NEVER RUN — confirmed by Michael, 2026-09-02: never run by hand.** The drill restores via the container command directly and bypasses this wrapper. `RELEASE_CHECKLIST.md:119` (D2) still asks for a hand restore | cheap — one archive and one key |
| `scripts/backup_db.sh`'s signing-key refusal | *"refusing to take a backup that would be silently unsigned while .env says otherwise"* | **NEVER RUN** — it fires only when the key path is set and wrong | cheap |
| `scripts/verify_source_identity.sh --assisted` | the only thing that licenses `TRITRACK_TRUSTED_PROXIES=peer-verified` | **NEVER RUN.** `RELEASE_CHECKLIST.md:118` (D1) open; asked across five separate comms entries | **needs a machine nobody has** — the real beta host and two off-host devices |
| `scripts/run_e2e_tests.sh` (15 files, ~60 tests) | the two-people-one-project suite, including authorization denial, refused-row visibility and the membership-cycle matrix | **RUN ONCE, ONE MACHINE, BY HAND** — 60/60 green 2026-08-29. **No workflow runs it**, by a deliberate decision recorded in `TASK_COMMS.md:5043` with a revisit trigger: *"after ten consecutive green runs or on the next unexplained failure."* ~~**Nothing counts the runs, so that trigger cannot fire.**~~ **The counting exists — Updated 2026-09-02 (task 11.125).** `run_e2e_tests.sh` now appends one committed line per run to `test/e2e/run_log.tsv` and prints the current streak of consecutive green runs, naming the threshold; a red run prints the trigger's other half instead. Committed on purpose, so the streak is a fact about the project rather than about one laptop — and therefore a floor, since a run whose line is never committed is invisible. First line written 2026-09-02: **74/74 green.** | cheap |
| `verify_merged_manifest_capabilities.sh` | catches a permission Gradle merged in from a plugin | **RUN IN CI — against the *debug* merged manifest only.** `build-check.yml` runs `flutter build apk --debug` and the script defaults to `merged_manifest/debug/…`. **Debug is the variant that merges in the cleartext exemption**, so the guard's strongest property is measured in the configuration where the control is deliberately off — the shape task 10.54 named ~~cheap — one `flutter build apk --profile` and a second invocation with the path as `$1`~~ **DONE 2026-09-02 (task 11.125).** `build-check.yml` now builds a profile APK and runs the guard against its merged manifest as well. Measured the same day: **debug carries `usesCleartextTraffic="true"` and profile and release do not**, and the two manifests otherwise declare an identical set of permissions and components — which is the answer this step exists to keep true |
| `macos/Runner/Release.entitlements` and `Release-Signed.entitlements` | app sandbox on, `network.server` absent, keychain access group | **NEVER RUN, structurally.** `flutter drive` refuses release mode and profile builds use the debug entitlements, so no harness can reach these files. The substitute is `test/platform/macos_keychain_entitlement_test.dart`, which pins the signed file byte-identical to its debug counterpart apart from the keychain block — drift prevention, not a run. **The script says this in its own header rather than leaving it to be discovered** | **needs a machine nobody has** |
| `proxy/Caddyfile`'s ACME / Let's Encrypt branch | certificate issuance for a real deployment | **NEVER RUN** — every run to date sets `TRITRACK_TLS_DOMAIN=localhost`, and `verify_tls_termination.sh:134` *asserts* the internal CA was used | **needs a machine nobody has** — a real domain, real DNS, ports 80/443 open |
| Android manifest permissions and `android:exported` | — | **RUN ONCE, ON AN EMULATOR** (11.66, 2026-08-31). `RELEASE_CHECKLIST.md` H8 still open for a real magnetometer, real GPS drift, and a device without Google Play services | **needs a machine nobody has** |
| `scripts/backup_status.sh`, `scripts/server_up.sh`, `scripts/dev_magic_link.sh`, `scripts/dev_lan_address.sh` | four operator wrappers | **ASKED AND ANSWERED, 2026-09-02 (task 11.125).** `server_up.sh`: **not used.** Michael starts the stack with `docker compose -f docker-compose.yml -f docker-compose.dev-lan.yml up --build -d` — **and until 2026-09-02 the script could not express that**, because it appended everything after `up` while `-f` must come before it. That is why it is not used, and it is why the beta host's scheduler ran as the wrong user for two days. Fixed: `-f` and `-p` are now hoisted, and the script prints the scheduler's uid beside the `backups/` directory's owner afterwards. `backup_status.sh` **was** used, and it is where the disagreement below was seen | cheap |

---

## Population 3 — Remedies: followed by somebody they did not already work for?

**29 remedies surveyed** (14 app-facing, 9 operator messages, 6 documented procedures, 0 server
error bodies — the server returns machine codes only and never prose, which is the right design
and is why that group is correctly empty). Triaged out: pure state description, reassurance
clauses attached to remedies, instrument `PASS`/`FAIL` lines, and confirmation-dialog copy.

**17 of 29 have never been followed by anybody.** Four have been **followed and failed** — all
four in the 11.80 shape: right diagnosis, remedy that could not fix the case in front of the
reader.

### Falsified — names a mechanism that does not exist

1. **"Check your email, then paste the code below."** — `lib/features/more/screens/server_config_screen.dart:805`, with `EMAIL ME A SIGN-IN CODE` at `:807` and *"Paste the code (or the whole link) from the email"* at `:813`. **There is no email sender in this codebase.** `resolveEmailSender` (`server/lib/src/auth/email_sender.dart:168`) has exactly two branches: a file writer that refuses to exist under `TRITRACK_ENV=production`, and `NullEmailSender`, which accepts and drops. **So on a production deployment the app tells a person to check an inbox nothing will ever arrive in**, and `/auth/magic-link` answers `202` either way because §4.5 requires it to. This is documented in `README.md:672` and `server/README.md:219` as a *development* inconvenience; **what is not recorded anywhere is that the app's own sign-in screen makes the promise.** Highest-severity item in this survey — it is the first thing a beta user does. **Cheap to establish; the fix is a decision, not a line.**
   > **Closed 2026-09-01, after this survey was taken.** Michael chose to change the
   > screen rather than build a mail sender. It now says delivery depends on how the
   > server is set up, that the app cannot tell which way, and to ask whoever runs it —
   > **deliberately not "this server does not send email"**, which would be true today
   > and false on every installed build the day somebody adds one.
   > `test/documentation/sign_in_delivery_vocabulary_test.dart` guards it, and was
   > watched failing against the old copy before being trusted. **The rest of this
   > survey is unchanged and remains a snapshot of 2026-09-01.**
2. **"Refresh the list to see where it stands."** — `lib/data/sync/sync_transport.dart:334`, shown when an owner taps Approve or Reject on a request that is no longer open. **The screen it appears on, `project_members_screen.dart`, has no `RefreshIndicator`, no `onRefresh`, no `invalidate` and no refresh button.** Verified by grep. **Cheap.**
3. **"its records need to be reconciled before it can sync again."** — `sync_transport.dart:295`, when a device has been offline past the tombstone retention window. **There is no reconciliation feature in `lib/`** — the only matches are offline-map tile bookkeeping. The comment above it is honest that there is no automatic fix; the sentence still ends in an action the reader cannot take. **Cheap to force in a test; has never been forced.**
4. **"Update the app"** — four sites (`sync_transport.dart:367`, `held_row_details.dart:188, 251`, `sync_status_screen.dart:215, 228`). Falsified in effect: **there is no update channel.** iOS installs signed with a free Apple ID expire in about seven days; Android needs somebody to build an APK and hand it over. A biologist in the field reading this has no action available. **Needs two devices on different builds.**
5. **"copy these off this machine"** — `scripts/backup_db.sh:59`, plus *"run the drill on the documented cadence"*. **There is no destination** (this is 11.80's open remainder) **and I could not find a stated cadence anywhere.** The script still prints the instruction as though it were followable. **Blocked on Michael's destination decision and NAU's answer.**

### Followed and failed

- **Rate-limit copy** (`server_config_screen.dart:45`): *"Wait about fifteen minutes and try again"* answers a 429 — but the cap a person actually trips is the **per-address** one (three per fifteen minutes), which returns a byte-identical `202` by design, so they get "Check your email" instead and this message rarely appears.
- **Held-row retry** (`held_row_details.dart:362`): *"Tap Try again"* re-sends an identical row for a deterministic refusal and gets an identical refusal. `DEVELOPMENT_PLAN.md:18202` already states the rule this breaks.
- **Rate-limit reset in `README.md:767`** hands the operator a bare `docker compose` line — the exact invocation `permissions.sh` and `host_user.sh` both name as the origin of the root-owned-directory failure that stranded a real backup.
- **The pre-11.80 backup ownership message**, already fixed.

### Never followed, and the population they would fail for is named

`restore.sh:190` and `:309` both tell an operator to **fetch another copy from somewhere else** — and `server/README.md:593` says in as many words that nothing carries an archive anywhere else. `server/README.md:279` tells somebody to revoke a colleague's sessions in `psql` *"with a `WHERE user_id = …` clause"* and **never says how to find a user id.** `server/README.md`'s four-step secret rotation gave no command for creating or revoking a Postgres credential, and step 2 (edit `.env`, restart) **does not change the password on an already-initialized volume** — ~~*flagged as uncertainty; settled by running the four steps against a stack with an existing volume*~~ **CONFIRMED and CLOSED by task 11.128, 2026-09-02: run against exactly that, and the rewritten procedure carries the SQL.** Sixteen *"ask an owner to change your role"* strings say "an owner" generically while `project_members_screen.dart:253` shows the right form — it names them.

### The counter-example worth protecting

`server/backup/permissions.sh:83–128` is the **only** remedy in this repository that was
rewritten because a real reader followed it and it failed. Its structure — put the remedy that
works for the reader the other one failed **first**, and say out loud that following the other
one was not their mistake — is the shape the falsified items above should be fixed into.
`held_row_details.dart:124` (task 11.122's honest default) is the other model: it offers
retyping as *a thing to check*, not as the answer.

---

## Ranking, so this can be scheduled rather than admired

**Tier 1 — cheap, and each closes a claim nobody has checked.** One line each, or close to it:
the two instrument self-tests nothing runs (1c); `nc -z` against Postgres (2e);
`scripts/audit_retention_status.sh` in the gate run (2f); the `--profile` merged manifest
(2f); the malformed-project-id refusal (2b); the nine permission-refusal handlers (2a).

**Tier 2 — cheap but larger.** A fourth broken-control harness for the eight instruments in
1d; the `SessionStore` real-storage half; e2e in CI, or at least something that counts its
green runs so its revisit trigger can fire.

**Tier 3 — decisions, not work.** The sign-in screen's email promise; the off-host backup
destination (11.80's remainder, waiting on NAU); the D1 source-identity attestation.

**Tier 4 — needs a machine nobody has.** The macOS release entitlements; the ACME branch; the
non-Pixel Android device and the phone without Google Play services.

---

## Where this derivation stops

**Per the rule task 11.84 established: a document with one derived section teaches a reader to
trust the rest of it, so the boundary belongs here rather than only in a report.**

- **Populations 1 and 2 are derived.** The instrument set, the wire-speaking subset, the
  coverage figures, the caller sweeps and the compose/database/platform enumerations are
  mechanical and reproducible by the commands in the Method section.
- **Population 3 is triaged, not derived.** Which strings count as remedies is a judgment call.
  ~46 of 64 app strings and ~60 of 82 operator lines were excluded by stated rules, but a
  different reader would draw the line differently. **Treat its count as a floor.**
- **"Has it ever run on a machine that is not in this repository" is not derivable from this
  repository.** Every `UNKNOWN` above is unknown for that reason, and most are settled by
  asking Michael one question.
- **Coverage is per-suite, and no tool here computes the union across the three suites.** For
  `packages/tritrack_sync` this was resolved by hand, symbol by symbol. **A future zero-coverage
  finding in that package must be checked the same way before it is believed.**
- **Nothing here was fixed, and nothing here was re-measured against a running beta server.**
  The verdicts are as of 2026-09-01, on this working tree, plus GitHub Actions history read on
  2026-09-02 for dating only.
- **That last sentence stopped being true on 2026-09-02**, when task 11.125 ran part of this
  list. Every verdict it changed is marked `Updated 2026-09-02` in place, and the section below
  holds what running things turned up that surveying could not.

---

## What running it found that reading it could not — 2026-09-02, task 11.125

**Four findings, none of which is visible from a working tree.** They are recorded here because
this document is where the next reader looks, and each is also filed for the planning session
in `TASK_COMMS.md`.

1. **Backups on the beta server had been failing silently since 2026-08-31.** The scheduler
   could not write to `/backups`, and per this survey's own item 4 nothing in this project reads
   a container's health, so nobody was going to be told. Diagnosed and fixed by Michael on
   2026-09-02. **A newest archive two days old on a daily schedule is not evidence that backups
   work; it is the symptom that they stopped.**
2. **`scripts/backup_status.sh` claimed it and `docker compose ps` "can never disagree", and
   they disagreed.** Same program, same directory, **different identity**: the script runs the
   container as the person typing, the scheduler ran as uid 70, and so the scheduler reported
   *freshness unknown* while the script reported *50 hours old, backups have stopped*. Both were
   truthful about what they could see. The header is corrected, and now says that a disagreement
   between the two **means the scheduler cannot read the directory** — which is the fault, not
   the noise.
3. **`scripts/server_up.sh` could not express the only way this stack is started** — the reason
   it is unused, and therefore the reason the ownership fix it exists to apply never applied.
   Fixed (see the wrappers row above).
4. **The documented secret-rotation procedure does not rotate anything, and breaks the server.**
   Run against a throwaway stack with an existing Postgres volume on 2026-09-02:
   `server/README.md`'s four steps leave the database still accepting the **old** password —
   `POSTGRES_PASSWORD` is read only by `initdb`, so on any existing volume it changes what the
   server presents and nothing else — after which the server starts, cannot connect, and serves
   `/health` **and nothing else**. `/health` answered `200` throughout. The missing step is an
   `ALTER ROLE <user> WITH PASSWORD '<new>'` before the restart; with it, everything works.
   **Reported rather than repaired**: rewriting an operator procedure is a task, not a batch
   item. **And `/health` returning 200 on a server with no database is its own finding** — it is
   the one probe an operator or an uptime monitor uses.

   **BOTH CLOSED by task 11.128, 2026-09-02.** The rotation procedure is rewritten around the
   `ALTER ROLE` and **run verbatim against a stack with an existing volume**, twice, plus once
   in the wrong order to see the failure. Two further traps were measured while running it and
   are now in the text: `docker compose restart server` does **not** pick up a changed `.env`
   (it needs `up -d --force-recreate server`), and a `psql` check aimed at `127.0.0.1` *inside*
   the postgres container ignores the password entirely, because the official image ships
   `host all all 127.0.0.1/32 trust` — **the first run of this drill checked the rotation that
   way and reported the old password still working.** The check was blind, not the rotation.
   `/health` keeps its `200` and is now stated to be a liveness probe; readiness is a new
   `GET /ready`, measured answering `503 {"degraded":["database"]}` on a database-less server
   and on a server whose database was stopped underneath it.
