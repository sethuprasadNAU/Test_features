#!/usr/bin/env bash
# gate-instrument: none - the push gate's Flutter suite, which requires the server stack to be DOWN and so cannot run inside this one.
# Task 10.15's headline test, as an explicit named run rather than an
# assumption: the full Flutter suite, green, with the server stack
# explicitly down first.
#
# Usage: scripts/run_offline_suite.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

PORT="${SERVER_PORT:-8080}"

echo "Bringing the server stack down (if it was ever up)..."
docker compose down 2>/dev/null || true

# W-6 (TriTrack_Security_Model.md §10.7.1): `docker compose down ... || true`
# swallows both "brought it down" and "could not bring it down" into the same
# branch, and the script used to go straight from there to claiming "no
# server running" without ever having checked. "Could not bring the stack
# down" and "the stack was never up" must not read the same. Confirm nothing
# actually answers on the server port before trusting the offline claim below.
if curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
  echo "ABORT: something is still answering on 127.0.0.1:${PORT} after" \
       "'docker compose down'. This suite's whole claim is that the app" \
       "passes with no server reachable — that is not true right now, so" \
       "refusing to run it and call the result meaningful." >&2
  exit 1
fi

# **Task 11.156: `flutter test` exits 0 over an unknown fraction of `test/`.**
# Until 2026-09-04 this script ran a bare `flutter test` and echoed PASS on its
# exit code — and a run that loaded a tenth of the files and passed everything
# it loaded exits 0 too. Nothing anywhere stated how many test files were
# reached. That is task 11.150's class one layer up: that check was green over
# one commit because the *checkout* narrowed it; this suite was green over an
# unknown fraction because the *invocation* did. This is the gate that runs on
# every push and it is the largest suite in the project.
#
# The JSON report below is what `scripts/assert_suite_scope.py` reads to tell
# "the suite passed" from "the suite ran a quarter of itself and passed that".
# It asserts the loaded suites against the `*_test.dart` files on disk, and the
# skipped tests against the declared set in `test/declared_skips.json` — both
# in both directions, neither of them a number anybody chose.
#
# **Measured cost, 2026-09-04, on the development Mac: not distinguishable
# from this machine's own noise, so not material.** Two pairs of full runs,
# reporter off then on: **111.3 s -> 106.4 s** and **81.7 s -> 84.8 s**. The
# reporter run was 4.9 s *faster* in one pair and 3.1 s slower in the other,
# and the same command with no reporter took 111.3 s once and 81.7 s the next
# time — a 29.6 s spread, an order of magnitude larger than any within-pair
# difference. **The honest reading is that the reporter's overhead on a
# 2,196-test suite is smaller than this measurement can resolve**, not that it
# is exactly zero. The report file it writes is 2.0 MB, to a temp path that
# the trap above deletes.
REPORT="$(mktemp "${TMPDIR:-/tmp}/tritrack-offline-suite.XXXXXX")"
trap 'rm -f "$REPORT"' EXIT

# **Task 11.325 item 2: one time zone for the whole suite, so "which tests skip"
# has one answer.** Four "clock matrix" tests in `animals_screen_test.dart` skip
# themselves unless the process started under the one zone they were written
# for (they read the real OS zone, which `withClock` cannot reach). Measured
# 2026-10-01 and 2026-10-02: on a Mac in Phoenix three of the four run, on a Mac
# on Eastern time all four skip, and CI (UTC) skipped all four — so
# `declared_skips.json` could not name them, because a declared skip that does
# not skip fails the scope check just as an undeclared one does. Pinning UTC
# here makes it four skips everywhere, declared by name there; those four tests
# run, under the zones they need, in `scripts/clock_matrix_test.sh`.
#
# **Task 11.326: UTC is the default, not the only zone.** A UTC-only suite
# cannot see a date printed through the wrong zone: a deployment day is local
# midnight, and local midnight read back as UTC is the same day in UTC and
# west of it, the day before east of it. The held card named the wrong days in
# New Zealand and London for weeks while this suite was green. So the night
# runs this script twice more, with TRITRACK_SUITE_TZ east and west of UTC. The
# four clock-matrix skips are zone-shaped in `declared_skips.json`
# (`runs_under_tz`): under the zone a test was written for it must run, and the
# scope check below is told the zone so it can hold it to that.
export TZ="${TRITRACK_SUITE_TZ:-UTC}"

echo "Running the full Flutter suite with the server offline (TZ=$TZ)..."
test_rc=0
flutter test --file-reporter="json:$REPORT" || test_rc=$?

# Run the scope check even when the suite is red: a red suite that also reached
# a tenth of its files is two findings, and the second one is the silent one.
scope_rc=0
python3 scripts/assert_suite_scope.py \
  --report "$REPORT" \
  --test-dir test \
  --declared-skips test/declared_skips.json \
  --tz "$TZ" \
  --label "offline suite, TZ=$TZ" || scope_rc=$?

if [ "$test_rc" != 0 ]; then
  echo "The offline suite itself failed (flutter test exited $test_rc); read its output above."
  exit "$test_rc"
fi
if [ "$scope_rc" != 0 ]; then
  echo "The offline suite passed everything it ran, and the scope check above says" \
       "that was not the whole of test/. Do not read this as a pass."
  exit "$scope_rc"
fi

echo "PASS: the suite is fully green with no server running (verified: 127.0.0.1:${PORT} does not answer), and the scope line above says how much of test/ that was."
