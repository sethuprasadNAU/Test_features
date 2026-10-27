#!/usr/bin/env bash
# gate-instrument: none - this is the gate itself, the file that runs the others.
# Gate instrument smoke test (task 10.42, H-2/H-8 — TriTrack_Security_Model.md
# §10.5, §10.7.1).
#
# 10.40 added a version-handshake self-check to all five wire-speaking gate
# instruments and never once ran any of them against a live server before
# recording that as done — the check itself asserted `200` where the server is
# designed to answer `403`, so all five aborted before exercising a single
# control. The task-level failure was not the one-line bug; it was that
# nothing made "do the instruments actually run" a command instead of a belief
# between gates. This is that command.
#
#   scripts/gate_smoke_test.sh
#
# Brings the e2e stack up, runs every wire-speaking instrument plus the backup
# drill and H-6's archive-forgery regression test, and reports PASS/FAIL **per
# instrument** rather than one pooled exit code — a single number can't tell a
# reader which of nine tools broke.
#
# What "PASS" and "FAIL" mean here: each instrument's own exit code, verbatim.
# A wire-speaking instrument that finds a genuine, still-open finding (several
# do, as of the third Gate C re-run) exits non-zero and is reported FAIL —
# that is the instrument doing its job, not the instrument being broken. This
# script's purpose is narrower and prior to that: proving each tool can reach
# the server, run its logic, and report a real result at all, which a stale
# shared constant or a broken preflight defeats silently. Read each
# instrument's own output (saved per-run, path printed below) to tell "found a
# real finding" apart from "the tool itself is rotten" — this script does not
# make that call for you.
#
# Self-proof: run with GATE_SMOKE_SELFTEST=1 to force a stale
# schema_major (the exact shape 10.40's bug was) and confirm every
# wire-speaking instrument aborts loudly instead of silently reporting HELD.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$(pwd)"
# Task 11.69: run the e2e server as this user, so the magic link every
# wire-speaking instrument below has to read is readable here. Eleven of
# them died on `Errno 13` the first time this ran on Linux. See
# scripts/lib/host_user.sh for what that does and does not change.
# shellcheck disable=SC1091
. scripts/lib/host_user.sh
# Task 10.47 / Security Model §10.7.3: `-p tritrack-gate`, matching §9.1's
# discipline and the default `verify_c5_denial_audit.py` and
# `gate_c_adversarial_pass.py` now assume — both `exec ... psql` into
# whatever project name their own `COMPOSE` resolves to, and before this they
# defaulted to none at all while this script's stack also had none, which
# happened to agree by accident rather than by naming the same project on
# purpose. Naming it here means it stays true if either script's default
# ever changes independently.
COMPOSE=(docker compose -p tritrack-gate -f docker-compose.yml -f docker-compose.e2e.yml)
OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tritrack-gate-smoke.XXXXXX")"

# **The SHIPPED settings, not this machine's — task 11.312, same fix as
# 11.310's item 4 (`verify_c3_cleartext_defaults_stack.sh`).** Until now every
# `${COMPOSE[@]}` command below read whatever `.env` sits in this checkout, so
# the 25-instrument stack this file certifies was never the one that ships —
# on the Ubuntu VM, `.env` sets `SERVER_PUBLISH_ADDRESS=0.0.0.0` (deliberately,
# so a phone can reach the dev server) and
# `TRITRACK_PROJECT_DELETION_GRACE_DAYS=0` (deliberately, for fast cycles),
# and every instrument below ran against those choices instead of what a clean
# checkout resolves to. `scripts/lib/shipped_compose_settings.py` prints every
# variable `docker-compose.yml` interpolates, empty (Compose ranks an exported
# variable above `.env`, and an empty value behaves as unset for every one of
# them — see that file), plus throwaway Postgres credentials. Exported here,
# once, for the rest of this script's lifetime, so `down`, `up` and every
# instrument invoked below by `run_instrument` (same shell, same environment)
# all agree on the same shipped configuration and the same database
# credentials — reusing the c3 stack's throwaway values would leave this
# script's own `up` using one password and its instruments assuming another.
# SERVER_PORT is left at its shipped default (empty here resolves to 8080 via
# `${SERVER_PORT:-8080}`), which is the port every wait/curl below already
# assumes.
SHIPPED_SETTINGS="$(mktemp "${TMPDIR:-/tmp}/tritrack-gate-shipped-settings.XXXXXX")"
python3 scripts/lib/shipped_compose_settings.py >"$SHIPPED_SETTINGS"
[ -s "$SHIPPED_SETTINGS" ] || {
  echo "FAIL: could not derive the shipped compose settings" >&2
  exit 1
}
set -a
# shellcheck disable=SC1090  # generated just above
. "$SHIPPED_SETTINGS"
set +a
rm -f "$SHIPPED_SETTINGS"

# **Coverage-only mode — task 11.172.**
#
#   GATE_SMOKE_COVERAGE_ONLY=1 scripts/gate_smoke_test.sh
#
# Records which instruments this file WOULD run, runs the two coverage
# derivations below over them, and runs nothing else. No Docker, no stack, no
# instrument, no control exercised — and it says so in those words rather than
# printing anything a reader could mistake for a gate result. It exists because
# the derivation below is what says a `run_instrument` line is still there, and
# a check that can only be exercised by a twenty-minute Docker run is a check
# whose own failure modes nobody watches. In this mode every sabotage of a run
# line can be watched going red in about a second.
COVERAGE_ONLY="${GATE_SMOKE_COVERAGE_ONLY:-0}"

# **Task 11.296.** In coverage-only mode nothing below ever writes into
# $OUT_DIR — [run_instrument] and [run_detection_proof] both return before
# touching their `$log` path whenever $COVERAGE_ONLY=1 — so the directory
# `mktemp -d` just created is guaranteed empty at every exit from this mode,
# including the conflict check three lines down. `rmdir` only succeeds on an
# empty directory, so installing it here, before that first possible exit,
# removes exactly the directories this mode leaks and nothing a full run
# writes logs into (task 10.42/M-12's `_cleanup` below installs its own
# single handler for that path and is untouched by this one — this trap is
# replaced, not stacked, the moment that branch runs). The pre-commit hook
# runs this mode on every commit and had left two of these per run, unread,
# forever: 39 counted before this fix.
if [ "$COVERAGE_ONLY" = "1" ]; then
  trap 'rmdir "$OUT_DIR" 2>/dev/null || true' EXIT
fi

if [ "$COVERAGE_ONLY" = "1" ] && [ "${GATE_SMOKE_SELFTEST:-0}" = "1" ]; then
  echo "GATE_SMOKE_COVERAGE_ONLY=1 and GATE_SMOKE_SELFTEST=1 together mean"
  echo "nothing: the self-test proves every wire instrument aborts against a"
  echo "live server, and coverage-only never brings one up. Pick one."
  exit 1
