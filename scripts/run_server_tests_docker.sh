#!/usr/bin/env bash
# gate-instrument: none - the server unit suite, run on every commit by .github/workflows/server-suite.yml.
# Task 10.15's acceptance criterion: "server suite green in Docker from a
# clean checkout." Brings up a throwaway Postgres via
# docker-compose.server-test.yml (loopback-only, never the base compose
# file's port-less Postgres), points `dart test` at it, and tears everything
# down afterward regardless of the test result.
#
# Usage: scripts/run_server_tests_docker.sh
# Requires: .env (see .env.example), Docker, Docker Compose, the Dart SDK.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# `.env` is loaded in exactly one place — see that file for why (task
# 11.40 / 11.52). This used to be an eight-line block copied into seven
# scripts.
. scripts/lib/load_env.sh

PROJECT="tritrack-server-test"
COMPOSE="docker compose -p $PROJECT -f docker-compose.yml -f docker-compose.server-test.yml"
TEST_PORT="${SERVER_TEST_POSTGRES_PORT:-55432}"

cleanup() {
  $COMPOSE down -v
}
trap cleanup EXIT

$COMPOSE up -d postgres

echo "Waiting for Postgres to become healthy..."
for _ in $(seq 1 30); do
  status="$($COMPOSE ps postgres --format '{{.Health}}')"
  if [ "$status" = "healthy" ]; then
    break
  fi
  sleep 1
done
if [ "$status" != "healthy" ]; then
  echo "Postgres never became healthy." >&2
  exit 1
fi

# Where the run writes its machine-readable account of itself. Task 11.155:
# **`dart test` exits 0 when every test it loaded was skipped, and when it
# loaded only some of the files it should have** — measured on 2026-09-04, not
# assumed. (Loading *nothing* is loud: an empty package exits 79.) So this
# script's exit code distinguishes "the server suite passed" from "the server
# suite blew up", but not from "the server suite ran eleven of its fifty-five
# files". The report below is what `scripts/assert_suite_scope.py` reads to
# tell those apart, and the counts it prints go in the log on every run, green
# or red, so the number is where a person will see it change.
REPORT="$(mktemp "${TMPDIR:-/tmp}/tritrack-server-suite.XXXXXX")"
trap 'rm -f "$REPORT"; cleanup' EXIT

test_rc=0
(
  cd server
  dart pub get
  POSTGRES_HOST=127.0.0.1 \
    POSTGRES_PORT="$TEST_PORT" \
    POSTGRES_DB="$POSTGRES_DB" \
    POSTGRES_USER="$POSTGRES_USER" \
    POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
    dart test --file-reporter="json:$REPORT"
) || test_rc=$?

# Run the scope check even when the suite is red: a red suite that also ran a
# tenth of its files is two findings, and the second one is the silent one.
scope_rc=0
python3 scripts/assert_suite_scope.py \
  --report "$REPORT" \
  --test-dir server/test \
  --report-cwd server \
  --label "server suite in Docker" || scope_rc=$?

if [ "$test_rc" != 0 ]; then
  echo "The server suite itself failed (dart test exited $test_rc); read its output above."
  exit "$test_rc"
fi
exit "$scope_rc"
