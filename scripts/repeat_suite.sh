#!/usr/bin/env bash
# gate-instrument: none - a local diagnostic runner, not part of any gate. It runs the full
# `flutter test` suite N times in a row (default 10) and reports pass/fail plus the failing
# test's file and name for each run, so a suite that answers differently on consecutive runs
# can be reproduced on demand rather than argued about.
#
# **Task 11.253, 2026-09-15.** Built after task 11.246 saw two consecutive full-suite runs fail
# in two different places (`test/security/no_committed_secrets_test.dart`'s setup, then
# `test/widgets/tag_edit_intent_dialog_test.dart`), both passing standalone. `CLAUDE.md`'s rule
# is to reproduce with a stated denominator before theorising — this is that denominator, kept
# runnable rather than re-invented each time. See task 11.205 for the method this follows.
#
# Usage: scripts/repeat_suite.sh [N]
#   N defaults to 10. Logs land in a run directory printed at the end; each run's raw JSON
#   stream is kept so a failure can be re-read without re-running.
#
# **Task 11.271.** Repetition samples load and ordering — it runs the suite N times in
# whatever few minutes it takes, all at roughly the same wall-clock hour. It does NOT sample
# the clock: a test that only fails within an hour of local midnight passes N/N here every
# time this is run earlier in the day, with a straight face. For that, run
# scripts/clock_matrix_test.sh, which fixes the clock instead of repeating the run.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runs="${1:-10}"

if ! command -v flutter >/dev/null 2>&1; then
  echo "repeat_suite: flutter is not on PATH." >&2
  exit 2
fi

out_dir="$(mktemp -d "${TMPDIR:-/tmp}/tritrack-repeat-suite.XXXXXX")"
echo "repeat_suite: running the full suite ${runs} times. Logs in ${out_dir}"

pass_count=0
fail_count=0
declare -a summary=()

for i in $(seq 1 "$runs"); do
  stream="${out_dir}/run-${i}.json"
  start=$(date +%s)
  (cd "$repo_root" && flutter test --reporter json) >"$stream" 2>&1
  end=$(date +%s)
  verdict="$(python3 "$repo_root/scripts/lib/suite_verdict.py" "$repo_root" "$stream")"
  verdict_status=$?
  elapsed=$((end - start))
  if [[ $verdict_status -eq 0 ]]; then
    pass_count=$((pass_count + 1))
    summary+=("run ${i}: PASS (${elapsed}s)")
    echo "run ${i}/${runs}: PASS (${elapsed}s)"
  else
    fail_count=$((fail_count + 1))
    first_line="$(echo "$verdict" | sed -n '2p')"
    summary+=("run ${i}: FAIL (${elapsed}s) - ${first_line}")
    echo "run ${i}/${runs}: FAIL (${elapsed}s)"
    echo "$verdict" | sed 's/^/    /'
  fi
done

echo ""
echo "repeat_suite: ${pass_count}/${runs} passed, ${fail_count}/${runs} failed."
for line in "${summary[@]}"; do
  echo "  ${line}"
done
echo "repeat_suite: raw JSON streams kept in ${out_dir}"

if [[ $fail_count -gt 0 ]]; then
  exit 1
fi
exit 0