fi
# Task 11.88. Exported to GITHUB_ENV, when present, so a workflow step run
# after this one can upload $OUT_DIR as a CI artifact — the per-instrument
# logs otherwise die with the runner the moment this script exits, and the
# console only ever saw an excerpt someone chose in advance.
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "GATE_SMOKE_OUT_DIR=$OUT_DIR" >>"$GITHUB_ENV"
fi

# Task 10.90: task 10.51 found `tritrack-gate_tritrack_postgres_data`
# surviving an earlier run, holding roles from a stale `.env`. The gate
# server never got a database connection and every wire-speaking instrument
# aborted (the safe direction), but nothing had *verified* the volume was
# fresh — a gate whose database persists across runs is measuring whatever
# configuration happened to be left behind, not the one it was just told to
# use. Bring the project down with `-v` first so every run starts from a
# volume-less state and `up` always performs a real `initdb`.
#
# F15 destroyed a developer's own Postgres volume once with an unscoped `-v`.
# The guard against repeating that is `-p tritrack-gate` living on `COMPOSE`
# itself (set once, above) — every command built from `"${COMPOSE[@]}"`,
# including this one, is scoped to that project's own resources and cannot
# reach a volume belonging to any other compose project, named or unnamed.
if [ "$COVERAGE_ONLY" != "1" ]; then
echo "Starting from known state: tearing down any previous tritrack-gate"
echo "stack, including its volumes, so this run's Postgres is freshly"
echo "initialized rather than inherited from an earlier one."
echo "+ ${COMPOSE[*]} down -v"
"${COMPOSE[@]}" down -v >"$OUT_DIR/compose-down.log" 2>&1 || {
  cat "$OUT_DIR/compose-down.log"
  echo "FAIL: could not tear down a previous tritrack-gate stack — see above."
  exit 1
}
fi   # COVERAGE_ONLY: nothing to tear down, because nothing will be brought up

# Finding M-12 (Security Model §16.3, task 10.108): this script tore the
# stack down before a run and never after, so its server kept 127.0.0.1:8080
# bound past this run's end. A later e2e stack then failed to bind that port
# and — because nothing checked which stack answered — an e2e suite ran
# against THIS run's server and database instead of its own, diagnosed only
# because a human happened to run `docker ps`. An EXIT trap, installed here so
# it covers every path out of this script (success, an instrument failure,
# `exit 1` above already having run, or a stray signal), is what makes "ends
# in a known state" true regardless of how the run finishes rather than only
# on the success path. Same `-p tritrack-gate` scoping as everywhere else in
# this file (task 10.90) — F15 destroyed a real Postgres volume with an
# unscoped `-v` once, and that scoping is why it has not happened since.
_teardown() {
  echo "Tearing down: ${COMPOSE[*]} down -v"
  "${COMPOSE[@]}" down -v >"$OUT_DIR/compose-teardown.log" 2>&1 || {
    cat "$OUT_DIR/compose-teardown.log"
    echo "WARNING: could not tear down the tritrack-gate stack — it may"
    echo "still be holding 127.0.0.1:8080 for whatever runs next. Full log:"
    echo "$OUT_DIR/compose-teardown.log"
  }
}

# Set to 1 by the self-test below once it has mutated gate_wire.py. Read only
# by [_cleanup].
RESTORE_GATE_WIRE=0

# **One EXIT handler, and only one — task 11.9.**
#
# Bash keeps a single EXIT trap: a later `trap ... EXIT` silently *replaces*
# the earlier one rather than adding to it. The self-test below needs its own
# cleanup (restoring `gate_wire.py` from the committed blob), and installing it
# as a second `trap` is what it used to do — which quietly discarded
# `_teardown` for the entire self-test run. Measured 2026-08-22: after
# `GATE_SMOKE_SELFTEST=1` the `tritrack-gate` stack was still up and still
# holding `127.0.0.1:8080`, and the next stack to want that port failed to
# bind. That is finding M-12 exactly, in the one branch task 10.108's fix did
# not reach — the instance was fixed and the class was not.
#
# So there is one handler, it does everything, and a future cleanup is a line
# **inside** it rather than a second `trap`.
# The restore is ordered first and its failure is reported rather than fatal:
# under `set -e` a failing command inside an EXIT trap ends the trap, so an
# unguarded `git checkout` that failed would take the teardown down with it and
# reintroduce the very defect this shape exists to fix.
_cleanup() {
  if [ "$RESTORE_GATE_WIRE" = "1" ]; then
    git -C "$ROOT" checkout -- scripts/gate_wire.py || {
      echo "WARNING: could not restore scripts/gate_wire.py from the committed"
      echo "blob. It still holds the forced-stale schema_major — restore it"
      echo "before running any wire instrument: git checkout -- scripts/gate_wire.py"
    }
  fi
  _teardown
}
if [ "$COVERAGE_ONLY" != "1" ]; then
trap _cleanup EXIT
fi

if [ "$COVERAGE_ONLY" = "1" ]; then
  echo
  echo "GATE_SMOKE_COVERAGE_ONLY=1: NOTHING BELOW IS RUN. No stack is brought"
  echo "up, no instrument executes, and no control is exercised. This run can"
  echo "only report on whether every line that would run something is derived."
else
# **Is port 8080 free? Asked before building, not discovered after — task
# 11.310.** This stack publishes the server on 127.0.0.1:8080. On a CI runner
# nothing else is ever there, which is why nobody noticed: on the Ubuntu VM
# that also serves TriTrack, the real server holds 8080, and this script used
# to build images for several minutes and then die on Docker's "port is already
# allocated" under a generic "could not bring the stack up". The previous
# tritrack-gate stack is already gone (the `down -v` above), so anything still
# holding the port belongs to something else — and the helper names it, with
# the command that stops it. **It never stops anything itself**: on that VM the
# holder is production, and stopping it is the operator's decision.
echo "Checking that port 8080 is free before building anything..."
if ! python3 scripts/lib/port_holder.py free 8080; then
  echo "FAIL: this gate needs port 8080 for its own throwaway server, and"
  echo "something else holds it (above). Nothing was built and nothing was"
  echo "attacked. Stop the holder, run this again, and start the holder"
  echo "afterwards."
  exit 1
fi
echo "Bringing up the e2e stack..."
# Named services rather than the whole file (task 11.78). The base compose file
# now carries a `backup-scheduler` service, which is right for a deployment and
# wrong here: this suite has no backup recipients configured, so the scheduler
# would fail on a loop and report itself unhealthy for the length of every run,
# and a red container that is *supposed* to be red is how a real red stops being
# noticed. These two are exactly what `up` started before it existed.
"${COMPOSE[@]}" up --build -d postgres server >"$OUT_DIR/compose-up.log" 2>&1 || {
  cat "$OUT_DIR/compose-up.log"
  echo "FAIL: could not bring the stack up — see above."
  exit 1
}

