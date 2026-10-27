#!/usr/bin/env bash
# gate-instrument: none - an operator command that takes a real backup; the gate exercises that pipeline through backup_restore_drill.sh instead.
# Take an encrypted database backup (task 10.24 / Security Model §4.9).
#
#   scripts/backup_db.sh
#
# Thin wrapper: the pipeline itself lives in server/backup/backup.sh and runs
# inside the container, so plaintext never crosses the host. This file exists
# so the operational command is one word rather than a compose incantation
# someone gets wrong at 2am.
#
# Requires TRITRACK_BACKUP_RECIPIENTS in .env. Read server/README.md's
# "Database backups (§4.9)" section first — the key custody arrangement is the
# part of this that cannot be fixed after the fact.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# `.env` is loaded in exactly one place — see that file for why (task
# 11.40 / 11.52). This used to be an eight-line block copied into seven
# scripts.
. scripts/lib/load_env.sh

# The user the backup container runs as (task 11.70). Sourced rather than
# computed here, because scripts/restore_db.sh needs the identical answer and
# a second copy of two lines is how the two drift. Without it the container is
# the image's own uid 70, and on a Linux server that user can neither create
# the archive in the operator's backups/ directory nor read the mode-600
# signing key — which used to surface as "pg_dump | age pipeline failed".
# shellcheck disable=SC1091
. scripts/lib/backup_user.sh

BACKUP_DIR="${TRITRACK_BACKUP_DIR:-./backups}"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

# The signing key (task 10.43 / §4.9.2) is bind-mounted, so it has to be an
# absolute path by the time compose sees it — a relative or `~`-prefixed value
# in .env would otherwise mount a *directory Docker creates for you*, and the
# container would report "no signing key" while the operator is looking at the
# line in .env that sets one.
if [ -n "${TRITRACK_BACKUP_SIGNING_KEY:-}" ]; then
  EXPANDED="${TRITRACK_BACKUP_SIGNING_KEY/#\~/$HOME}"
  if [ ! -f "$EXPANDED" ]; then
    echo "TRITRACK_BACKUP_SIGNING_KEY is set to '${TRITRACK_BACKUP_SIGNING_KEY}'," >&2
    echo "but there is no file there. Refusing to take a backup that would be" >&2
    echo "silently unsigned while .env says otherwise — see §4.9.2." >&2
    exit 1
  fi
  TRITRACK_BACKUP_SIGNING_KEY="$(cd "$(dirname "$EXPANDED")" && pwd)/$(basename "$EXPANDED")"
  export TRITRACK_BACKUP_SIGNING_KEY
fi

docker compose --profile backup run --rm backup tritrack-backup

echo
echo "Archives in ${BACKUP_DIR}:"
ls -1t "$BACKUP_DIR"/tritrack-*.age 2>/dev/null | sed -n 1,5p || echo "  (none)"
echo
echo "Reminder (§4.9): copy these off this machine, and run"
echo "scripts/backup_restore_drill.sh on the documented cadence. An archive"
echo "nobody has restored from is not a backup."
