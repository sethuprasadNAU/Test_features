#!/usr/bin/env bash
# gate-instrument: audit_retention_status
# Is this server still holding rows it said it would delete? (task 11.79 / §4.7)
#
#   scripts/audit_retention_status.sh
#
# One word, because the question it answers is one an operator should be able to
# ask without remembering anything: are the retention windows in the
# documentation describing what is on disk, or describing an intention?
#
# It measures **the age of the oldest surviving row** in each class — never
# whether a scheduler is running. A wedged loop, a stopped container and a
# database the sweep cannot write to are all the same fact to a person, and they
# all come out red here.
#
# This asks exactly the question the `audit-retention` service's healthcheck
# asks, by running the same program, so `docker compose ps` and this script can
# never disagree. If you only ever run one command about retention,
# `docker compose ps` already tells you — this exists for the times you want
# the sentence rather than the colour.
#
# **Checked against the lens that broke the equivalent claim in
# `backup_status.sh` (task 11.94/11.125): identity, location, visibility.**
# Unlike backup status, this check has nothing host-filesystem-owned to read —
# the answer lives in Postgres, reached over the network — and neither this
# script's `docker compose run` nor the service's own healthcheck sets a
# `user:` override, so both run as the same (default) container user against
# the same database. There is no seam here for the two to see different
# things. The claim holds.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

. scripts/lib/load_env.sh

# Postgres IS a dependency here, unlike scripts/backup_status.sh: the answer
# lives in the database and there is no honest way to give one without it. On a
# stopped stack this starts the database, asks, and leaves it up — the same
# thing `docker compose up` would have done.
#
# `--build`: this can be the first thing run on a machine whose server image
# predates task 11.79, where the binary does not exist and the failure is
# `executable file not found` — a message about a container for a question
# about retention. Building is cached and costs about a second.
#
# `COMPOSE` (task 11.125, item 2(ii)): until 2026-09-02 **nothing anywhere
# called this script**, and Michael had never run it — so the one command an
# operator is told to reach for had never been observed answering. It now runs
# in `gate_smoke_test.sh` against that run's own stack, and the only thing that
# stood in the way was the compose invocation being a literal: the gate's stack
# is `-p tritrack-gate`, and a bare `docker compose` here would have started a
# second, unrelated project's database to answer a question about the gate's.
# Unset, it is exactly the line an operator has always run.
COMPOSE=${COMPOSE:-"docker compose"}
# shellcheck disable=SC2086  # COMPOSE is a command line, deliberately split.
$COMPOSE run --rm --build -T audit-retention --check
