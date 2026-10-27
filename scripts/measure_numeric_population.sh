#!/usr/bin/env bash
# gate-instrument: none - a one-off measurement written for task 11.158, not a control.
# How many stored rows would the stricter numeric rule newly refuse?
# (task 11.158)
#
#   scripts/measure_numeric_population.sh
#
# Run this on the machine the beta server runs on, from the repository
# directory, with the stack up. It prints a number and, underneath it, what
# that number means — the interpretation was written before the measurement,
# so there is nothing to argue about afterwards.
#
# ## What it is asking
#
# Until task 11.158, a numeric column holding something that is not a number
# — a latitude of "north" — was refused by nothing and stored as it arrived.
# Closing that newly refuses rows that already sync. This project has a rule
# about doing that without counting them first, and this is the count.
#
# It also counts the two rows the same task's new floors would refuse: a
# `revision` below zero, and a triangulation window of zero minutes or less.
#
# ## Why it is a mode of the server binary
#
# The list of numeric columns is derived from the shared schema declaration
# rather than typed into this file. Ninety-odd column names written out here
# would be a hand-maintained list, wrong the first time somebody adds a
# column, and it would fail silently — by measuring a smaller database than
# the one it claims to have measured.
#
# ## `exec`, never `run`
#
# Task 11.140's rule: a status command must not start the thing it came to
# ask about. On a stopped stack this says so and stops, which is the honest
# answer — a database that is down is not a database with no bad rows in it.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

. scripts/lib/load_env.sh

# See `scripts/audit_retention_status.sh` for why this is a variable: the gate
# smoke test runs against its own compose project, and a bare `docker compose`
# here would ask a different database than the one under test.
COMPOSE=${COMPOSE:-"docker compose"}

# shellcheck disable=SC2086  # COMPOSE is a command line, deliberately split.
if ! $COMPOSE exec -T server /app/bin/server --numeric-population; then
  echo
  echo "COULD NOT CHECK. The server container did not answer."
  echo "Nothing was measured — that is not the same as nothing being found."
  echo "Bring the stack up (docker compose up -d) and run this again."
  exit 1
fi
