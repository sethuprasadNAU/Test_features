#!/usr/bin/env bash
# gate-instrument: none - brings up the throwaway stack the broken-control
# drills attack in their healthy phase; it sends no request of its own.
#
# Task 11.312, item 3. This exact bring-up — same compose project, same two
# named services, same health wait — lived in two places that had already
# drifted from each other without anybody deciding to change either:
# `.github/workflows/broken-control-check.yml`'s own "Bring up the healthy
# stack" step, and the paragraph task 11.310's report typed out for Michael
# to run by hand on the VM (`README.md`/`TASK_COMMS.md`, 2026-09-23, step 5).
# Nothing had ever compared the two, and nothing stopped a third copy
# appearing the next time somebody needed this stack up. One script now,
# used by both — see the CI workflow's own "Bring up the healthy stack" step
# and task 11.312's VM instructions.
#
#   scripts/gate_drill_stack_up.sh
#
# Brings up the same `tritrack-gate` project the four `verify_*_broken_control.py`
# drills expect their HEALTHY phase to find (`port_holder.check_stack`, task
# 11.310, checks exactly this), then waits for /health. It does not run any
# drill and it does not tear anything down — that is each drill's own job
# (the drills' BROKEN phase brings up and tears down its own throwaway
# stacks under different project names) and the CI workflow's final "Tear
# down" step.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Task 11.69: run the server as the invoking user so the magic link every
# instrument the drills drive has to read is readable — see
# scripts/lib/host_user.sh for what this does and does not change.
# shellcheck disable=SC1091
. scripts/lib/host_user.sh

COMPOSE=(docker compose -p tritrack-gate -f docker-compose.yml -f docker-compose.e2e.yml)

# **Task 11.310's guard, reused rather than a second copy — task 11.312 item
# 2's own instruction, applied here too.** In CI nothing else is ever on
# 8080. On a machine that also serves TriTrack — the Ubuntu VM — this stack
# would otherwise try to bind the real server's port and either fail
# opaquely or, if the real server happens to be down for another reason,
# silently attack whatever comes up next on it. Checked before building
# anything.
echo "Checking that port 8080 is free before building anything..."
if ! python3 scripts/lib/port_holder.py free 8080; then
  echo "FAIL: this stack needs port 8080, and something else holds it"
  echo "(above). Nothing was built. Stop the holder and run this again."
  exit 1
fi

echo "Bringing up the stack the broken-control drills' healthy phase attacks..."
# Named services, not the whole file (task 11.78, same reason as
# gate_smoke_test.sh): the base compose file's backup-scheduler service has
# no recipients configured for this stack and would sit unhealthy for the
# whole run, and a red container that is supposed to be red is how a real
# red stops being noticed.
mkdir -p .e2e_magic_links
"${COMPOSE[@]}" up --build -d postgres server

echo -n "Waiting for the server to answer /health..."
for _ in $(seq 1 60); do
  if curl -fsS http://localhost:8080/health >/dev/null 2>&1; then
    echo
    echo "Up: compose project 'tritrack-gate', services 'postgres' and 'server'."
    exit 0
  fi
  sleep 1
  echo -n "."
done
echo
echo "FAIL: the server never answered /health. Its log:" >&2
"${COMPOSE[@]}" logs --tail 40 server >&2
exit 1
