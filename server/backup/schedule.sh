#!/bin/sh
# Takes a backup without anybody remembering to (task 11.78 / §4.9).
#
# ## Why this is a container and not a cron line
#
# `server/README.md` used to say "schedule it the same way as the audit purge —
# a daily cron. Nothing schedules it for you." That is a documented step a human
# performs and nothing checks, which is the class task 11.70 rejected when it
# chose a `user:` line in docker-compose.yml over a `chown` in the instructions.
# The same reasoning applies here and the stakes are higher: a `chown` somebody
# forgets produces a loud failure, and a cron entry somebody forgets produces
# silence and the belief that backups exist.
#
# So the schedule travels with the repository. `docker compose up` starts this,
# and `restart: unless-stopped` brings it back after a reboot — neither of which
# requires anyone to have read a README.
#
# ## It decides by the age of the archive, not by its own clock
#
# The loop does not remember when it last ran. Every wake-up it asks
# `tritrack-backup-freshness` how old the newest archive is and takes a backup
# when that exceeds TRITRACK_BACKUP_INTERVAL_HOURS. Three things follow, and
# they are the reason for the design rather than side effects:
#
#   - a container restarted five times an hour does not take five backups;
#   - a machine that was switched off for a week takes one immediately on
#     return, rather than waiting a day for the next tick;
#   - somebody who takes a manual backup with `scripts/backup_db.sh` has
#     genuinely satisfied the schedule, because the schedule is a statement
#     about archives and not about this process.
#
# ## It stays running when it is failing
#
# A failed backup logs loudly and the loop continues. It must NOT exit: a
# stopped container has no healthcheck, so exiting on failure would replace a
# red signal with no signal — which is the whole shape of the defect this file
# exists to end. The archive keeps ageing, the healthcheck keeps saying so, and
# the container stays up to keep saying it.
set -u

INTERVAL_HOURS="${TRITRACK_BACKUP_INTERVAL_HOURS:-24}"
CHECK_SECONDS="${TRITRACK_BACKUP_CHECK_SECONDS:-3600}"
INTERVAL_SECONDS=$((INTERVAL_HOURS * 3600))

echo "tritrack-backup-schedule: a backup when the newest archive passes ${INTERVAL_HOURS}h; checked every ${CHECK_SECONDS}s."
echo "Staleness is reported separately at TRITRACK_BACKUP_MAX_AGE_HOURS=${TRITRACK_BACKUP_MAX_AGE_HOURS:-48}h — that is the number the healthcheck uses."

while :; do
  # `--age-seconds` prints nothing and exits non-zero when no archive exists,
  # which is the "take one now" case as much as an over-age archive is.
  if AGE="$(tritrack-backup-freshness --age-seconds 2>/dev/null)" \
     && [ -n "$AGE" ] && [ "$AGE" -lt "$INTERVAL_SECONDS" ]; then
    echo "--- $(date -u +%Y-%m-%dT%H:%M:%SZ) newest archive is $((AGE / 3600))h old, under the ${INTERVAL_HOURS}h interval — nothing to do."
  else
    echo "--- $(date -u +%Y-%m-%dT%H:%M:%SZ) taking a backup."
    if tritrack-backup; then
      echo "Backup finished."
    else
      # Never fatal to this loop. See the header: exiting would take the
      # healthcheck with it and turn a visible failure into a silent one.
      # Retried sooner than a successful cycle, and the first boot of a new
      # deployment is why. The database exists before the server has run its
      # migrations, so the very first attempt on a brand-new stack can fail on
      # a table that is about to be created — observed, not theorised. Waiting
      # a full interval to find that out would leave a fresh deployment red for
      # an hour over something that fixed itself in seconds.
      RETRY="$CHECK_SECONDS"
      [ "$RETRY" -gt 300 ] && RETRY=300
      echo "BACKUP RUN FAILED — the reason is in the lines above this one. This container stays up so the healthcheck keeps reporting the age of the newest archive; it will try again in ${RETRY}s." >&2
      tritrack-backup-freshness || :
      sleep "$RETRY"
      continue
    fi
  fi

  # The last thing each cycle prints is the finding, not the schedule's name —
  # `docker compose logs` is one of the two places a person ever sees this, and
  # a log tail that ends in "nothing to do" says less than one ending in an age.
  tritrack-backup-freshness || :

  sleep "$CHECK_SECONDS"
done
