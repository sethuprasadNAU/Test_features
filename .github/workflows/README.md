# Continuous integration — what runs, and what deliberately does not

**Task 11.40.** Before 2026-08-29 nothing in this repository ran on a commit.
Everything below is new, and so is the honesty about its edges.

**Read `CLAUDE_DOCS/RELEASE_CHECKLIST.md` before trusting a green run here.**
It is the other half of this directory: the list of checks that a machine
cannot perform, which therefore have to be performed by a person before a
release. A green badge that omits them would be read as coverage, and this
project's most-repeated finding is that *a check which cannot fail for the
reason you care about is not a check*.

**Paused 2026-10-02 (task 11.325): none of these starts by itself, except the site's publish.**
The code changes many times a day and Actions minutes are limited, so every workflow below
starts only when somebody presses *Run workflow*, and the same checks run as one batch on
Michael's own machines (`scripts/nightly_check.sh`: the Ubuntu VM for the gate and the
broken-control drills, the Mac for everything else). `website.yml` still publishes the site,
but only on a push that changes `website/**`. **The "Runs on" column below is what each one
did, and what it will do again once restored** — each workflow's header holds a dated notice and
a comment with its old triggers, and `CLAUDE_DOCS/RELEASE_CHECKLIST.md` (row B0) says when to
restore them: before a release, or when development slows.
`test/documentation/ci_pause_test.dart` fails if a notice and a workflow disagree.

| Workflow | Runs on (when restored) | Covers | Wall clock |
| --- | --- | --- | --- |
| `offline-suite.yml` | every push, every pull request | `flutter analyze`, **that the committed generated files (`*.g.dart`, `*.freezed.dart`) are what `build_runner` writes from the committed sources** (`scripts/check_generated_files_current.sh`, task 11.318), and the `flutter test` suite, with the server stack verified down | ~5 min |
| `server-suite.yml` (job `server-suite`) | every push, every pull request | `server/`'s Postgres suite in Docker | ~6 min |
| `server-suite.yml` (job `gate-coverage`) | every push, every pull request | **that `gate_smoke_test.sh` still runs every instrument it says it runs (the count is the last line of any run)** — and nothing else. **No instrument executes, no server is reached and no control is exercised**; it reads `scripts/` and reports whether every line that runs something is still claimed by a `# gate-instrument:` declaration. Task 11.173 | ~0.2 s of check, inside a job that costs whatever a runner takes to start and check out |
| `gate-instruments.yml` | pushes touching the server, the wire, the scripts or the compose files; manually; **and nightly at 04:00 UTC** (switched off 2026-09-10 to save Actions minutes, task 11.221; back on 2026-10-01, task 11.318) | every committed gate instrument, against a stack the run brings up itself — including `verify_smtp_delivery.sh`, which pulls one test-only mail-catcher image **pinned by digest** and fails with "COULD NOT PULL" rather than passing if it cannot | ~15 min |
| `broken-control-check.yml` | pushes touching the sync envelope or the auth routes; manually | breaks the server on purpose and requires the round-8 instrument to notice — the only evidence its 152 checks can fail | ~15 min |
| `tile-credit-freshness.yml` | weekly (Mondays 07:00 UTC); pushes touching the map credits or the probes; manually | asks the three tile providers whether they still publish the credit strings the app hard-codes — showing them is a licence condition, and one was already stale | ~3 min |
| `build-check.yml` | Android: every push, every pull request (free, Linux). iOS + macOS: **manually only** — see `CLAUDE_DOCS/RELEASE_CHECKLIST.md` | the app actually compiles and packages on all three platforms, plus (Android) that the manifest Gradle merges in from plugins still matches `CLAUDE_DOCS/CAPABILITY_MATRIX.md` | Android ~5 min (free); iOS + macOS ~20–30 min, billed at macOS's 10x rate — task 11.76 |

## What none of these workflows cover

- **Anything the operating system grants.** The keychain, App Transport
  Security, location, background modes, security-scoped bookmarks. See
  `CLAUDE_DOCS/CAPABILITY_MATRIX.md` for the enumeration and
  `RELEASE_CHECKLIST.md` for who runs what.
- **`integration_test/`.** Both files there need a *signed* app bundle on real
  hardware. A GitHub-hosted runner has no signing identity, and the macOS
  keychain test is specifically the one that fails with `-34018` on an
  ad-hoc-signed build — so a CI run of it would fail for the wrong reason, or,
  worse, be quietly configured until it passed for the wrong reason.
- **The end-to-end suite (`test/e2e/`).** Not because it cannot run — it can,
  and it was 60/60 green on 2026-08-29 — but because it has a known
  intermittent failure whose diagnosis is not finished (task 11.40 item 3).
  Adding a job that goes red for a reason nobody can explain trains people to
  ignore the red. **Revisit after the next ten green runs, or on the next
  unexplained failure, whichever comes first.**

**Nothing here has run on GitHub yet.** Every script these workflows invoke was
run locally, in the shape the workflow invokes it — but no workflow file can be
executed from a developer's machine. The first push is the first real test.
