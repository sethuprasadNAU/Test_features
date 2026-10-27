# One derivation owns the container count

**Task 11.297, 2026-09-21.**

The number of long-running containers this project ships is not an opinion. It is
`docker-compose.yml` plus `docker-compose.tls.yml`, minus any service behind a Compose
profile. It has been hand-carried into prose instead, and it has gone stale in every place
that carried it, twice: task 11.79 made "four" into five and nobody carried it back; task
11.290 made "five" into six on 2026-09-20, caught a day later only because task 11.287
happened to be reading those documents for another reason.

This is the same class task 11.52 fixed for setup steps
(`CLAUDE_DOCS/SETUP_OWNERSHIP.md`) — a fact copied by hand instead of pointed at, and the
copy going stale is wrong instructions somebody follows (or, here, a wrong number a system
administrator checks against `docker compose ps`). **A count is not a step**, so 11.52's
guard never looked for it. This document and
`test/documentation/container_count_test.dart` are the same idea applied to a number instead
of a sentence.

## The derivation

```
docker compose -f docker-compose.yml -f docker-compose.tls.yml config --services
```

run with dummy values for every `${VAR:?...}` the two files require (extracted from the
files themselves at test time, not hand-listed here, so a third required variable does not
silently go unfilled). `--services` already excludes anything gated by `profiles:` unless
that profile is explicitly activated — that is `backup`, a one-shot job the base file
deliberately keeps out of `docker compose up`. The test runs this for real, once, and counts
the lines. **This is why `docker compose` and not a hand-rolled YAML parser**: it resolves
merges, overrides and anchors the same way an operator's `up` does, which is the only reading
of "the count" worth enforcing.

As of 2026-09-21 that command prints seven services: `postgres`, `server`, `proxy`,
`backup-scheduler`, `audit-retention`, `project-destruction`, `tombstone-retention`.

## Two ways a document can hold this number

### Live — the document describes the deployment as it is today

Its stated count must equal the derivation, every time the test runs. If it does not, the
document is wrong and the test fails. There is no list of *which* numbers are wrong to keep
in step — the test reads the file, finds every place it states a container count, and checks
each one against the derivation itself.

| Document | Kind |
| --- | --- |
| `CLAUDE_DOCS/SERVER_DEPLOYMENT_PRIMER.md` | Live |
| `CLAUDE_DOCS/TriTrack-server-architecture.html` | Live |
| `CLAUDE_DOCS/TriTrack-server-deployment.html` | Live |
| `CLAUDE_DOCS/TriTrack-server-architecture.svg` | Live |

**The SVG was missing from this table until 2026-09-21 and the test caught it on its first
run after a service was added** — task 11.291 drew the new box and wrote the new total into
the picture, and the picture had never been registered. **That is the instrument working**:
the count went into a sixth place nobody had decided to allow, and the failure said so in
those words rather than silently passing. It is Live for the obvious reason — it is a diagram
of the deployment as it is.

**One second shape, and it is checked against a different number.** `TriTrack-server-architecture.html`'s
table describes the containers *other than* `postgres` as the ones that reach it — *this
deployment's total minus one*, a different quantity from "how many containers does this
deployment run," stated that way because the sentence is about what can reach the database
rather than about the whole stack. A phrase of the form "the other N containers" is not a
total-container claim, so it is not checked against the derivation itself — it is checked
against **the derivation minus one**. Every other phrase in a Live document **is** a
total-container claim and is checked against the derivation directly.

**This was a hole until task 11.300 (2026-09-21).** "The other N" is checkable, and leaving it
unchecked meant one hand-maintained count sat inside the instrument built to abolish
hand-maintained counts. Before fixing it, 11.300 asked whether "the other N" always means "all
but the one this row is about" — the only way that reading could be wrong is if some other
document used the same phrase for an unrelated subset. It does not: the phrase appears exactly
once anywhere this instrument scans, in the sentence quoted above, so the single occurrence is
the whole population and the reading holds by inspection, not by assumption. If a second
occurrence with a different meaning is ever added, this paragraph is the place to record the
disagreement and reconsider — reading everyone's mind about what an English phrase means is not
this instrument's job, and it does not try.

