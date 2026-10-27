#!/usr/bin/env bash
# gate-instrument: none - a sourced helper, not a runnable instrument.
# The one place that knows how a harness waits for something to become ready
# (task 11.176).
#
# Source it from the repository root, after the usual `cd "$(dirname
# "${BASH_SOURCE[0]}")/.."`:
#
#   . scripts/lib/wait_for.sh
#
#   if ! wait_for 60 1 -- my_probe; then
#     fail "the thing never became ready. $(wait_for_evidence)"
#   fi
#
# ## Why this exists
#
# `scripts/verify_h6_archive_forgery.sh` waited for Postgres sixty times with
# `>/dev/null 2>&1` on every attempt, and then printed
# `HARNESS ERROR postgres never came up`. On 2026-09-06 Postgres was healthy
# the whole time: the probe ran `psql` *inside the backup container*, the
# backup image would not build, and `ERROR: unable to select packages` — the
# sentence naming the real cause — was thrown away sixty times, including on
# the last attempt. Task 11.175 had to carry that failure as a hypothesis
# rather than read it off the log.
#
# So: **a readiness loop's final attempt must surface what it actually got.**
# A harness that knows why it failed and does not say is worse than one that
# never knew.
#
# This keeps every attempt's combined output and hands the last one back
# through `wait_for_evidence`. Keeping it rather than re-running the probe once
# more with output shown is deliberate — a re-run can succeed, and a loop that
# gives up and then reports a success is a third wrong answer.
#
# It does not solve the *other* half of that defect, which is a probe that
# measures a compound (image AND network AND database) and names one of the
# three in its failure. Nothing generic can: only the caller knows what its
# probe touches. Where a probe cannot separate its causes, its message must
# say so.

# Set by `wait_for`. The combined stdout+stderr of the final attempt, and its
# exit status.
WAIT_FOR_LAST_OUTPUT=""
WAIT_FOR_LAST_STATUS=0

# wait_for <attempts> <interval-seconds> -- <command...>
#
# Runs the command until it exits zero or the attempts run out. Quiet while
# polling; returns 0 on success, 1 on exhaustion. Either way the last
# attempt's output is in WAIT_FOR_LAST_OUTPUT.
wait_for() {
  local attempts="$1" interval="$2"
  shift 2
  [ "${1:-}" = "--" ] && shift
  local i status
  WAIT_FOR_LAST_OUTPUT=""
  WAIT_FOR_LAST_STATUS=0
  i=1
  while [ "$i" -le "$attempts" ]; do
    status=0
    WAIT_FOR_LAST_OUTPUT="$("$@" 2>&1)" || status=$?
    WAIT_FOR_LAST_STATUS=$status
    [ "$status" = "0" ] && return 0
    [ "$i" = "$attempts" ] && break
    sleep "$interval"
    i=$((i + 1))
  done
  return 1
}

# The sentence a failure message appends. Never empty: "it printed nothing" is
# itself a finding, and a probe that fails silently is worth knowing about.
wait_for_evidence() {
  if [ -z "$WAIT_FOR_LAST_OUTPUT" ]; then
    printf 'The final attempt exited %s and printed nothing at all.' \
      "$WAIT_FOR_LAST_STATUS"
  else
    printf 'The final attempt exited %s and said:\n%s' \
      "$WAIT_FOR_LAST_STATUS" \
      "$(printf '%s\n' "$WAIT_FOR_LAST_OUTPUT" | sed 's/^/    /')"
  fi
}
