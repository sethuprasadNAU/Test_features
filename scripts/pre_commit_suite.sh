#!/usr/bin/env bash
# gate-instrument: none - the local pre-commit runner, fired by a commit on a developer machine; it runs the Flutter suite the gate deliberately does not.
#
# Runs `flutter test` before a commit and refuses the commit if it is red.
#
# **Task 11.180, 2026-09-06.** `flutter test` was red on `main` at commit
# 1d4bfd5 and the commit went in anyway. Nothing was ignored: task 11.178 ran
# the two test files it had written, and its own report says exactly that. The
# failing test was in `test/documentation/app_shell_harness_default_test.dart`,
# a file that task never opened — **only a full run reaches it.** Michael
# pushes in batches to save Actions minutes, so the push gate that would have
# caught it can be a dozen commits away.
#
# Wired as a `PreToolUse` hook on `Bash` in `.claude/settings.json`, so it
# binds every commit any of this project's Claude windows makes. **It does not
# bind a commit typed into a terminal by hand**, and it should not be described
# as if it did.
#
# **Why the whole suite rather than a cheap subset.** `test/documentation/`
# runs in 11 s against the full suite's 96 s and holds the guard that fired
# here — but a partial run that prints "green" is the lying instrument this
# project keeps finding, because the only sentence anybody would read it as is
# "the tests pass". A path filter fails for a second, measured reason: a
# **Markdown-only** commit can turn this suite red, and has (task 11.170's
# second red was a `.claude/commands/*.md` file breaking
# `setup_step_ownership_test.dart`), so "only run it when Dart changed" would
# have missed a real one.
#
# **What this hook covers and what it does not — task 11.182, and it is here
# because the gap bit within a day.** The commit that built this hook was the
# commit that turned CI red, over two files under `scripts/` carrying no
# `# gate-instrument:` declaration, **and this hook could not have caught it**:
# it ran `flutter test` and that check lives in a workflow. So it now also runs
# the gate's `GATE_SMOKE_COVERAGE_ONLY=1` derivation, measured at **0.85 s**
# against the suite's 96 — under one percent, and it goes first.
#
# **Five checks still live only in CI, and this is the list somebody surprised
# by a red should find instead of the surprise:**
#
#   - `server-suite.yml` — the Dart server suite, which needs Postgres in
#     Docker. Minutes, and a stack; deliberately out.
#   - `offline-suite.yml` — the Flutter suite run with the server stack
#     **down**, plus `packages/tritrack_sync`'s own `dart test`. Its whole
#     premise is a machine state this hook cannot assert.
#   - `gate-instruments.yml`'s full run — 23 instruments against a live
#     stack. Only its coverage derivation is cheap enough to run here.
#   - `broken-control-check.yml` — the detection proofs, which need a
#     deliberately broken server and a `dart compile exe`.
#   - `build-check.yml` — the platform builds, and `website.yml`.
#
# **Since 2026-10-02 (task 11.325) none of those five starts by itself on GitHub**: the
# workflows run only when somebody presses the button, and the same checks run as
# one local batch, `scripts/nightly_check.sh`. The list above is what the batch
# covers and this hook does not, so it is still the list to read after a surprise.
#
# **A commit that is green here can still redden any of those**, and nothing
# local will say so. That is a cost accepted rather than an oversight.
#
# **The escape, and why there is one.** Three windows share this working tree,
# so a red is often not the committer's — task 11.127 met exactly that and was
# right to decline the fix. Prefixing the commit with
# `TRITRACK_PRECOMMIT_RED_IS_PREEXISTING=1` skips the run. It is written into
# the command string rather than the environment so it is visible in the
# transcript, it says out loud that nothing was verified, and using it obliges
# you to say so in your `CLAUDE_DOCS/TASK_COMMS.md` entry.
#
# **A red keeps its evidence — task 11.294.** Until 2026-09-20 the runner's
# JSON stream was deleted on every exit, so the refusal named the failing test
# and then destroyed the only copy of its exception. Diagnosing a load-dependent
# red cost task 11.287 a second full run just to read the message the first run
# had already produced. That is the cleanup-that-runs-unconditionally class
# (defect vocabulary 84): a teardown that cannot tell green from red has decided
# that no failure will be diagnosable. So: a green run deletes its stream, a red
# run keeps it and the refusal prints the path. The kept file is the raw
# `flutter test --reporter json` output; the failing test's `print` events (a
# pending timer's creation stack, for one) are in there under its `testID`.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# **The trace, and why an always-on one earns its line — task 11.182.** A
# `PreToolUse` hook's stdout on a successful run is not shown to the window
# that triggered it, so from inside a Claude session there is no observable
# saying this ran. Task 11.181 tried to measure it with `time git commit …`
# and got 0.088 s against a 96-second suite, and reported the hook dead. The
# number was real and it was of the wrong quantity: the hook completes
# *before* the command being timed starts, so `time` around a commit is
# structurally incapable of containing it. **The hook had been running the
# whole time.** This file therefore says so itself, in a place a person can
# read afterwards, for the two branches worth recording — a commit, and a
# refusal. The hundreds of not-a-commit calls a session makes are not logged;
# they are the noise that hid the parse failure below for a week.
TRACE_LOG="${TRITRACK_PRECOMMIT_TRACE:-${TMPDIR:-/tmp}/tritrack-precommit-trace.log}"
trace() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$TRACE_LOG" 2>/dev/null; }

