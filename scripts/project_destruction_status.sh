#!/usr/bin/env bash
# gate-instrument: project_destruction_status
# Is this server still holding a project its owner was told would be gone by
# now? (task 11.290)
#
#   scripts/project_destruction_status.sh
#
# One sentence, for the question an operator should be able to ask without
# remembering anything: are the deletion dates owners were shown being kept, or
# were they an intention?
#
# It measures **how far past its date the most overdue scheduled deletion is**
# — never whether the sweep is running. A wedged loop, a stopped container and a
# database the sweep cannot write to are all the same fact to a person, and they
# all come out red here.
#
# This asks exactly the question the `project-destruction` service's
# healthcheck asks, by running the same program, so `docker compose ps` and this
# script can never disagree. Same identity, same location, same visibility as
# `scripts/audit_retention_status.sh`, and for the same reason: the answer lives
# in Postgres over the network, and neither this `docker compose run` nor the
# service's own healthcheck sets a `user:` override.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

. scripts/lib/load_env.sh

# Postgres IS a dependency here: the answer lives in the database and there is
# no honest way to give one without it. On a stopped stack this starts the
# database, asks, and leaves it up — the same thing `docker compose up` would
# have done.
#
# `--build`: this can be the first thing run on a machine whose server image
# predates task 11.290, where the binary does not exist and the failure is
# `executable file not found` — a message about a container for a question
# about deletions. Building is cached and costs about a second.
#
# `COMPOSE`: the gate's stack is `-p tritrack-gate`, and a bare `docker compose`
# here would start a second, unrelated project's database to answer a question
# about the gate's. Unset, it is exactly the line an operator runs.
COMPOSE=${COMPOSE:-"docker compose"}
# shellcheck disable=SC2086  # COMPOSE is a command line, deliberately split.
$COMPOSE run --rm --build -T project-destruction --check
