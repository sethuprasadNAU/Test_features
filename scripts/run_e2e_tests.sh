#!/usr/bin/env bash
# gate-instrument: none - the end-to-end suite's own runner, with its own stack; running it from here would fight this run for 127.0.0.1:8080.
# One command for the end-to-end integration suite (task 10.17), which until
# now was four lines a person had to assemble by hand.
#
# Usage: scripts/run_e2e_tests.sh
# Requires: .env (see .env.example), Docker, Docker Compose, the Flutter SDK.
#
# ## Why this script exists
#
# The server suite has had `run_server_tests_docker.sh` since task 10.15 and
# the e2e suite never got one, so running it meant remembering a `docker
# compose` line with two `-f` flags and a `-p`, then a `flutter test` line
# with two environment variables on it. On 2026-08-27 the same person ran
# `flutter test test/e2e --tags e2e --run-skipped` without the variables
# twice in a row -- the second time from an error message that printed the
# full command -- and both runs produced thirty-odd failures.
#
# That is not a person failing to read. It is a suite whose correct
# invocation cannot be copied in one piece, next to a sibling suite whose
# correct invocation is one word. The message was the instrument; this is
# the fix.
#
# ## The trap it removes
#
# `--run-skipped` is required, because `dart_test.yaml` skips the `e2e` tag
# by default so a bare `flutter test` stays green offline. It is also
# precisely the flag that overrides `e2eSkipReason`, the opt-out that keeps
# an unconfigured run from executing anything. So the only way to run this
# suite is also the only way to run it against nothing at all, and the
# difference between the two is two environment variables. This script makes
# them not something anybody has to know.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# `.env` is loaded in exactly one place — see that file for why (task
# 11.40 / 11.52). This used to be an eight-line block copied into seven
# scripts.
. scripts/lib/load_env.sh
# Task 11.69: run the e2e server as this user so the suite can read the
# magic links it signs in with. See scripts/lib/host_user.sh.
# shellcheck disable=SC1091
. scripts/lib/host_user.sh

PROJECT="tritrack-e2e"
COMPOSE="docker compose -p $PROJECT -f docker-compose.yml -f docker-compose.e2e.yml"
PORT="${SERVER_PORT:-8080}"
BASE_URL="http://localhost:$PORT"
LINK_DIR=".e2e_magic_links"

# Named `-p tritrack-e2e` deliberately: `e2e_coverage_guard_test.dart` checks
# that the container answering this port belongs to *this* compose project,
# not merely that something answers (finding M-12). Keep the two in step.
KEEP_UP="${TRITRACK_E2E_KEEP_STACK:-0}"
RUN_LOG=".e2e_last_run.log"
# The machine-readable half of the same run. `$RUN_LOG` is for a person and
# `$REPORT` is for `scripts/assert_suite_scope.py`; see the block after the
# suite runs for why this script needs both. Deleted by `cleanup` — it is a
# 100 KB JSON file with every test name in it and no diagnostic value once the
# scope line has been printed.
REPORT="$(mktemp "${TMPDIR:-/tmp}/tritrack-e2e-suite.XXXXXX")"
# Empty until the suite has actually run, so `cleanup` can tell "the suite
# failed" from "the stack never came up".
SUITE_STATUS=""

# ## Why a red run is not torn down (task 11.130)
#
# `down -v` deletes the Postgres volume, and the audit log is in it. That log
# is the *only* place the server records why a magic link was not sent —
# §4.4/§4.5 require `/auth/magic-link` to answer the identical 202 whether it
# sent one, silently refused one on the per-address limit, or failed to write
# one — so tearing a red run down destroys the answer to the only question a
# red run raises.
#
# That is not hypothetical. On 2026-09-02 this suite failed with six sign-in
# links that never arrived; `test/e2e/support/magic_link_reader.dart` asked the
# audit log and printed a verdict for each one, this trap then deleted the
# database, and task 11.130 could not recover a single row. **The ledger
# recorded that the run happened and the runner deleted why.**
#
# So: green tears down as before, red leaves the stack standing and says what
# to ask it. The cost of being wrong in this direction is a container a person
# has to stop by hand; in the other it is the diagnosis.
cleanup() {
  rm -f "$REPORT"
  if [ "$KEEP_UP" = "1" ]; then
    echo "Leaving the stack up (TRITRACK_E2E_KEEP_STACK=1). Tear it down with:"
    echo "  $COMPOSE down -v"
    return
  fi
  if [ -n "$SUITE_STATUS" ] && [ "$SUITE_STATUS" != "0" ]; then
    echo
    echo "LEAVING THE STACK UP, because this run was red and its Postgres"
    echo "volume holds the only record of why (task 11.130). The suite's whole"
    echo "output, including each failure's audit-log verdict, is in $RUN_LOG."
    echo "To ask the server directly which magic-link requests it refused and"
    echo "which it sent:"
    # One line, because a wrapped one is a line somebody has to reassemble at
    # the moment they are least able to. Verified against a live red stack on
    # 2026-09-02 rather than written and trusted.
    echo "  $COMPOSE exec postgres psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -c \"SELECT occurred_at, event, outcome FROM auth_audit_log WHERE event IN ('link_requested','rate_limit_tripped') ORDER BY occurred_at\""
    echo "A rate_limit_tripped/email_limited row means the per-address limit"
    echo "silently refused that request (§4.4); link_requested/internal_error"
    echo "means delivery failed and no link exists; link_requested/sent means"
    echo "the link was issued and something between the container and this host"
    echo "swallowed it. Tear the stack down when you are done:"
    echo "  $COMPOSE down -v"
    return
  fi
  echo "Tearing down the e2e stack..."
  $COMPOSE down -v
}
trap cleanup EXIT