payload="$(cat)"

# **Reading the payload was this hook's most dangerous act until task
# 11.182.** The reader was `except Exception: sys.exit(0)` with `2>/dev/null`
# after it, so an unreadable payload produced an **empty** `tool_command`,
# which failed the is-this-a-commit grep below, which exited 0 — and that is
# byte-for-byte what a genuine non-commit does, hundreds of times a session.
# **A parse failure and "this was not a commit" were the same observable**,
# which is this project's cannot-distinguish-success-from-its-own-failure rule
# living inside the instrument built to enforce discipline. So: **a hook that
# cannot read its input must not exit 0.** It refuses, loudly, and the refusal
# names the one thing that can be done about it — there is no
# `TRITRACK_PRECOMMIT_RED_IS_PREEXISTING=1` escape here, because that escape
# is read out of the very command string that could not be read.
if ! command -v python3 >/dev/null 2>&1; then
  trace "REFUSED: python3 is not on PATH"
  echo "pre-commit suite: python3 is not on PATH, so this hook cannot read" \
       "its own input and cannot tell a commit from anything else. It is" \
       "refusing rather than passing silently. Install python3, or remove" \
       "the PreToolUse hook from .claude/settings.json." >&2
  exit 2
fi

parse_status=0
tool_command="$(
  printf '%s' "$payload" | python3 -c '
import json, sys
data = json.load(sys.stdin)
tool_input = data.get("tool_input")
if not isinstance(tool_input, dict) or not isinstance(tool_input.get("command"), str):
    sys.stderr.write("payload parsed as JSON but carries no tool_input.command string\n")
    sys.exit(3)
sys.stdout.write(tool_input["command"])
'
)" || parse_status=$?

if [[ $parse_status -ne 0 ]]; then
  trace "REFUSED: payload unreadable (reader exit $parse_status, ${#payload} bytes)"
  echo "pre-commit suite: could not read the hook payload (reader exited" \
       "$parse_status over ${#payload} bytes), so it does not know whether" \
       "this Bash call is a commit. It is refusing rather than exiting 0," \
       "because until task 11.182 those two looked identical and this hook" \
       "was believed dead for a week. Fix the payload reader, or remove the" \
       "PreToolUse hook from .claude/settings.json." >&2
  exit 2
fi

# Anything that is not a commit is none of this hook's business.
if ! grep -qE '(^|[^[:alnum:]_.-])git([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+commit([[:space:]]|$)' \
  <<<"$tool_command"; then
  exit 0