### Record — the document reports what someone was told, at the time they were told it

`NAU_infosec_review_request.md` is the one live example. It is a superseded, unsent letter
kept **because** it records what an administrator would have been told on the day it was
drafted — correcting its stale numbers to match today would destroy the only reason it is
still in the repository. The letter states old counts (four, then five) in at least three
places, on purpose, and must go on doing so even after the true count changes again.

**A record still has to say what is true today, visibly, in the same file** — otherwise a
reader who opens it has no way to know the number they are looking at is history rather than
fact, which is exactly the failure this task was filed to stop. The declaration this project
uses is a literal sentence, already the house style in this file before this task:

> the count is **six**

with the number spelled as a word and matching the derivation. **The test requires this exact
phrase, with today's true count, to appear somewhere in a document declared Record below.**
If the true count changes and nobody updates the phrase, the test fails — a stale
declaration is exactly as wrong as a stale description, and this is how it is caught.

| Document | Kind | Required phrase (number is today's derived count, spelled out) |
| --- | --- | --- |
| `CLAUDE_DOCS/NAU_infosec_review_request.md` | Record | `the count is **{count}**` |

This is checked **once per file**, not once per stale number in it — a record is allowed to
repeat an old count as many times as its own history needs, and the one sentence above is
what keeps the whole file honest about what is true now. Where a stale number sits far from
any restatement — the letter's draft-email bullet said "five Docker containers" with no
nearby correction at all, found while building this instrument — add a human-visible note
near it anyway (this task added one to the "Notes for whoever next edits this" section); the
test does not require that placement, but a reader scrolling straight to the number should
not have to find the top-of-file banner to learn it is old.

## Anything else that states a count is an uncovered copy

A file that says "N containers" (or "N long-running containers", "N Docker containers") and
is not in either table above, and is not one of the excluded files below, fails the test
outright: it is a sixth place for this number to go stale that nobody decided to allow.

**Excluded from the search entirely** — append-only records of what was said at the time,
the same three files `SETUP_OWNERSHIP.md` excludes, plus this document and its test (which
have to quote example numbers and the literal declaration phrase to describe them) and
`.claude/commands/` (a command file narrates the task that wrote it and is deleted when that
task closes — see `command_file_staleness_test.dart` — so it is history, not a document
anyone is meant to still be reading for a current fact):

- `CLAUDE_DOCS/DEVELOPMENT_PLAN.md`
- `CLAUDE_DOCS/TASK_COMMS.md`
- `CLAUDE_DOCS/CONTAINER_COUNT.md` (this file)
- `test/documentation/container_count_test.dart`
- everything under `.claude/commands/`
- `scripts/verify_round8_server_surface.py` — **not a false start on the guard, a different
  word sense.** "those three containers" there is the sync response's row lists
  (Observations/Tags/Deployments), in a security probe about confusing one for another.
  English has one word for both; this instrument watches Docker's.

## The 11.52 boundary question

Task 11.297 asked whether `setup_step_ownership_test.dart` should have covered this and
where the line sits. Answered in the 2026-09-21 report to `CLAUDE_DOCS/TASK_COMMS.md`: a
setup step's guard works by finding a fixed **signature substring** and requiring the owner
to still contain it — that mechanism cannot express "this document's number must equal
whatever a shell command prints today," because a signature is checked for presence, not
recomputed. The boundary is the same one 11.52's own table draws between guarded rows (a
fixed string) and unguarded ones (prose no substring safely matches): a *value that changes
over time and is derivable* is a third category neither table has a column for, and it
needs its own instrument rather than a stretched row in that one. This file is that
instrument's home, not an extension of `SETUP_OWNERSHIP.md`'s table.