# **Waits for /ready, not /health (task 11.128).** Every instrument below
# needs a database; /health answers 200 on a server that has none, so waiting
# on it used to hand a green light to a run whose auth routes were not even
# mounted — every wire-speaking instrument then aborted on a 404 and the
# operator had to work backwards to the database. /ready answers 503 with
# {"degraded":["database"]} for exactly that state.
#
# Both are polled so the failure message can say WHICH of the two happened,
# which is the difference between "the server did not start" and "the server
# started and its database never arrived" — two different things to go and fix.
echo -n "Waiting for the server to answer /ready..."
UP=0
ALIVE=0
for _ in $(seq 1 50); do
  if curl -fsS http://localhost:8080/health >/dev/null 2>&1; then
    ALIVE=1
    if curl -fsS http://localhost:8080/ready >/dev/null 2>&1; then
      UP=1
      break
    fi
  fi
  sleep 0.2
  echo -n "."
done
echo
if [ "$UP" != "1" ]; then
  if [ "$ALIVE" = "1" ]; then
    echo "FAIL: the server is alive but never became READY. It answered"
    echo "/health and then: $(curl -sS http://localhost:8080/ready 2>&1)"
    echo "That is a database the server could not reach, not a server that"
    echo "did not start. Check the postgres service and the credentials in"
    echo "the environment this stack was brought up with."
  else
    echo "FAIL: the server never answered /health — the stack came up but the "
    echo "server did not. Nothing below can be trusted to have run against a "
    echo "live server."
  fi
  exit 1
fi
fi   # COVERAGE_ONLY

STALE_ENVELOPE_PATCH=""
if [ "${GATE_SMOKE_SELFTEST:-0}" = "1" ]; then
  echo
  echo "GATE_SMOKE_SELFTEST=1: forcing a stale schema_major so every"
  echo "wire-speaking instrument below is EXPECTED to abort with"
  echo "PREFLIGHT ABORT, not to run its controls. This proves the smoke test"
  echo "actually catches instrument rot, not just that it can run scripts."
  # Task 10.95 (10.82 residual): the restore used to come from a `cp` taken
  # into $OUT_DIR (a mktemp directory) at mutation time, not from git. Two
  # ways that goes wrong: a SIGKILL mid-run skips the EXIT trap entirely and
  # leaves the stale constant in the tree with no backup ever taken from a
  # known-good source; and if a PRIOR run was killed that way, this run's own
  # "orig" backup would be copied from the already-mutated live file, so its
  # own restore would just write the corruption back. `git checkout` restores
  # from the committed blob regardless of what state the working tree was in
  # when this run started, so it cannot compound a prior interrupted run's
  # damage — and refusing to start with an already-dirty gate_wire.py catches
  # exactly that prior-corruption case instead of silently patching on top of
  # it.
  if ! git -C "$ROOT" diff --quiet -- scripts/gate_wire.py; then
    echo "GATE_SMOKE_SELFTEST=1: scripts/gate_wire.py already has uncommitted"
    echo "changes — refusing to mutate it further. If a prior run was killed"
    echo "mid-selftest, restore it first: git checkout -- scripts/gate_wire.py"
    exit 1
  fi
  STALE_ENVELOPE_PATCH="$OUT_DIR/stale_gate_wire.py"
  python3 - "$ROOT/scripts/gate_wire.py" "$STALE_ENVELOPE_PATCH" <<'PY'
import sys
src = open(sys.argv[1]).read()
# Force the parsed major to a value the live server will reject with 409,
# without touching the real gate_wire.py or the Dart source it parses from.
src = src.replace(
    'ENVELOPE = {\n',
    'SCHEMA_MAJOR = SCHEMA_MAJOR + 1000  # GATE_SMOKE_SELFTEST\nENVELOPE = {\n',
    1,
)
open(sys.argv[2], "w").write(src)
PY
  cp "$STALE_ENVELOPE_PATCH" "$ROOT/scripts/gate_wire.py"
  # NOT a second `trap` — see [_cleanup] above for what that cost.
  RESTORE_GATE_WIRE=1
fi

# **Task 11.312 item 4.** The Deployments existence-oracle sweep's own
# refusal starts `ABORT:`, which the hand-typed `fail|error|admitted|traceback`
# below never included — so a red run's summary said "no FAIL/ERROR/ADMITTED
# line found" and fell back to the log's last 40 lines, finding the right text
# by luck rather than by matching it. `scripts/lib/gate_log_markers.py` derives
# the word set instead: every `scripts/*.py` instrument's own `SystemExit`/
# `sys.exit` failure messages, whose ALL-CAPS opening word is read straight
# from the source, plus a small fixed floor explained in that file (`FAIL`,
# `ERROR`, `ADMITTED`, `TRACEBACK` — none of which a Python-only scan can
# reach). Computed once, not per instrument.
MARKER_REGEX="$(python3 scripts/lib/gate_log_markers.py --regex)"
if [ -z "$MARKER_REGEX" ]; then
  echo "FAIL: scripts/lib/gate_log_markers.py derived no marker words at all" >&2
  echo "— refusing to run with a grep pattern that matches nothing." >&2
  exit 1
fi

declare -a NAMES=()
declare -a RESULTS=()
# Task 11.172: the command each name actually ran, recorded in step with NAMES.
# The coverage derivation below asserts that the file claiming a name is a file
# that name's command mentions — a declaration checked against the act rather
# than against its own wording.
declare -a COMMANDS=()
FAILED_ANY=0

run_instrument() {
  local name="$1"
  shift
  local log="$OUT_DIR/${name}.log"
  COMMANDS+=("$*")
  if [ "$COVERAGE_ONLY" = "1" ]; then
    NAMES+=("$name")
    RESULTS+=("NOT-RUN")
    return 0
  fi
  echo
  echo "== $name =="
  if "$@" >"$log" 2>&1; then
    echo "  PASS  $name"
    NAMES+=("$name")
    RESULTS+=("PASS")
  else
    local code=$?
    echo "  FAIL  $name (exit $code) — see $log"
    # Task 11.88. A fixed `tail -n 5` assumes the failure is the last thing
    # an instrument says. An instrument that tears down or prints a banner
    # after failing — which is correct behaviour — pushes its own finding
    # out of a fixed window; the four invite-404 instruments were legible
    # only by luck, and backup_restore_drill's real finding was thrown away
    # this way on every CI run since task 11.70. Grep the log for the
    # instrument's own conclusion instead of guessing where in the file it
    # landed — $MARKER_REGEX (derived above, task 11.312 item 4) is the set
    # of words a gate instrument opens its own conclusion with.
    #
    # `-A 8`: a match's own explanation often continues on the lines right
    # after it without repeating the marker word on each one — the drill's
    # own step-0 message is exactly this shape: the line that says "FAIL"
    # names the symptom, and the actual uid:gid values needed to diagnose it
    # sit on the very next line, which a bare per-line grep would have
    # dropped just as surely as the old `tail -n 5` did.
    local marker_lines
    marker_lines="$(grep -niE -A 8 "$MARKER_REGEX" "$log" || true)"
    if [ -n "$marker_lines" ]; then
      echo "$marker_lines" | tail -n 40 | sed 's/^/    | /'
    else
      echo "    | (none of this run's derived marker words — $MARKER_REGEX —"
      echo "    | were found in the log; last 40 lines instead, so something"
      echo "    | still reaches the console:)"
      tail -n 40 "$log" | sed 's/^/    | /'
    fi
    echo "    | Full log ($log) is kept at \$OUT_DIR and, in CI, uploaded"
    echo "    | as an artifact on failure — read it before deciding what a"
    echo "    | truncated console excerpt might have hidden."
    NAMES+=("$name")
    RESULTS+=("FAIL")
    FAILED_ANY=1
  fi
}