fi
trace "COMMIT: $(head -c 160 <<<"$tool_command" | tr '\n' ' ')"

if grep -q 'TRITRACK_PRECOMMIT_RED_IS_PREEXISTING=1' <<<"$tool_command"; then
  echo "pre-commit suite: SKIPPED on purpose. NOTHING WAS RUN — no test" \
       "executed, so this commit carries no evidence that the tree is green." \
       "Say so in your TASK_COMMS.md entry, and say how you established the" \
       "red was not yours."
  trace "SKIPPED on purpose (TRITRACK_PRECOMMIT_RED_IS_PREEXISTING=1)"
  exit 0
fi

# **The gate's coverage derivation, added by task 11.182, and it is here
# because of what it cost not to have it.** The commit that built this hook
# was itself the commit that turned CI red — two files under `scripts/`
# carrying no `# gate-instrument:` declaration — and **this hook could not
# have caught it even had it been running**, because it runs `flutter test`
# and that check lives in a workflow. `GATE_SMOKE_COVERAGE_ONLY=1` runs the
# gate's two derivations and **no instrument**: no Docker, no stack, no
# server. **Measured at 0.85 s** against the suite's 96, so it is under one
# percent and it goes first, because failing in a second beats failing in a
# hundred. What still lives outside this hook is listed in
# `CLAUDE_DOCS/SETUP_OWNERSHIP.md` under the pre-commit hook's row.
coverage_status=0
coverage="$(cd "$repo_root" && GATE_SMOKE_COVERAGE_ONLY=1 ./scripts/gate_smoke_test.sh 2>&1)" \
  || coverage_status=$?
if [[ $coverage_status -ne 0 ]]; then
  trace "REFUSED: gate coverage derivation is red"
  {
    echo "pre-commit suite: the gate's coverage derivation is red, so this" \
         "commit would break .github/workflows/gate-instruments.yml. No" \
         "instrument ran — this is the declaration check only."
    sed 's/^/  /' <<<"$coverage" | tail -30
  } >&2
  exit 2
fi

if ! command -v flutter >/dev/null 2>&1; then
  echo "pre-commit suite: flutter is not on PATH, so the suite did not run and" \
       "this commit is unverified. Install it, or skip deliberately with" \
       "TRITRACK_PRECOMMIT_RED_IS_PREEXISTING=1." >&2
  exit 2
fi

# **What this commit takes, task 11.325 item 3.** Until 2026-10-02 the checks
# below asked `git diff --cached --name-only -- lib/` whether the commit touched
# `lib/`. That is right for `git commit` and wrong for `git commit -- <path>`,
# the form `CLAUDE.md` requires: a commit that names its paths takes the
# working-tree content of those paths and ignores the index, so an unstaged edit
# was committed without this hook ever seeing it. Reproduced 2026-10-01 (task
# 11.318, a stale generated file committed to a throwaway branch) and again
# 2026-10-02 (task 11.325: the old hook went straight to `flutter test` with
# `build_runner` never started). `scripts/lib/commit_scope.py` reads the command,
# works out which shape it is, and asks git what that shape takes.
#
# **It must not fail open.** A scope that cannot be read is a refusal, for the
# reason the payload reader above is one: "could not tell" and "nothing to check"
# are the same observable if the answer is exit 0.
scope_status=0
scope="$(printf '%s' "$tool_command" | python3 "$repo_root/scripts/lib/commit_scope.py" "$repo_root" 2>&1)" \
  || scope_status=$?
if [[ $scope_status -ne 0 ]]; then
  trace "REFUSED: could not work out which files this commit takes"
  echo "pre-commit suite: could not work out which files this commit takes" \
       "(commit_scope.py exited $scope_status), so it cannot tell whether the" \
       "generated-files and analyze checks apply. Refusing rather than passing" \
       "silently:" >&2
  sed 's/^/  /' <<<"$scope" >&2
  exit 2
fi

