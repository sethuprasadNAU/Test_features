#!/usr/bin/env bash
# gate-instrument: none - a local diagnostic runner, not part of any gate. It runs a scoped
# set of tests under a small, argued set of fixed clocks so a date-boundary defect (task
# 11.271) reproduces on demand instead of only when somebody happens to run the suite near
# local midnight.
#
# **Task 11.271, 2026-09-17.** Two evenings and three commits (tasks 11.269 and 11.273) were
# spent on the same shape of bug in `test/features/more/animals_screen_test.dart` and
# `lib/features/more/screens/animal_detail_screen.dart`: "is this instant on the same
# calendar day as now" answered differently depending on the hour the suite happened to run.
# `scripts/repeat_suite.sh` running that file ten times in one evening never varied the one
# thing that mattered — see its own header comment.
#
# ## What this controls, and what it cannot
#
# The clock-matrix tests inside `animals_screen_test.dart`'s "clock matrix" group use two
# different, narrower mechanisms for two different defects:
#
# - `withClock`/`package:clock` pins what `clock.now()` returns inside the test process — the
#   one production seam this task added (`animal_detail_screen.dart`'s `_now` getter). This is
#   set from *inside* Dart and needs nothing from this script.
# - Which calendar day a value **already round-tripped through the database** falls on is
#   decided by `DateTime.toUtc()`/`.toLocal()`, which always ask the real OS/ICU timezone
#   database — `withClock` cannot reach that. The only way to control it is the process's own
#   timezone, set via `TZ` before the Dart VM starts. That is what this script actually varies.
#
# So this script runs `flutter test`, filtered to the "clock matrix" group and (task 11.318
# item 6) the "linking on a date the person chooses" group, once per `TZ` below. A case
# whose `TZ` does not match the one it was launched under reports itself skipped (with a stated reason) rather than silently passing under the wrong zone — see that
# group's own comment for why each case needs the `TZ` it needs.
#
# ## What this does NOT sample
#
# This is a small, scoped harness for one file with a known history, not a general
# time-of-day check. Every `DateTime.now()` call outside `animal_detail_screen.dart`'s `_now`
# seam — about 75 other call sites in `lib/`, and every other test file's `DateTime.now()` —
# still reads the real, unfixed clock and is not exercised by this script. See task 11.271's
# entry in `CLAUDE_DOCS/DEVELOPMENT_PLAN.md` for the named list.
#
# Also does not chase DST: both zones below are chosen because neither observes it.
#
# Usage: scripts/clock_matrix_test.sh
#   No arguments. Exits non-zero if any case's tests failed (a skip is not a failure).

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if ! command -v flutter >/dev/null 2>&1; then
  echo "clock_matrix_test: flutter is not on PATH." >&2
  exit 2
fi

target='test/features/more/animals_screen_test.dart'
# **Task 11.318 item 6: two groups, not one.** `--plain-name` given twice means
# "matches both", which matches nothing, so this is a regex. The second group is
# task 11.322's linking-on-a-chosen-date tests: they write deployment dates, so
# "which calendar day is it" decides what is stored, and they had never run
# under a zone other than the Mac's own.
name_pattern='clock matrix|linking on a date the person chooses'

zones=(
  'America/Phoenix'
  'Asia/Tokyo'
)

overall_status=0

for tz in "${zones[@]}"; do
  echo ""
  echo "clock_matrix_test: TZ=${tz}"
  log="$(mktemp "${TMPDIR:-/tmp}/tritrack-clock-matrix.XXXXXX")"
  if TZ="$tz" flutter test "$target" --name "$name_pattern" --reporter expanded \
      >"$log" 2>&1; then
    echo "clock_matrix_test: TZ=${tz} PASS (a case not native to this zone reports itself skipped, not a failure)"
  else
    overall_status=1
    echo "clock_matrix_test: TZ=${tz} FAIL — log follows"
    sed 's/^/    /' "$log"
  fi
done

echo ""
if [[ $overall_status -eq 0 ]]; then
  echo "clock_matrix_test: every case that ran under its own TZ passed."
else
  echo "clock_matrix_test: at least one TZ's run failed. See the log above."
fi
exit $overall_status