# **A detection proof: an instrument sabotaged on purpose, required to notice.**
# Task 11.125, item 2(i), from task 11.119's survey.
#
# `run_instrument` above proves a tool can *run*. That is not evidence it can
# *detect* — the distinction task 11.77 drew and the survey then counted: of
# twenty-six instruments, two already carry a proof that they notice their own
# blinding, and **nothing in this repository ever ran either of them.** A
# detection proof that nobody runs is in exactly the position of the control it
# is about.
#
# The difference from `run_instrument` is that **a sabotaged run is required to
# FAIL**, so a zero exit here is the defect. But an exit code alone is too
# coarse to be the whole check: `verify_source_identity.sh` exits 1 both when
# its sabotaged control fires (correct) and when the run reaches the end with
# the sabotage undetected (the failure the proof exists to catch) — and it
# would exit 1 again if Docker were simply unavailable, which measures nothing
# at all. So each call also names the line the instrument must print when the
# right control catches the sabotage, and the lines that must be absent.
#
#   run_detection_proof NAME --require RE [--require RE] [--forbid RE] -- cmd...
#
# PASS means: non-zero exit, every `--require` pattern present in the log, and
# every `--forbid` pattern absent from it.
run_detection_proof() {
  local name="$1"
  shift
  local -a required=() forbidden=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    case "$1" in
      --require) shift; required+=("$1") ;;
      --forbid) shift; forbidden+=("$1") ;;
      *) echo "run_detection_proof: unexpected argument $1" >&2; exit 1 ;;
    esac
    shift
  done
  shift   # the `--`
  local log="$OUT_DIR/${name}.log"
  COMMANDS+=("$*")   # task 11.172, as in [run_instrument]
  if [ "$COVERAGE_ONLY" = "1" ]; then
    NAMES+=("$name")
    RESULTS+=("NOT-RUN")
    return 0
  fi
  echo
  echo "== $name (detection proof — this run is sabotaged and MUST fail) =="
  local why=""
  if "$@" >"$log" 2>&1; then
    why="it exited 0. A deliberately sabotaged run that passes is the proof failing."
  else
    local re
    for re in "${required[@]}"; do
      if ! grep -qE "$re" "$log"; then
        why="the sabotage was not caught where it should have been: no line matching /$re/."
        break
      fi
    done
    if [ -z "$why" ]; then
      for re in "${forbidden[@]}"; do
        if grep -qE "$re" "$log"; then
          why="the log carries /$re/, which says the sabotaged control did not fire."
          break
        fi
      done
    fi
  fi
  if [ -z "$why" ]; then
    echo "  PASS  $name (sabotage caught)"
    NAMES+=("$name")
    RESULTS+=("PASS")
  else
    echo "  FAIL  $name — $why"
    echo "        Full log: $log"
    tail -n 20 "$log" | sed 's/^/    | /'
    NAMES+=("$name")
    RESULTS+=("FAIL")
    FAILED_ANY=1
  fi
}

# Task 10.65 / Security Model §12.7 (J-6, `Cf`'s class reintroduced). Static,
# needs no Docker and no live server — runs first, cheaply, rather than
# waiting on the stack above. Excluded from WIRE_INSTRUMENTS below: it does
# not speak the sync wire and is unaffected by GATE_SMOKE_SELFTEST's forced
# stale schema_major, same as backup_restore_drill and verify_h6_archive_forgery.
run_instrument "verify_instrument_unchecked_returns" python3 scripts/verify_instrument_unchecked_returns.py
# Its detection proof, which had never been run by anything (task 11.125,
# item 2(i)). `--selftest` plants a swallowed return in a temporary tree and
# requires the scanner to find it, then plants nothing and requires a clean
# scan — both halves live. It exits 0 when the proof holds, so it is an
# ordinary `run_instrument`; the two below are not.
run_instrument "verify_instrument_unchecked_returns_selftest" \
  python3 scripts/verify_instrument_unchecked_returns.py --selftest
# Task 11.90 / Security Model §22.4.1 (R-3). The decision rule inside
# `gate_c_adversarial_pass`'s `Cg` timing check, exercised on lists of numbers
# instead of on a live stack — including on the numbers from the run that
# reported a Gate C blocker three re-runs could not reproduce. It needs no
# Docker and no server, so it runs here with the other static checks. **The
# guard it replaces was wrong, and the only defence against a second wrong
# guard is being able to break this one cheaply and on purpose**; this line is
# what makes that happen on every gate rather than once, on the day it was
# written. Not a wire-speaking instrument.
run_instrument "gate_timing_guard_selftest" \
  python3 scripts/gate_timing_guard.py --selftest
