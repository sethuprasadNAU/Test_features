#!/usr/bin/env bash
# gate-instrument: none - an operator question about a live deployment's backup age; the gate's throwaway stack has no backup history to read.
# How old is the newest backup? (task 11.78 / Security Model §4.9)
#
#   scripts/backup_status.sh
#
# One word, because the question it answers is the one an operator should be
# able to ask without remembering anything: is there a recent encrypted archive
# of this server's database, or not?
#
# Three answers, and they are deliberately different sentences — a stale backup
# and no backup at all are not the same situation. Stale means the schedule
# broke at a knowable moment and there is still a restorable copy of something.
# Absent means every observation on this server exists only on the phones that
# recorded it.
#
# This asks the same question the `backup-scheduler` service's healthcheck asks,
# by running the same program. If you only ever run one command about backups,
# `docker compose ps` already tells you — this exists for the times you want
# the sentence rather than the colour.
#
# ## They CAN disagree, and the disagreement is the finding
#
# **This header used to say the two "can never disagree", and on 2026-09-02
# they did** (task 11.125). Same program, same directory — **different
# identity.** This script sources `scripts/lib/backup_user.sh`, so the
# container it starts runs as the person typing; the `backup-scheduler`
# service runs as whatever `TRITRACK_BACKUP_UID`/`GID` were when the stack was
# brought up, and on the beta host they were unset, so it ran as the image's
# uid 70 against a `backups/` directory owned by uid 1000. The scheduler could
# not read the directory and reported **freshness unknown**; this script read
# it fine and reported **50 hours old, backups have stopped**. Both were
# telling the truth about what they could see.
#
# So: **a disagreement between this script and `docker compose ps` is not
# noise. It means the scheduler cannot read `backups/`, and therefore that it
# has not written to it either** — which is exactly what had been happening,
# unseen, since 2026-08-31. Compare the two deliberately rather than trusting
# whichever you ran; `scripts/server_up.sh` now prints the scheduler's uid and
# the directory's owner side by side for the same reason.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

. scripts/lib/load_env.sh
# shellcheck disable=SC1091
. scripts/lib/backup_user.sh

# `--no-deps`: this reads a directory. It has no reason to start Postgres, and
# on a stopped stack the honest answer is still "here is how old the newest
# archive is", not a database that had to be booted to say so.
# `--build`: this can be the first thing anyone runs on a machine whose backup
# image predates the freshness check, and a stale image fails with
# `executable file not found in $PATH` — a message about a container for a
# question about backups. Building is cached and costs about a second.
# `COMPOSE` (task 11.140), the same seam `scripts/audit_retention_status.sh`
# already carries: unset, this is exactly the line an operator has always run.
# `scripts/operator_status.sh` sets it so that the composite status command
# asks this question of the stack it was pointed at, rather than of whatever
# `docker compose` resolves to in the current directory.
COMPOSE=${COMPOSE:-"docker compose"}
# shellcheck disable=SC2086  # COMPOSE is a command line, deliberately split.
$COMPOSE --profile backup run --rm --no-deps --build -T \
  backup tritrack-backup-freshness