# The bind-mount target. Created here rather than left to Docker, which would
# make it root-owned and then unreadable by the test process that has to read
# a token out of it.
mkdir -p "$LINK_DIR"

echo "Bringing up the e2e stack on $BASE_URL ..."
# Named services rather than the whole file (task 11.78). The base compose file
# now carries a `backup-scheduler` service, which is right for a deployment and
# wrong here: this suite has no backup recipients configured, so the scheduler
# would fail on a loop and report itself unhealthy for the length of every run,
# and a red container that is *supposed* to be red is how a real red stops being
# noticed. These two are exactly what `up` started before it existed.
$COMPOSE up --build -d postgres server

# **/ready, not /health (task 11.128).** Every test in this suite signs in, so
# a server with no database is useless to it — and /health answers 200 on one.
# /ready answers 503 with {"degraded":["database"]} instead. /health is still
# polled first so the failure below can name which of the two states it is.
echo "Waiting for the server to answer /ready ..."
ready=0
alive=0
for _ in $(seq 1 60); do
  if curl -fsS "$BASE_URL/health" >/dev/null 2>&1; then
    alive=1
    if curl -fsS "$BASE_URL/ready" >/dev/null 2>&1; then
      ready=1
      break
    fi
  fi
  sleep 1
done
if [ "$ready" != "1" ]; then
  if [ "$alive" = "1" ]; then
    echo "The server answered $BASE_URL/health but never became ready:" >&2
    echo "  $(curl -sS "$BASE_URL/ready" 2>&1)" >&2
    echo "The process is up and its database is not — a sign-in would 404." >&2
  else
    echo "The server never answered $BASE_URL/health. Recent logs:" >&2
  fi
  $COMPOSE logs --tail 40 server >&2 || true
  exit 1
fi

echo "Running the end-to-end suite..."
# Captured as well as shown. Every failure in this suite carries its own
# diagnosis — the magic-link reader queries the server's audit log and names
# the cause — and on 2026-09-02 six of those scrolled past unread. `tee` keeps
# them; `$RUN_LOG` is gitignored, because a failing assertion about a response
# body can print a live token and §4.7 has no development exemption.
set +e
TRITRACK_E2E_BASE_URL="$BASE_URL" \
  TRITRACK_E2E_MAGIC_LINK_DIR="$LINK_DIR" \
  flutter test test/e2e --tags e2e --run-skipped \
  --file-reporter="json:$REPORT" 2>&1 | tee "$RUN_LOG"
# The suite's status, not `tee`'s — which is always 0 and would report every
# red run as green.
SUITE_STATUS="${PIPESTATUS[0]}"
set -e

# ## Did that run reach the suite at all? (task 11.171)
#
# `--run-skipped` above is not an optimisation, it is the only reason any of
# these tests execute: `dart_test.yaml` skips the `e2e` tag by default. **Drop
# that one flag and `flutter test test/e2e --tags e2e` prints "All tests
# skipped." and exits 0** — so `$SUITE_STATUS` would be 0, the ledger below
# would append a `green` line, and the streak that decides whether this suite
# goes into continuous integration would be counting runs that ran nothing.
#
# That is task 11.156's finding on the sibling suite, one directory over, and
# `scripts/assert_suite_scope.py` is the control it already produced. This is
# the fourth caller it should have had. `--no-skips` is the right mode here
# and not merely the strictest one: this script exists to run *the tests the
# default configuration skips*, so a single skipped test in it is the whole
# failure mode rather than an edge of it.
#
# Run even when the suite is red, for the same reason the offline suite runs
# it then: a red run that also reached three of sixteen files is two findings,
# and only one of them is on the screen.
scope_rc=0
python3 scripts/assert_suite_scope.py \
  --report "$REPORT" \
  --test-dir test/e2e \
  --no-skips \
  --label "e2e suite" || scope_rc=$?