run_instrument "verify_c1_row_naming" python3 scripts/verify_c1_row_naming.py
run_instrument "verify_c2_existence_oracle" python3 scripts/verify_c2_existence_oracle.py
run_instrument "verify_c5_denial_audit" python3 scripts/verify_c5_denial_audit.py
run_instrument "verify_d1_per_row_oracle" python3 scripts/verify_d1_per_row_oracle.py
# Task 10.54 / Security Model §11.5. Absent from this list and from the
# self-test's WIRE_INSTRUMENTS below despite landing in the same commit
# (5edfafc) as the other four wire-speaking probes above — task 10.42's claim
# that "the tools work is now a command, not a belief" excluded the newest
# tool. It speaks the sync wire exactly like its neighbors (imports `preflight`
# from gate_wire.py), so it belongs in both places, not just this list.
run_instrument "verify_h3_existence_oracle_sweep" python3 scripts/verify_h3_existence_oracle_sweep.py
# Task 10.55 / finding I-4. Speaks the sync wire like the four above, so it is
# in the self-test's WIRE_INSTRUMENTS below as well — the omission the note
# above records is not one to repeat with the newest tool.
run_instrument "verify_i4_email_forgery" python3 scripts/verify_i4_email_forgery.py
# Task 11.9. Phase 11's team surface — invitations, membership and role
# mutation over the wire, the role gradient applied to teammates' rows, and
# `Observation_Exclusions`, the one write in this app where one person acts on
# somebody else's record. Speaks the sync wire (imports `preflight` from
# gate_wire.py), so it is in WIRE_INSTRUMENTS below as well.
run_instrument "verify_11_9_team_surface" python3 scripts/verify_11_9_team_surface.py
# Task 11.24 / finding N-1, plus task 11.26's class. Added here by task 11.49,
# which found it had been in neither list since 2026-08-22 — the third time
# this file has gained a wire-speaking instrument late, after the two comments
# above already recorded the first two. The guard added below this run list is
# the class fix: from now on a wire-speaking instrument that is not in both
# places fails the run instead of being noticed by the next reader.
run_instrument "verify_11_24_attribution" python3 scripts/verify_11_24_attribution.py
# Task 11.49. Inventory entries 27 and 28 — the server's two reads. Speaks the
# sync wire and also `exec ... psql` into whatever project name COMPOSE
# resolves to, exactly as verify_c5_denial_audit does, so it needs no extra
# configuration here.
run_instrument "verify_11_49_server_reads" python3 scripts/verify_11_49_server_reads.py
# Task 11.64. Inventory entries 14, 15 and 20 — the sync envelope and cursors,
# the auth routes, and the dev magic-link sender. **These are round 8's own
# checks, which were written by hand on 2026-08-17 and never committed**, so
# every gate since has either re-written them (half a day of Opus time) or
# gone without them. Speaks the sync wire, so it is in WIRE_INSTRUMENTS below
# as well; it also `exec`s into the `server` container to ask whether any file
# escaped the magic-link directory, which is a question the host bind mount
# cannot answer.
run_instrument "verify_round8_server_surface" python3 scripts/verify_round8_server_surface.py
run_instrument "gate_c_adversarial_pass" python3 scripts/gate_c_adversarial_pass.py
# Task 11.125, item 2(ii), from the 11.119 survey: **nothing in this
# repository called `scripts/audit_retention_status.sh`, and Michael had never
# run it either** — so the command `server/README.md` gives an operator for
# "are we still holding rows we said we would delete" had never once been
# watched answering. It runs the same program as the `audit-retention`
# service's healthcheck, so this also exercises the binary that healthcheck
# depends on. `COMPOSE` scopes it to this run's own stack; without it the
# script would start a second compose project's database to answer a question
# about this one's.
run_instrument "audit_retention_status" \
  env COMPOSE="${COMPOSE[*]}" bash scripts/audit_retention_status.sh
# Task 11.290: the same question for scheduled project deletions — is the
# server holding a project its owner was told would be gone? Same program as
# the `project-destruction` service's healthcheck, same COMPOSE scoping.
run_instrument "project_destruction_status" \
  env COMPOSE="${COMPOSE[*]}" bash scripts/project_destruction_status.sh
# Task 11.291: the same question for deleted records — is the server holding
# tombstones past the 24-month window, and what would the next purge refuse?
# Same program as the `tombstone-retention` service's healthcheck, same
# COMPOSE scoping.
run_instrument "tombstone_retention_status" \
  env COMPOSE="${COMPOSE[*]}" bash scripts/tombstone_retention_status.sh
run_instrument "backup_restore_drill" bash scripts/backup_restore_drill.sh
# H-6's reproduction, kept as a regression test by task 10.43: it now exits 0
# when the forged archive is REFUSED, so it belongs in the same one-command run
# as the drill. Like the drill it brings up its own compose project and does
# not speak the sync wire, so it is excluded from the self-test below.
run_instrument "verify_h6_archive_forgery" bash scripts/verify_h6_archive_forgery.sh
# Task 10.95 (10.82 residual, K-7): C-3's own reproduction was written and
# proven but never wired into this file, so it stayed proven only when someone
# remembered to run it by hand — the exact "checked once, not automatically"
# gap this script exists to close for every other instrument. Like the two
# instruments above, it brings up its own compose project (the SHIPPED
# docker-compose.yml, not the e2e overlay, which is the point) and does not
# speak the sync wire, so it is excluded from the self-test below.
run_instrument "verify_c3_cleartext_defaults" bash scripts/verify_c3_cleartext_defaults_stack.sh
# Task 10.52 / finding I-1. **This one is here because of what it measures, not
# just to be counted.** The e2e stack every instrument above runs against sets
# TRITRACK_RATE_LIMIT_PER_SOURCE_DISABLED=1, so nothing in this file has ever
# exercised §4.4's per-source limit at all — which is how a limit that had
# collapsed into one global bucket passed four gates. This drill brings up the
# TLS overlay instead, with the limiter enabled, and attacks it from two client
# containers at distinct addresses. Like the two above it owns its compose
# project and does not speak the sync wire, so it is excluded from the
# self-test below. It is also the slowest instrument here: it builds, brings a
# stack up twice, and pulls a curl image on first run.
run_instrument "verify_i1_source_identity" bash scripts/verify_i1_source_identity.sh
# Task 10.62 / finding J-2. The drill above proves the server resolves a caller
# correctly given an address that distinguishes callers; this asks the prior
# question — does an off-host caller reach this machine with its own address
# still attached — which is a property of the HOST's publish path and the one
# J-2 shows nobody had measured. `--report-only` because a COLLAPSED verdict is
# a true fact about this host (every Docker Desktop checkout collapses) rather
# than a broken tool, and this file's job is the tool: in that mode it fails
# only if one of its three controls stops working.
#
# Task 10.110 changed what this run proves, and the change matters here. The
# probe's automatic mode can no longer return PRESERVED at all — two containers
# on this host are not two off-host callers, and treating them as such returned
# a false COLLAPSED on every Linux host (and, on a host that does not masquerade
# the hairpin, would have returned a false PRESERVED). So a smoke run can no
# longer confirm the PASS branch by watching it fire; the probe's own control 2
# asserts that branch is reachable instead, which is why a probe that has
# silently lost the ability to say yes now fails HERE rather than at the next
# deployment. Licensing a host takes `--assisted` and two real off-host devices
# — not this file, and not any unattended run. Run it that way before declaring
# TRITRACK_TRUSTED_PROXIES=peer-verified (the `direct` shape) or
# TRITRACK_PROXY_SOURCE_IDENTITY=probe-verified (the `proxied` shape, task
# 10.74) anywhere — those two declarations are what such a run licenses, and the
# only thing that qualifies a deployment to be exposed.
run_instrument "verify_source_identity" bash scripts/verify_source_identity.sh --report-only
# **Its two detection proofs, which nothing in this repository ran until task
# 11.125** (item 2(i), from the 11.119 survey). The `--report-only` run above
# proves the probe works; these two prove it can tell when it does not.
#
# `blind-filter` disables `classify`, the function that gates every PASS —
# which is what had effectively happened when a container on this host counted
# as an off-host caller (§12.11, task 10.110). Control 1 must refuse to report.
# `break-machinery` gives two on-network callers the same address, so the log,
# the proxy header and the parser can no longer tell two callers apart, and
# control 3 must refuse.
#
# The `--forbid` pattern is the important half. A sabotaged run exits 1 whether
# the control caught it or the run sailed past and said so at the end, so the
# exit code cannot distinguish the proof passing from the proof failing; that
# closing message is what tells them apart. The `--require` lines pin *which*
# control did the catching, so a probe that dies early for an unrelated reason
# (no Docker, no LAN address) cannot be mistaken for one that detected
# anything.
run_detection_proof "verify_source_identity_selftest_blind_filter" \
  --require "Refusing to report" \
  --require "control 3 \(machinery\)" \
  --forbid "sabotaged control did NOT fire" \
  -- env TRITRACK_PROBE_SELFTEST=blind-filter \
     bash scripts/verify_source_identity.sh --report-only
