#!/usr/bin/env bash
# gate-instrument: none - an operator command that restores a real backup; the gate exercises that path through backup_restore_drill.sh instead.
# Restore an encrypted database backup (task 10.24 / Security Model §4.9).
#
#   scripts/restore_db.sh <archive.age> <target-database> <path-to-identity>
#
# e.g.
#   scripts/restore_db.sh tritrack-20260809T211500Z.age tritrack_restored \
#     ~/.config/tritrack/backup-identity.txt
#
# The target database is created fresh. Restoring *over* the live database is
# possible but has to be spelled out — see server/backup/restore.sh.
#
# The archive's ORIGIN is checked before anything else (task 10.43 / §4.9.2),
# against TRITRACK_BACKUP_VERIFY_KEY from .env. An archive that predates
# signing still restores here, into its own new name, once you say so:
#
#   TRITRACK_RESTORE_UNSIGNED=I_ACCEPT_UNVERIFIED_ORIGIN scripts/restore_db.sh ...
#
# Nothing lets an archive of unverified origin take over an existing database
# name. That is finding H-6: a file written by anyone who can create one in
# the backup directory was accepted as the field record and executed as a
# Postgres superuser.
#
# The identity file is mounted read-only for the duration of this one command
# and is the only moment a backup private key is near the server host. If you
# are restoring on the server itself, remember that this is the machine §4.9
# assumes may already be compromised: prefer restoring on your own laptop
# against a scratch Postgres, which is what scripts/backup_restore_drill.sh
# does.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ $# -ne 3 ]; then
  echo "usage: scripts/restore_db.sh <archive.age> <target-database> <identity-file>" >&2
  exit 2
fi

ARCHIVE="$1"
TARGET="$2"
IDENTITY="$3"

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

if [ ! -f "$IDENTITY" ]; then
  echo "No identity file at ${IDENTITY}." >&2
  echo "That is the age private key from the custody arrangement in §4.9." >&2
  exit 1
fi

# A restore never signs anything, so it has no business mounting the signing
# key — and this is the command most likely to be run somewhere other than the
# backup host (§4.9 says to prefer a laptop). Cleared explicitly so a value in
# .env cannot carry the key onto a machine that only needs to read.
export TRITRACK_BACKUP_SIGNING_KEY=""

BACKUP_DIR="${TRITRACK_BACKUP_DIR:-./backups}"
if [ ! -f "${BACKUP_DIR}/${ARCHIVE}" ]; then
  echo "No such archive: ${BACKUP_DIR}/${ARCHIVE}" >&2
  exit 1
fi

# Verify the recorded checksum before spending time on a decrypt, so bitrot on
# whatever storage the archive travelled through is reported as bitrot rather
# than as a confusing age failure.
if [ -f "${BACKUP_DIR}/${ARCHIVE}.sha256" ]; then
  (cd "$BACKUP_DIR" && shasum -a 256 -c "${ARCHIVE}.sha256") \
    || { echo "Checksum mismatch — this archive is damaged." >&2; exit 1; }
fi

TRITRACK_RESTORE_ARCHIVE="$ARCHIVE" \
TRITRACK_RESTORE_TARGET_DB="$TARGET" \
TRITRACK_RESTORE_IDENTITY="$(cd "$(dirname "$IDENTITY")" && pwd)/$(basename "$IDENTITY")" \
  docker compose --profile backup run --rm backup tritrack-restore