# **The verdict the ledger records is both halves.** `$SUITE_STATUS` stays the
# suite's own status, because `cleanup` above uses it to decide whether to
# leave Postgres standing and that message is about failing tests. `$RUN_STATUS`
# is what the ledger gets: a run that passed everything it loaded and loaded
# almost nothing is not a green run, and the ledger is the thing task 11.40's
# revisit trigger counts.
RUN_STATUS="$SUITE_STATUS"
if [ "$RUN_STATUS" = "0" ] && [ "$scope_rc" != "0" ]; then
  RUN_STATUS="$scope_rc"
fi

# ## The ledger, and why this script keeps one (task 11.125, item 4)
#
# Task 11.40 decided this suite stays out of continuous integration, and said
# it would be revisited **"after ten consecutive green runs or on the next
# unexplained failure."** Task 11.119 found the obvious thing: **nothing
# counted the runs.** The second half of that trigger can fire — somebody sees
# a failure they cannot explain — and the first half never could, so the
# decision rested on a condition no one was in a position to observe. A trigger
# nobody can pull is decoration.
#
# This is the counting. One line per run, appended here because **this script
# is the only way the suite is invoked** (that is what it was written for), so
# a run it does not see is a run that did not use the supported command.
#
# It is committed on purpose: the streak is a fact about the project rather
# than about one laptop, and a counter kept in `/tmp` would reset on the day
# somebody reboots. It is also therefore incomplete by construction — a run
# whose ledger line is never committed is invisible to everyone else, and the
# line below says the count it printed, so a reader can tell.
LEDGER="test/e2e/run_log.tsv"
GREEN_TRIGGER=10
if [ ! -f "$LEDGER" ]; then
  printf '# One line per run of scripts/run_e2e_tests.sh (task 11.125).\n' >"$LEDGER"
  printf '# utc\tcommit\tresult\n' >>"$LEDGER"
fi
printf '%s\t%s\t%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" \
  "$(if [ "$RUN_STATUS" = "0" ]; then echo green
      elif [ "$SUITE_STATUS" != "0" ]; then echo "red($SUITE_STATUS)"
      else echo "red(scope)"; fi)" \
  >>"$LEDGER"

STREAK=0
while IFS= read -r line; do
  case "$line" in
    '#'*) continue ;;
  esac
  case "$line" in
    *"	green") STREAK=$((STREAK + 1)) ;;
    *) STREAK=0 ;;
  esac
done <"$LEDGER"

echo
if [ "$SUITE_STATUS" = "0" ] && [ "$scope_rc" != "0" ]; then
  echo "E2E SUITE: every test it ran passed, and the scope check above says that"
  echo "was not the whole of test/e2e. DO NOT READ THIS AS A PASS. The commonest"
  echo "cause is the suite being selected differently than this script intends —"
  echo "with the e2e tag skipped, \"All tests skipped.\" is also exit 0. Recorded"
  echo "in $LEDGER as red, so it does not count towards task 11.40's streak."
  exit "$scope_rc"
elif [ "$SUITE_STATUS" != "0" ]; then
  echo "E2E SUITE RED (exit $SUITE_STATUS). Task 11.40's revisit trigger has a"
  echo "second half — 'on the next unexplained failure' — and this is a"
  echo "failure. If you cannot explain it, that trigger has fired: say so in"
  echo "CLAUDE_DOCS/TASK_COMMS.md and ask the planning session to reopen the"
  echo "question of putting this suite in CI. Ledger: $LEDGER"
elif [ "$STREAK" -ge "$GREEN_TRIGGER" ]; then
  echo "E2E SUITE GREEN — and that is $STREAK consecutive green runs recorded"
  echo "in $LEDGER, at or past task 11.40's threshold of $GREEN_TRIGGER. THE"
  echo "REVISIT TRIGGER HAS FIRED: ask the planning session to re-decide"
  echo "whether this suite belongs in continuous integration. Counted only"
  echo "from committed ledger lines, so it is a floor, not a total."
else
  echo "E2E SUITE GREEN — $STREAK consecutive green run(s) recorded in"
  echo "$LEDGER; task 11.40 revisits CI at $GREEN_TRIGGER. Commit the ledger"
  echo "line above or this run will not count for anybody else."
fi

# The scope-failure branch above has already exited on its own verdict, so by
# here the only thing left to report is the suite's.
exit "$SUITE_STATUS"