# **Generated-files drift, task 11.309.** Only worth a ~25-100 s clean
# build_runner run when the commit actually takes something under lib/ — every
# tracked .g.dart/.freezed.dart lives there, so a commit that does not cannot
# have produced this drift, and most commits in this repo (CLAUDE_DOCS/,
# .claude/commands/) do not. For a commit that names its paths, the generated
# files it names are compared as they are in the working tree, because that is
# what it will commit (`GENERATED_FILES_WORKTREE_PATHS`, read by the script).
if grep -q '^generated_check=yes$' <<<"$scope"; then
  worktree_generated="$(sed -n 's/^worktree_generated=//p' <<<"$scope")"
  if ! generated_check="$(cd "$repo_root" && GENERATED_FILES_WORKTREE_PATHS="$worktree_generated" ./scripts/check_generated_files_current.sh 2>&1)"; then
    trace "REFUSED: generated files are stale"
    echo "pre-commit suite: generated files are stale against their sources." >&2
    sed 's/^/  /' <<<"$generated_check" >&2
    exit 2
  fi
fi

# **`flutter analyze`, task 11.325 item 1.** Twenty issues arrived between
# 2026-09-10 and 2026-10-01 without anything refusing them, because neither this
# hook nor any task's checklist ran the analyzer, and they surfaced only when
# CI's first real run died at its first step. It runs for a commit that takes
# Dart (a `.dart` file, a `pubspec`, or `analysis_options.yaml`) — not for a
# Markdown-only commit, which cannot change what the analyzer says. Measured
# 2026-10-02: 13-17 s with a warm cache, 66 s cold (not the ~30 s the plan
# guessed). It goes before the suite because failing in a few seconds beats
# failing in a hundred, and it covers the whole repository, `server/` and
# `packages/` included, exactly as CI's step did.
if grep -q '^analyze=yes$' <<<"$scope"; then
  if ! analyze_out="$(cd "$repo_root" && flutter analyze 2>&1)"; then
    trace "REFUSED: flutter analyze reports issues"
    echo "pre-commit suite: flutter analyze reports issues, so this commit would" \
         "put them on main. Fix them, or commit with" \
         "TRITRACK_PRECOMMIT_RED_IS_PREEXISTING=1 if they are not yours." >&2
    sed 's/^/  /' <<<"$analyze_out" | tail -40 >&2
    exit 2
  fi
fi

stream="$(mktemp "${TMPDIR:-/tmp}/tritrack-precommit-stream.XXXXXX")"
# Deleted on a green run only. A red run sets `keep_stream`, and the trap
# leaves the file for the person reading the refusal (task 11.294).
keep_stream=0
trap '[[ "$keep_stream" -eq 1 ]] || rm -f "$stream"' EXIT

(cd "$repo_root" && flutter test --reporter json) >"$stream" 2>&1

# The verdict is the reader's, not the exit code's: `flutter test` exiting 0
# says nothing about how many files it reached.
verdict="$(python3 "$repo_root/scripts/lib/suite_verdict.py" "$repo_root" "$stream")"
verdict_status=$?

if [[ $verdict_status -ne 0 ]]; then
  keep_stream=1
  {
    echo "pre-commit suite: this commit would put a red on main, which is what" \
         "task 11.180 exists to stop."
    sed 's/^/  /' <<<"$verdict"
    echo "The runner's full JSON stream is kept at $stream — the failing" \
         "test's exception text and its printed diagnostics are in there," \
         "so read it before running the suite again."
    echo "If the red is not yours: stash your changes and re-run on the clean" \
         "tree to establish that (task 11.127's method), then commit with" \
         "TRITRACK_PRECOMMIT_RED_IS_PREEXISTING=1 and record it in" \
         "CLAUDE_DOCS/TASK_COMMS.md."
  } >&2
  trace "REFUSED: suite is red (stream kept at $stream)"
  exit 2
fi

echo "pre-commit suite: $verdict"
trace "PASSED: $verdict"
exit 0