run_detection_proof "verify_source_identity_selftest_break_machinery" \
  --require "Refusing to report" \
  --require "control 3: two on-network callers" \
  --require "control 1 \(attribution\)" \
  --forbid "sabotaged control did NOT fire" \
  -- env TRITRACK_PROBE_SELFTEST=break-machinery \
     bash scripts/verify_source_identity.sh --report-only
# Task 11.64. Inventory entry 17's twelve-shape deployment refusal matrix —
# the other half of what round 8 ran by hand and never committed, and the one
# that found M-11. It builds the server image and runs it twelve ways with
# nothing else attached, so it owns no compose project and needs no database;
# like the three instruments above it does not speak the sync wire and is
# excluded from the self-test below.
run_instrument "verify_deployment_refusal_matrix" bash scripts/verify_deployment_refusal_matrix.sh
# Task 11.318 item 4 (checklist C4, Michael's decision 2026-09-29: the gate may pull
# one test-only image). Does the sign-in email sender deliver through a relay it was not
# written against — STARTTLS required, authentication on — and refuse a wrong password
# by name? The relay is `axllent/mailpit`, **pinned by digest** in the script; the
# sender runs inside the server image, so the gate needs no Dart. **Its broken control
# is step 1 of the drill itself** (a wrong password must be refused, and nothing may
# reach the catcher), so it runs here every time. **A failed pull is a FAIL that says
# "COULD NOT PULL"**, never a pass: the VM's network has dropped three times, and a
# drill that went quiet on that would be green exactly when the machine is broken. It
# owns its own container and does not speak the sync wire, so it is excluded from the
# self-test below.
run_instrument "verify_smtp_delivery" bash scripts/verify_smtp_delivery.sh

echo
echo "---- Smoke summary ----"
for i in "${!NAMES[@]}"; do
  printf '  %-6s %s\n' "${RESULTS[$i]}" "${NAMES[$i]}"
done
echo "Full per-instrument output kept at: $OUT_DIR"

