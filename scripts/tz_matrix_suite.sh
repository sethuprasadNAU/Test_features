#!/usr/bin/env bash
# gate-instrument: none - a local diagnostic runner, not part of any gate. It runs the *whole*
# `flutter test` suite, unchanged, once under each of a small argued set of `TZ` values, so a
# defect that depends on how far the wall clock sits from local midnight can be found without
# waiting to happen to run the suite at the wrong hour.
#
# **Task 11.275, 2026-09-17.** Task 11.271 built a fixed-clock harness scoped to one file's
# date-boundary logic and said plainly that it did not close the wider question: "nobody
# currently knows whether main is green -- only that it is green at the times somebody happened
# to run it." This is that wider check. It changes no test -- every defect in this class so far
# (tasks 11.263, 11.269, 11.273) turned on DateTime.now().toLocal(), which follows the process
# time zone, so changing TZ before the Dart VM starts is enough to sample a different distance
# from midnight without touching test/ at all.
#
# ## The three zones, and why these three
#
# - America/Phoenix (UTC-7, no DST) -- Michael's own zone, where every time-of-day defect in
#   this project has actually surfaced.
# - UTC -- the zone every CI runner uses, and the one most reports are silently measured in.
# - Australia/Brisbane (UTC+10, no DST) -- the sign of the offset is what the earlier
#   `_setAttached` defect turned on, so a UTC-positive zone is load-bearing, not decorative.
#
# Neither Phoenix nor Brisbane observes DST, so a case here does not depend on the calendar
# date. This script does NOT choose zones to land near midnight -- "now" lands wherever it
# lands each time this is run, and the script prints the local time it got so a reader can see
# how close to midnight each run actually was, rather than assuming the riskiest case was
# sampled.
#
# ## What this samples, and what it does not
#
# This runs the ordinary suite three times at (nearly) one instant, under three timezones. It
# is one more sample of "distance from local midnight", not a sweep of every possible distance,
# and not a repeat of the same run (see scripts/repeat_suite.sh for that) or a fixed-clock
# reproduction of one file's boundary logic (see scripts/clock_matrix_test.sh for that).
# A clean result here means the suite was clean at three distances from midnight on one day --
# not that it is clean at every distance, on every day.
#
# Usage: scripts/tz_matrix_suite.sh
#   No arguments. Exits non-zero if any zone's run failed or did not reach the whole suite.
#   Logs (raw JSON streams, one per zone) land in a run directory printed at the end.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v flutter >/dev/null 2>&1; then
  echo "tz_matrix_suite: flutter is not on PATH." >&2
  exit 2
fi

zones=(
  'America/Phoenix|Michael'"'"'s own zone -- every time-of-day defect in this project has surfaced here'
  'UTC|the zone CI and most silent runs use'
  'Australia/Brisbane|a UTC-positive zone -- the offset sign is what the _setAttached defect turned on'
)

out_dir="$(mktemp -d "${TMPDIR:-/tmp}/tritrack-tz-matrix.XXXXXX")"
echo "tz_matrix_suite: running the full suite once per zone. Logs in ${out_dir}"

overall_status=0
declare -a summary=()

for entry in "${zones[@]}"; do
  tz="${entry%%|*}"
  reason="${entry#*|}"
  local_now="$(TZ="$tz" date '+%Y-%m-%d %H:%M:%S %Z')"
  echo ""
  echo "tz_matrix_suite: TZ=${tz} (${reason})"
  echo "tz_matrix_suite: local time at start of this run: ${local_now}"
  stream="${out_dir}/${tz//\//_}.json"
  start=$(date +%s)
  (cd "$repo_root" && TZ="$tz" flutter test --reporter json) >"$stream" 2>&1
  end=$(date +%s)
  elapsed=$((end - start))
  verdict="$(python3 "$repo_root/scripts/lib/suite_verdict.py" "$repo_root" "$stream")"
  verdict_status=$?
  if [[ $verdict_status -eq 0 ]]; then
    summary+=("TZ=${tz}: PASS (${elapsed}s, local ${local_now})")
    echo "tz_matrix_suite: TZ=${tz} PASS (${elapsed}s)"
    echo "$verdict" | sed 's/^/    /'
  else
    overall_status=1
    summary+=("TZ=${tz}: FAIL (${elapsed}s, local ${local_now})")
    echo "tz_matrix_suite: TZ=${tz} FAIL (${elapsed}s) -- log follows"
    echo "$verdict" | sed 's/^/    /'
  fi
done

echo ""
echo "tz_matrix_suite: summary"
for line in "${summary[@]}"; do
  echo "  ${line}"
done
echo "tz_matrix_suite: raw JSON streams kept in ${out_dir}"

if [[ $overall_status -ne 0 ]]; then
  echo "tz_matrix_suite: at least one zone's run failed or did not reach the whole suite."
else
  echo "tz_matrix_suite: the suite was clean at all three zones' distances from midnight, today. That is not the same as clean at every distance."
fi
exit $overall_status