# The list of wire-speaking instruments, derived from the filesystem rather
# than typed (task 11.49).
#
# **Why this exists.** Three instruments have now been added to this project
# and left out of this file's lists: `verify_h3_existence_oracle_sweep` and
# `verify_i4_email_forgery` (both recorded in the comments above), and
# `verify_11_24_attribution`, which task 11.49 found had been in neither the
# run list nor WIRE_INSTRUMENTS since it landed on 2026-08-22 — so N-1's
# closure had no automated re-run at all, and a stale-envelope regression in it
# would have been silent. Task 10.65 already fixed the *instance* of this in
# the self-test, by checking WIRE_INSTRUMENTS membership in both directions;
# what neither that fix nor the two comments could catch is an instrument
# missing from **both** hand-written lists at once, which is invisible to any
# check built out of those lists.
#
# So the set is read from the source: a `scripts/*.py` that imports
# `gate_wire` and calls `preflight` **is** a wire-speaking instrument, by the
# same definition the self-test uses. Task 10.66's standing criterion — fix the
# class, not the instance — applied to the one defect this file has now had
# three times.
#
# This runs on every invocation, not only under GATE_SMOKE_SELFTEST: the
# omission it catches is about coverage, and a coverage gap that is only
# visible in a mode nobody runs between gates is the gap itself.
#
# The test is an actual `from gate_wire import` (or `import gate_wire`) line
# plus a call to `preflight(`, not a mention of either word. Matching mentions
# also matched `verify_11_49_broken_control.py`, which *describes* both while
# importing neither — it drives another instrument rather than speaking the
# wire itself. A derivation that over-matches fails the run just as loudly as
# one that under-matches is silent, so it was worth narrowing rather than
# special-casing.
# Task 11.172: both derivations below report through one flag, so a coverage
# failure fails the self-test run too. FAILED_ANY cannot do that job there —
# under GATE_SMOKE_SELFTEST every wire instrument is SUPPOSED to fail, so
# FAILED_ANY is always 1 and says nothing about coverage.
COVERAGE_OK=1
DERIVED_WIRE=()
for f in scripts/*.py; do
  n="$(basename "$f" .py)"
  [ "$n" = "gate_wire" ] && continue
  if grep -qE '^(from gate_wire import|import gate_wire)' "$f" \
     && grep -q 'preflight(' "$f"; then
    DERIVED_WIRE+=("$n")
  fi
done
if [ "${#DERIVED_WIRE[@]}" -eq 0 ]; then
  echo "FAIL: no wire-speaking instrument was derived from scripts/*.py at"
  echo "all. The import shape changed — fix this derivation rather than"
  echo "letting an empty set report full coverage."
  COVERAGE_OK=0
  FAILED_ANY=1
fi
for d in "${DERIVED_WIRE[@]}"; do
  RAN=0
  for n in "${NAMES[@]}"; do
    [ "$n" = "$d" ] && RAN=1 && break
  done
  if [ "$RAN" = "0" ]; then
    echo "FAIL: scripts/$d.py speaks the sync wire and this file never runs"
    echo "it. Add a run_instrument line for it, and add it to"
    echo "WIRE_INSTRUMENTS below. An instrument nobody runs between gates is"
    echo "indistinguishable from one that passes."
    COVERAGE_OK=0
    FAILED_ANY=1
  fi
done

# ---------------------------------------------------------------------------
# **The other eleven lines — task 11.172.**
#
# The derivation above covers the wire-speaking Python instruments, because
# they share an import: a `scripts/*.py` that imports `gate_wire` and calls
# `preflight` **is** one of them, by construction. Task 11.171 measured what
# that leaves: **11 of the 22 lines in this file that run something.** The
# other eleven are the shell drills, the two detection proofs, and the static
# scanner with its self-test — and they **share nothing**. No import, no
# interpreter, no naming convention. Until this block existed, deleting any
# one of those eleven lines left this gate green having stopped running it,
# and two of the eleven are whole drills rather than proofs:
# `backup_restore_drill`, the check that says a backup can actually be
# restored, and `verify_deployment_refusal_matrix`. Michael's beta backup
# scheduler failed silently for eleven days and was found by somebody asking.
#
# **So the predicate is added rather than found, and it is opt-OUT.** Every
# `*.sh` and `*.py` under `scripts/` carries exactly one line of the form
#
#     "# gate-instrument: <name> [<name> ...]"      — this gate must run it
#     "# gate-instrument: none - <why not>"         — and here is the reason
#
# and a file carrying neither fails this run. **That direction is the whole
# point.** A marker somebody adds when they remember is a hole that has moved
# rather than closed; a new file that says nothing about itself is refused, so
# the declaration cannot be silently omitted. The cost is one line in each of
# the ~29 scripts here that are not this gate's to run, and the reason on each
# is what a later reader needs anyway.
#
# Four checks, and the third is what makes a declaration more than a comment:
#
#   1. Every scanned file declares exactly once. Zero is the hole this closes;
#      two is a file that can disagree with itself.
#   2. Every declared name ran. Delete a `run_instrument` line and the script
#      it used to run still says it should have.
#   3. The command that ran under a name mentions the file declaring it. A
#      name is a claim about a file, and this asserts the claim against the
#      act — the coupling task 11.171 used on `run_offline_suite.sh`'s port
#      probe, for the same reason: a name is wording and wording is free.
#   4. Every name that ran was declared by exactly one file. A run line no
#      file claims is a name with nothing keeping it true, and two files
#      claiming one name is the duplicate-key defect task 11.88 found.
#
# And, per task 11.160: **deriving nothing is a failure.** A scan that finds
# no files and a `scripts/` holding no instruments are indistinguishable from
# the inside, and only one of them is true.
#
# COVERAGE_OK is NOT re-initialised here: it is set once above, before the wire
# derivation, and both derivations report through it. Setting it again would
# quietly forgive a wire-speaking instrument this file had stopped running.
DECL_NAMES=()
DECL_OWNERS=()
SCANNED=0
while IFS= read -r f; do
  SCANNED=$((SCANNED + 1))
  n_decl="$(grep -c '^# gate-instrument: ' "$f")"
  if [ "$n_decl" = "0" ]; then
    echo "FAIL: $f carries no '# gate-instrument:' line. Every *.sh and *.py"
    echo "under scripts/ must say whether this gate runs it:"
    echo "  '# gate-instrument: <name>'      — and this file runs it by that name"
    echo "  '# gate-instrument: none - why'  — and here is why it does not"
    echo "A file that says nothing about itself is exactly the gap this check"
    echo "exists for: an instrument nobody runs between gates is"
    echo "indistinguishable from one that passes."
    COVERAGE_OK=0
    FAILED_ANY=1
    continue
  fi
  if [ "$n_decl" != "1" ]; then
    echo "FAIL: $f carries $n_decl '# gate-instrument:' lines. One file, one"
    echo "declaration — two of them can disagree, and nothing would say which"
    echo "was meant."
    COVERAGE_OK=0
    FAILED_ANY=1
    continue
  fi
  payload="$(grep -m1 '^# gate-instrument: ' "$f" | sed 's/^# gate-instrument: //')"
  case "$payload" in
    "none - "*)
      # Declared out, with a reason. The reason is for a person, so it is
      # required to be one — "none - n/a" is the declaration going the way of
      # every hand-kept list this project has had to replace.
      reason="${payload#none - }"
      words="$(printf '%s\n' "$reason" | wc -w | tr -d ' ')"
      if [ "$words" -lt 5 ]; then
        echo "FAIL: $f declares 'none' with a $words-word reason. Say why this"
        echo "gate does not run it, in a sentence somebody can disagree with."
        COVERAGE_OK=0
        FAILED_ANY=1
      fi
      ;;
    none|none*)
      echo "FAIL: $f declares 'none' with no reason. The form is"
      echo "'# gate-instrument: none - <why this gate does not run it>'."
      COVERAGE_OK=0
      FAILED_ANY=1
      ;;
    "")
      echo "FAIL: $f has an empty '# gate-instrument:' declaration."
      COVERAGE_OK=0
      FAILED_ANY=1
      ;;
    *)
      for nm in $payload; do
        DECL_NAMES+=("$nm")
        DECL_OWNERS+=("$f")
      done
      ;;
  esac
done < <(find scripts -type f \( -name '*.sh' -o -name '*.py' \) | LC_ALL=C sort)

DERIVATION_SOUND=1
if [ "$SCANNED" = "0" ]; then
  echo "FAIL: the gate-instrument scan found no *.sh or *.py under scripts/ at"
  echo "all. That is the derivation broken, not a repository with no"
  echo "instruments in it — fix this scan rather than letting an empty set"
  echo "report full coverage."
  DERIVATION_SOUND=0
  COVERAGE_OK=0
  FAILED_ANY=1
fi
if [ "${#DECL_NAMES[@]}" -eq 0 ]; then
  echo "FAIL: $SCANNED script(s) were scanned and not one of them declares a"
  echo "gate-instrument name. This file runs ${#NAMES[@]} of them, so either"
  echo "the declaration format changed or every declaration was lost. An empty"
  echo "derivation must never report full coverage."
  DERIVATION_SOUND=0
  COVERAGE_OK=0
  FAILED_ANY=1
fi

# **Checks 2-4 run only if the scan itself is sound.** With a broken scan every
# one of the 22 names below reports undeclared, and 22 true-but-derived failures
# bury the one finding — which the five-line tail CI keeps would then not
# contain. A broken instrument reports that it is broken, and stops. The test is
# the scan, not COVERAGE_OK: one file with a malformed declaration must not stop
# this run asking whether the backup drill is still being run.
if [ "$DERIVATION_SOUND" = "1" ]; then

# 2 and 3: every declared name ran, under a command that mentions its file.
DECL_I=0
while [ "$DECL_I" -lt "${#DECL_NAMES[@]}" ]; do
  d="${DECL_NAMES[$DECL_I]}"
  owner="${DECL_OWNERS[$DECL_I]}"
  DECL_I=$((DECL_I + 1))
  RAN_AT=-1
  for i in "${!NAMES[@]}"; do
    if [ "${NAMES[$i]}" = "$d" ]; then RAN_AT=$i; break; fi
  done
  if [ "$RAN_AT" = "-1" ]; then
    echo "FAIL: $owner declares that this gate runs it as '$d', and this run"
    echo "never ran anything by that name. Either add the line back, or change"
    echo "that file's '# gate-instrument:' declaration to 'none - <reason>' so"
    echo "the decision to stop running it is one somebody made on purpose."
    COVERAGE_OK=0
    FAILED_ANY=1
    continue
  fi
  case "${COMMANDS[$RAN_AT]}" in
    *"$owner"*) ;;
    *)
      echo "FAIL: '$d' ran, but the command that ran under that name does not"
      echo "mention $owner, which is the file claiming it:"
      echo "    ${COMMANDS[$RAN_AT]}"
      echo "A name is wording. The declaration is a claim about a file, so it"
      echo "is checked against what actually ran."
      COVERAGE_OK=0
      FAILED_ANY=1
      ;;
  esac
done

# 4: every name that ran was declared by exactly one file.
for i in "${!NAMES[@]}"; do
  CLAIMS=0
  CLAIMED_BY=""
  DECL_I=0
  while [ "$DECL_I" -lt "${#DECL_NAMES[@]}" ]; do
    if [ "${DECL_NAMES[$DECL_I]}" = "${NAMES[$i]}" ]; then
      CLAIMS=$((CLAIMS + 1))
      CLAIMED_BY="$CLAIMED_BY ${DECL_OWNERS[$DECL_I]}"
    fi
    DECL_I=$((DECL_I + 1))
  done
  if [ "$CLAIMS" = "0" ]; then
    echo "FAIL: this file runs '${NAMES[$i]}' and no script under scripts/"
    echo "declares that name. Add '# gate-instrument: ${NAMES[$i]}' to the"
    echo "script it runs, so deleting the line above stops being silent."
    COVERAGE_OK=0
    FAILED_ANY=1
  elif [ "$CLAIMS" != "1" ]; then
    echo "FAIL: '${NAMES[$i]}' is declared by $CLAIMS files —$CLAIMED_BY."
    echo "One name, one owner: with two, deleting one run line still leaves a"
    echo "declaration satisfied by the other."
    COVERAGE_OK=0
    FAILED_ANY=1
  fi
done

fi   # the derivation was sound enough to ask these questions

if [ "$COVERAGE_ONLY" = "1" ]; then
  echo
  if [ "$COVERAGE_OK" = "1" ]; then
    echo "COVERAGE ONLY: ${#NAMES[@]} of ${#NAMES[@]} line(s) that run something are"
    echo "derived — each from a '# gate-instrument:' declaration in the script it"
    echo "runs, ${#DERIVED_WIRE[@]} of them also derived as wire-speaking, out of"
    echo "$SCANNED script(s) scanned under scripts/."
    echo
    echo "NOTHING WAS RUN. No instrument executed, no server was reached and no"
    echo "control was exercised by this invocation. This says only that the lines"
    echo "are still there and still claimed — run scripts/gate_smoke_test.sh with"
    echo "no GATE_SMOKE_COVERAGE_ONLY to find out what they report."
    exit 0
  fi
  echo "COVERAGE ONLY: FAILED — see the FAIL lines above. A line that runs"
  echo "something is not derived, or a declaration names something this file"
  echo "does not run. Nothing was executed either way."
  exit 1
fi

if [ "${GATE_SMOKE_SELFTEST:-0}" = "1" ]; then
  # The self-test's job is to prove every wire-speaking instrument aborts
  # (they must ALL be FAIL, on PREFLIGHT ABORT, with a stale major). The drills
  # don't speak the sync wire and are unaffected — the derivation below leaves
  # them out by construction rather than by a list somebody has to maintain.
  #
  # **Derived above rather than typed here** (task 11.49): a hand-written list
  # cannot notice an instrument that is missing from every hand-written list,
  # which is what happened to `verify_11_24_attribution` for a week. The count
  # printed on success is therefore whatever the filesystem holds — ten today —
  # and grows on its own when the next instrument lands.
  WIRE_INSTRUMENTS=("${DERIVED_WIRE[@]}")
  SELFTEST_OK=1
  # Task 11.172. A self-test run that proves every wire instrument aborts, on a
  # file that has quietly stopped running four of the drills, has proved the
  # thing that was easiest to prove. Coverage is checked in both modes.
  if [ "$COVERAGE_OK" != "1" ]; then
    echo "SELFTEST FAILED: the instrument-coverage derivation above failed —"
    echo "see its FAIL lines. What this run covered is not what this file says"
    echo "it covers, and the abort proof below is about the part that ran."
    SELFTEST_OK=0
  fi
  # Task 10.65 / Security Model §12.7 (J-6): this loop used to iterate only
  # over instruments that RAN (NAMES) and ask whether each is a known
  # WIRE_INSTRUMENT — it never asked the reverse, whether every
  # WIRE_INSTRUMENT actually ran at all. Demonstrated live: commenting out
  # one of the run_instrument calls above still printed SELFTEST PASSED,
  # which is exactly the omission §11.5 reported and 10.54 was written to
  # fix (it added the missing name to this list and not the check that
  # would have caught its own absence). Fixed by checking membership in
  # both directions.
  for w in "${WIRE_INSTRUMENTS[@]}"; do
    FOUND=0
    for n in "${NAMES[@]}"; do
      [ "$n" = "$w" ] && FOUND=1 && break
    done
    if [ "$FOUND" = "0" ]; then
      echo "SELFTEST FAILED: $w is in WIRE_INSTRUMENTS but never ran — no"
      echo "run_instrument call for it above. A missing instrument is"
      echo "indistinguishable from a passing one unless this is checked."
      SELFTEST_OK=0
    fi
  done
  for i in "${!NAMES[@]}"; do
    for w in "${WIRE_INSTRUMENTS[@]}"; do
      if [ "${NAMES[$i]}" = "$w" ] && [ "${RESULTS[$i]}" != "FAIL" ]; then
        echo "SELFTEST FAILED: $w reported ${RESULTS[$i]} with a stale "
        echo "schema_major forced in — it should have aborted."
        SELFTEST_OK=0
      fi
      if [ "${NAMES[$i]}" = "$w" ] && ! grep -q "PREFLIGHT ABORT" "$OUT_DIR/${NAMES[$i]}.log"; then
        echo "SELFTEST FAILED: $w failed for a reason other than the forced "
        echo "stale constant (no PREFLIGHT ABORT in its log) — see $OUT_DIR/${NAMES[$i]}.log."
        SELFTEST_OK=0
      fi
    done
  done
  if [ "$SELFTEST_OK" = "1" ]; then
    echo "SELFTEST PASSED: all ${#WIRE_INSTRUMENTS[@]} wire-speaking"
    echo "instruments ran and caught the forced-stale constant, aborting via"
    echo "PREFLIGHT ABORT, exactly as 10.40's self-check is meant to."
    exit 0
  fi
  exit 1
fi

if [ "$FAILED_ANY" = "1" ]; then
  echo "FAIL: at least one instrument exited non-zero. Read its log above —"
  echo "distinguish a genuine open finding from a broken instrument before"
  echo "deciding what this means for the gate."
  exit 1
fi
# **Say what this run actually covered, not only that it passed** (task
# 11.155). A gate suite that quietly ran fewer instruments than the last one —
# because a script was not in the checkout, or a `run_instrument` line was
# dropped in a refactor — is the fourth verdict `UNEXERCISED_CONTROLS.md`
# names: executed constantly, by the right mechanism, against almost none of
# its subject. The counts and the commit go in the last line CI keeps, so a
# person reading a five-line tail sees the number change.
echo "PASS: all ${#NAMES[@]} instrument(s) ran against a live server and exited zero; ${#NAMES[@]} of ${#NAMES[@]} derived from a '# gate-instrument:' declaration in the script they run (${#DERIVED_WIRE[@]} wire-speaking, out of $SCANNED scripts scanned), at commit $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)."
