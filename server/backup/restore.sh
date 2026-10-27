#!/bin/sh
# Restore an encrypted backup (task 10.24 / Security Model §4.9, rebuilt by
# task 10.37 after finding G-3).
#
# The half that is usually skipped. §4.9: "a backup that has never been
# restored is not a backup" — so this is a first-class script with a drill
# (scripts/backup_restore_drill.sh) that runs it end to end, including the
# in-place replace path, not a paragraph of instructions in a README.
#
# Decrypts straight into psql, so the plaintext dump never lands on disk here
# either — the machine performing a restore is usually the *least* controlled
# one in the story (a laptop, in a hurry, during an incident).
#
# THE ORIGIN INVARIANT (task 10.43 / finding H-6). Everything below asks two
# different questions and they must not be confused, because for three tasks
# they were:
#
#   INTEGRITY — are these the bytes somebody encrypted? `age` answers this,
#     per STREAM chunk, and answers it well.
#   ORIGIN    — was that somebody US? `age` cannot answer this at all. It has
#     no signing mode, and its recipient strings are PUBLIC: §4.9.1 says they
#     may appear "in documentation, tickets, or a commit".
#
# H-6 reproduced the gap live. An attacker holding nothing but the public
# recipient wrote an archive that matched its checksum, declared a supported
# schema major, decrypted cleanly under the operator's own private key, and had
# its SQL piped into psql as the POSTGRES_USER the postgres image creates as a
# SUPERUSER — then was renamed into the live database name. All three gates
# passed because the attacker authored all three inputs.
#
# So origin is now established by a signature (`minisign`, Ed25519) made on the
# machine that took the backup with a key the archive directory never sees, and
# the verifying public key is configured HERE, with the restore procedure —
# never read from beside the archive, because an archive directory that
# supplies its own verifying key verifies nothing. §4.9.2 is the custody
# arrangement.
#
# An archive whose origin cannot be established is not refused outright — every
# archive written before task 10.43 is one, and refusing them would strand the
# history. It is refused from the ONE operation where origin is what matters:
# an unverified archive is never promoted over an existing database. Restore it
# into a name of its own, look at it, and repoint the server by hand.
#
# THE ORDERING INVARIANT (task 10.37 / finding G-3). Nothing that can destroy
# data happens until the archive has been decrypted end to end, restored into a
# database of its own, and found to hold something. Until then this script has
# only ever created. Concretely:
#
#   verify signature -> verify checksum -> verify schema marker ->
#   decrypt the WHOLE stream -> restore into <target>_restore_<stamp> ->
#   only then swap names
#
# and the swap *renames* the live database aside rather than dropping it, so
# even a restore that decrypts perfectly and turns out to hold the wrong season
# is recoverable. G-3 was the previous ordering — DROP, CREATE, then decrypt —
# reproduced live against a database holding the only copy of an observation.
# A restore is the one operation whose failure mode must not be worse than
# doing nothing at all.
#
# Reads from the environment:
#   TRITRACK_RESTORE_ARCHIVE   filename under /backups (e.g. tritrack-....age)
#   TRITRACK_RESTORE_TARGET_DB database to restore into
#   TRITRACK_RESTORE_REPLACE   set to I_UNDERSTAND to take over an existing name
#   TRITRACK_BACKUP_VERIFY_KEY minisign PUBLIC key line(s), comma/space
#                              separated — the signing keys this operator
#                              trusts. More than one so a signing-key rotation
#                              does not strand the archives written before it.
#   TRITRACK_RESTORE_UNSIGNED  set to I_ACCEPT_UNVERIFIED_ORIGIN to restore an
#                              archive whose origin cannot be established. Only
#                              ever into a NEW database name; see below.
#   TRITRACK_RESTORE_FAULT     drill-only fault injection, see the SWAP section
#   POSTGRES_*                 connection to the server (as the admin user)
#
# Requires the private key mounted read-only at /identity/key.txt. That mount
# exists for the duration of one command and is the only moment a TriTrack
# backup key is ever near the server host — see §4.9 on why it does not live
# there.
set -eu
set -o pipefail

fail() {
  echo "RESTORE FAILED — $1" >&2
  exit 1
}

: "${POSTGRES_HOST:?POSTGRES_HOST is not set}"
: "${POSTGRES_USER:?POSTGRES_USER is not set}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is not set}"
: "${TRITRACK_RESTORE_ARCHIVE:?TRITRACK_RESTORE_ARCHIVE is not set}"
: "${TRITRACK_RESTORE_TARGET_DB:?TRITRACK_RESTORE_TARGET_DB is not set}"
PORT="${POSTGRES_PORT:-5432}"
ARCHIVE="/backups/${TRITRACK_RESTORE_ARCHIVE}"
TARGET="$TRITRACK_RESTORE_TARGET_DB"

[ -f "$ARCHIVE" ] || fail "no such archive: $ARCHIVE"
[ -f /identity/key.txt ] || fail "no private key mounted at /identity/key.txt"

# Task 11.70, the restore half of the same fact. Both of these paths are bind
# mounts of files the operator owns — the archive directory, and an age private
# key that §4.9 says lives on their laptop and is mode 600 there. On Linux a
# bind mount passes ownership through, so a container running as anyone else
# finds both files and can open neither. Said here, in a sentence, rather than
# later as an `age` failure to decrypt, which is what a restore under time
# pressure would read as a corrupt archive.
. /usr/local/lib/tritrack-permissions.sh
[ -r "$ARCHIVE" ] || fail "the archive $ARCHIVE exists but this container cannot read it.$(tritrack_ownership_note "$ARCHIVE")"
[ -r /identity/key.txt ] || fail "the private key at /identity/key.txt is mounted but this container cannot read it.$(tritrack_ownership_note /identity/key.txt)"

# Every database name below is interpolated into SQL. They are operator-typed
# rather than attacker-supplied, but this script also *derives* two more names
# from this one, and a name that needs quoting would break those silently.
case "$TARGET" in
  ''|*[!A-Za-z0-9_]*)
    fail "target database name '$TARGET' must be letters, digits and underscores only" ;;
esac

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
STAGING="${TARGET}_restore_${STAMP}"
DISPLACED="${TARGET}_replaced_${STAMP}"
# Postgres truncates identifiers at 63 bytes, which would silently collide two
# derived names into one. Refuse instead.
if [ "${#DISPLACED}" -gt 63 ] || [ "${#STAGING}" -gt 63 ]; then
  fail "target name '$TARGET' is too long: this restore derives '$STAGING' and
  '$DISPLACED', and Postgres truncates identifiers at 63 characters. Use a
  shorter target name."
fi

# ===========================================================================
# PRE-FLIGHT. Everything below this line either reads, or creates something
# new under a name nobody is using. Nothing is destroyed or renamed until the
# "SWAP" section at the bottom, and that section is only reached if all of
# this passed.
#
# "a name nobody is using" is ENFORCED as of task 10.43, not merely intended —
# see the pg_database check in front of CREATE DATABASE below. It was an
# assertion in this comment and nothing else for two tasks (finding H-9), and
# a comment that describes a property no code checks is the shape this whole
# section exists to avoid.
# ===========================================================================

# --- ORIGIN: who wrote this archive (task 10.43 / finding H-6) --------------
#
# This runs first because it is the only check here that an attacker cannot
# author. The checksum and the schema marker below are plain files sitting in
# the same directory as the archive; whoever can write one can write all three.
# The signature is made with a key that is not in that directory and is not
# derivable from the public recipient string §4.9.1 publishes.
#
# Precisely what it does and does not defend, because getting this wrong in a
# comment is the whole of H-6: it separates the backup job from everyone else
# who can create a file in /backups — the off-site copy, the cloud drive, the
# sync target, the incident-time "fetch another copy". It does NOT defend a
# compromised backup host, which holds the signing key and also the live
# database it would be signing dumps of. See §4.9.2's blast-radius table.
#
# The verifying key comes from the environment — from the restore procedure —
# and never from beside the archive. That is the whole point: a directory that
# ships its own verifying key proves only that it is internally consistent,
# which the forged archive in H-6 also was.
SIG_FILE="${ARCHIVE}.minisig"
VERIFY_KEYS="$(printf '%s' "${TRITRACK_BACKUP_VERIFY_KEY:-}" | tr ',' ' ')"
SIGNED=0
SIGNED_COMMENT=""
if [ -n "$(printf '%s' "$VERIFY_KEYS" | tr -d '[:space:]')" ] && [ -f "$SIG_FILE" ]; then
  for k in $VERIFY_KEYS; do
    if SIGNED_COMMENT="$(minisign -V -Q -P "$k" -m "$ARCHIVE" -x "$SIG_FILE" 2>/dev/null)"; then
      SIGNED=1
      break
    fi
  done
  if [ "$SIGNED" != "1" ]; then
    # Never overridable, on any path, for any target. A missing signature is a
    # legacy archive; a signature that does not verify is a file that claims an
    # origin it does not have, or one that has been altered since it was
    # signed. Neither has a benign reading, and there is no flag for it.
    #
    # Which of the two it is matters enormously to whoever is reading this at
    # 3am, and the recorded checksum can tell them: it was written by the same
    # party as the signature, so if the archive fails BOTH, the file changed
    # after it left the backup job (damage), whereas an archive that matches
    # its recorded checksum and fails the signature is internally consistent
    # and simply not ours (forgery).
    if [ -f "${ARCHIVE}.sha256" ] \
       && ! (cd /backups && sha256sum -c "$(basename "${ARCHIVE}.sha256")" >/dev/null 2>&1); then
      fail "this archive matches neither its recorded checksum nor its signature,
  so the file itself changed after it was written — damage in transit, not a
  forgery. Fetch another copy. Nothing has been changed."
    fi
    fail "the signature beside this archive does NOT verify against any key in
  TRITRACK_BACKUP_VERIFY_KEY. Nothing has been changed.

  This is not a damaged archive: it is consistent with its own sidecars.
  Either it was altered after signing, or it was signed by a key you do not
  trust — which is exactly what someone who can write into the archive
  directory but cannot read an archive produces (§4.9.2, finding H-6).

  Do not 'fetch another copy from the same place'. Get an archive from
  somewhere the party who can write that directory cannot reach, and find
  out who can write it."
  fi
  echo "Origin: signature verifies against a trusted TriTrack backup key."
fi

if [ "$SIGNED" != "1" ]; then
  # Two different ways to arrive here, and an operator mid-incident needs to
  # know which one they are in.
  if [ -f "$SIG_FILE" ]; then
    echo "NOTE: $SIG_FILE exists but TRITRACK_BACKUP_VERIFY_KEY is not set," >&2
    echo "      so this archive's origin was NOT checked. The key that would" >&2
    echo "      check it is public — it belongs in .env next to the restore" >&2
    echo "      procedure (§4.9.2). Find it before trusting this archive." >&2
  else
    echo "NOTE: no $SIG_FILE — this archive's origin cannot be established." >&2
    echo "      Archives written before task 10.43 are all like this." >&2
  fi

  # THE refusal. An archive nobody can attribute is still restorable — into a
  # database of its own, where an operator can look at it before believing it.
  # What it is never allowed to do is take over the name the server reads,
  # which is H-6 end to end. That step costs one ALTER DATABASE by hand and it
  # is the difference between "a strange archive is sitting in a database" and
  # "the field record is now whatever an attacker wrote".
  if [ "${TRITRACK_RESTORE_REPLACE:-}" = "I_UNDERSTAND" ]; then
    fail "refusing to restore an archive of unverified origin OVER an existing
  database. Nothing has been changed.

  TRITRACK_RESTORE_REPLACE says you accept losing what is in '$TARGET'.
  It does not say you have established that this archive came from your own
  backup job, and no combination of flags will: encryption proves the bytes
  were not altered, never who wrote them (Security Model §4.9.2, H-6).

  Do this instead — it is the same recovery, one step longer:
    1. restore into a NEW name with TRITRACK_RESTORE_UNSIGNED=I_ACCEPT_UNVERIFIED_ORIGIN
    2. look at it: row counts, and the most recent observations you know
       should be there
    3. repoint the server, or rename it into place yourself

  If this archive should have been signed, that is the finding, not an
  obstacle: something wrote a file into your archive directory."
  fi

  if [ "${TRITRACK_RESTORE_UNSIGNED:-}" != "I_ACCEPT_UNVERIFIED_ORIGIN" ]; then
    fail "this archive's origin cannot be verified, and restoring one is a
  deliberate act. Nothing has been changed.

  Set TRITRACK_BACKUP_VERIFY_KEY to the minisign public key your backup job
  signs with (§4.9.2) — that is the answer for any archive taken after task
  10.43.

  For an older archive, or one you have established the provenance of by
  other means, set TRITRACK_RESTORE_UNSIGNED=I_ACCEPT_UNVERIFIED_ORIGIN.
  That restores into a new database name only; it will not replace one."
  fi
  echo "Proceeding with an archive of UNVERIFIED origin, into a new name only."
fi

# --- Recorded checksum (task 10.37, corrected by task 10.43) ----------------
#
# backup.sh has always written a .sha256 beside each archive, and until task
# 10.37 the only thing that checked it was scripts/restore_db.sh — the wrapper
# that *cannot* perform an in-place replace, because it never sets
# TRITRACK_RESTORE_REPLACE. So the single path capable of destroying live data
# was the single path with no integrity check on the archive it was trusting,
# and server/README.md credited the check anyway. That is how G-3's truncated
# archive reached a DROP DATABASE. The check belongs here, on the path that
# can do damage, not only on the one that cannot.
#
# WHAT THIS CHECK IS FOR, stated correctly (task 10.43). It detects ACCIDENTS:
# a copy that rotted on a USB stick, a transfer that ended early. It is not an
# authenticity check and never was — this file is authored by whoever can write
# the archive directory, so against an adversary it says exactly nothing. The
# comment that used to sit here said a missing checksum was fine because "the
# decrypt below authenticates the bytes regardless", which is true of the bytes
# and false of the archive: `age` proves nothing was altered AFTER encryption
# and is silent on who encrypted it. That sentence is H-6, written down as a
# reassurance, and it survived three tasks reading this file.
#
# So: a missing checksum stays a note rather than a refusal, because archives
# do get copied and renamed by hand during an incident and this check was never
# the thing standing between an operator and a forgery. The signature above is.
#
# When the archive IS signed, the checksum recorded in the signed trusted
# comment is the authoritative one, and the sidecar is compared against it —
# a sidecar that disagrees with a valid signature is not bitrot, it is somebody
# writing files into the archive directory, and it is reported as such.
CHECKSUM_FILE="${ARCHIVE}.sha256"
SIGNED_SHA=""
if [ "$SIGNED" = "1" ]; then
  SIGNED_SHA="$(printf '%s' "$SIGNED_COMMENT" | sed -n 's/.*[[:space:]]sha256=\([0-9a-f]*\).*/\1/p')"
  SIGNED_NAME="$(printf '%s' "$SIGNED_COMMENT" | sed -n 's/.*[[:space:]]archive=\([^[:space:]]*\).*/\1/p')"
  # A renamed copy is legitimate — restore.sh's own error text tells operators
  # to fetch another copy, and copies get renamed. The bytes are what the
  # signature covers, so the name is a note and not a gate.
  if [ -n "$SIGNED_NAME" ] && [ "$SIGNED_NAME" != "$(basename "$ARCHIVE")" ]; then
    echo "NOTE: this archive was signed under the name '$SIGNED_NAME'." >&2
    echo "      The signature covers the contents, so a renamed copy is fine." >&2
  fi
fi
if [ -f "$CHECKSUM_FILE" ]; then
  if ! (cd /backups && sha256sum -c "$(basename "$CHECKSUM_FILE")" >/dev/null 2>&1); then
    if [ "$SIGNED" = "1" ]; then
      fail "checksum mismatch, and it is the SIDECAR that is wrong. The signature
  over $ARCHIVE verifies, so the archive is provably the one the backup job
  wrote — but the .sha256 beside it describes some other file. That is not
  damage in transit; that is a file in the archive directory written by
  something other than the backup job. Find out what can write there.
  Nothing has been changed."
    fi
    fail "checksum mismatch: $ARCHIVE does not match the .sha256 recorded when
  it was written. The archive was damaged or altered in transit — fetch
  another copy rather than restoring this one. Nothing has been changed."
  fi
  if [ "$SIGNED" = "1" ] && [ -n "$SIGNED_SHA" ]; then
    SIDECAR_SHA="$(sed 's/ .*//' "$CHECKSUM_FILE")"
    if [ "$SIDECAR_SHA" != "$SIGNED_SHA" ]; then
      fail "the .sha256 sidecar disagrees with the checksum inside the signature.
  Both cannot describe this archive. Nothing has been changed."
    fi
  fi
  echo "Checksum: matches the value recorded at backup time."
else
  echo "NOTE: $CHECKSUM_FILE not found — skipping the checksum check." >&2
  if [ "$SIGNED" = "1" ]; then
    echo "      The signature above already covers every byte of the archive." >&2
  else
    echo "      Nothing here has checked this archive against a recorded value." >&2
  fi
fi

# --- Schema-version marker (task 10.36) -------------------------------------
#
# Read the cleartext sidecar written by backup.sh, without touching the key or
# the ciphertext, so an operator can see what an archive holds before
# committing to a restore. Archives from before this task carry no sidecar —
# that means "the last major before this task" (schema major 1), not
# "unknown, refuse", or every pre-existing backup would be stranded.
#
# The supported range mirrors the client's asymmetric rule (lib/data/sync/
# schema_migrator.dart's `_lowestMigratableMajor`, currently 1) up through this
# build's `schemaMajorVersion` (packages/tritrack_sync/lib/src/
# schema_constants.dart). **SCHEMA_MAX is checked against that constant** by
# `server/test/security/shipped_defaults_test.dart`, because it was still 2 a
# week after major 3 shipped (task 11.242 found it); update it in the same
# commit as the constant, and the test will hold you to it.
#
# Task 10.43: when the archive is signed, the major recorded in the SIGNED
# trusted comment is the one that counts. The sidecar stays for the operator to
# read without any tooling, but H-6's attacker wrote `schema_major=2` into one
# and it was believed, so it is no longer what the script decides on.
SCHEMA_MIN=1
SCHEMA_MAX=6
SCHEMA_FILE="${ARCHIVE}.schema"
SIGNED_MAJOR=""
if [ "$SIGNED" = "1" ]; then
  SIGNED_MAJOR="$(printf '%s' "$SIGNED_COMMENT" | sed -n 's/.*[[:space:]]schema_major=\([0-9]*\).*/\1/p')"
fi
if [ -n "$SIGNED_MAJOR" ]; then
  ARCHIVE_MAJOR="$SIGNED_MAJOR"
  if [ -f "$SCHEMA_FILE" ]; then
    SIDECAR_MAJOR="$(sed -n 's/^schema_major=//p' "$SCHEMA_FILE" | sed -n 1p)"
    if [ "$SIDECAR_MAJOR" != "$ARCHIVE_MAJOR" ]; then
      fail "the .schema sidecar says major '$SIDECAR_MAJOR' and the signature
  says major '$ARCHIVE_MAJOR'. The signature is the one that came from the
  backup job, so the sidecar has been rewritten. Treat the archive directory
  as untrusted. Nothing has been changed."
    fi
  fi
elif [ -f "$SCHEMA_FILE" ]; then
  ARCHIVE_MAJOR="$(sed -n 's/^schema_major=//p' "$SCHEMA_FILE" | sed -n 1p)"
else
  ARCHIVE_MAJOR=1
  echo "NOTE: $SCHEMA_FILE not found — treating archive as schema major 1" \
    "(the last major before task 10.36)." >&2
fi
case "$ARCHIVE_MAJOR" in
  ''|*[!0-9]*) fail "$SCHEMA_FILE has an unreadable schema_major value" ;;
esac
if [ "$ARCHIVE_MAJOR" -lt "$SCHEMA_MIN" ] || [ "$ARCHIVE_MAJOR" -gt "$SCHEMA_MAX" ]; then
  fail "archive is schema major $ARCHIVE_MAJOR; this build supports major \
$SCHEMA_MIN through $SCHEMA_MAX. Restore it with a build that supports major \
$ARCHIVE_MAJOR, or upgrade this one."
fi
echo "Archive schema major: $ARCHIVE_MAJOR (this build supports $SCHEMA_MIN through $SCHEMA_MAX)"

# The default restore target is a NEW database, never the live one. A restore
# is performed under time pressure by definition, and "restore over production"
# as a one-flag default is how a good backup turns into the outage. Recovering
# in place is available, but it has to be typed out.
if [ "$TARGET" = "${POSTGRES_DB:-}" ] && [ "${TRITRACK_RESTORE_REPLACE:-}" != "I_UNDERSTAND" ]; then
  fail "target '$TARGET' is the live database.
  Restore into a new database and repoint the server, or set
  TRITRACK_RESTORE_REPLACE=I_UNDERSTAND to take over the name in place."
fi

export PGPASSWORD="$POSTGRES_PASSWORD"
psql_admin() {
  psql --host="$POSTGRES_HOST" --port="$PORT" --username="$POSTGRES_USER" \
    --dbname=postgres --quiet --no-psqlrc -v ON_ERROR_STOP=1 "$@"
}

TARGET_EXISTS=0
if psql_admin -tAc "SELECT 1 FROM pg_database WHERE datname = '$TARGET'" | grep 1 >/dev/null; then
  TARGET_EXISTS=1
  if [ "${TRITRACK_RESTORE_REPLACE:-}" != "I_UNDERSTAND" ]; then
    fail "database '$TARGET' already exists.
  Pick an unused name, or set TRITRACK_RESTORE_REPLACE=I_UNDERSTAND to take
  over the name (the existing database is renamed aside, not dropped)."
  fi
  # The swap renames the live database aside, and Postgres refuses to rename a
  # database anything is connected to. Say so now, before spending a full
  # decrypt and restore on something that cannot land — rather than after.
  # Note this is a courtesy check, not the control: a connection opened after
  # it still only makes the rename fail, which destroys nothing.
  SESSIONS="$(psql_admin -tAc \
    "SELECT count(*) FROM pg_stat_activity WHERE datname = '$TARGET'" | tr -d '[:space:]')"
  if [ "${SESSIONS:-0}" -gt 0 ]; then
    fail "'$TARGET' has ${SESSIONS} open connection(s), and taking over the name
  requires renaming it. Stop the server first, then run this again. Nothing
  has been changed."
  fi
fi

# --- The decrypt, verified in full, before anything is touched --------------
#
# This is finding G-3's fix. `age` authenticates per STREAM chunk, so reading
# the stream to its end is the only thing that establishes the archive is
# whole: a truncated file has a valid header and a valid prefix and fails
# partway, which is exactly what happened at the gate — after the live
# database had already been dropped.
#
# Two passes over the ciphertext, deliberately. The alternative is to decrypt
# once to a temp file and restore from that, and §4.9's "plaintext never lands
# on disk, not even in a temp directory" forbids it. Decryption is ChaCha20
# over a compressed dump; the cost of the second pass is seconds, and it buys
# the difference between a refused restore and a destroyed database.
#
# The two markers are pg_dump's own. `complete` is the last thing it writes, so
# requiring it proves the plaintext reached its end — an end-to-end truncation
# check that does not depend on age's framing.
#
# WHAT THE HEADER MARKER PROVES, stated correctly (task 10.43). It used to say
# here that the header "proves this is a database dump at all, and not some
# other file that happens to be encrypted to the same key". Against an accident
# — a photo, a tarball, the wrong file entirely — that is true. Against an
# adversary it is worthless: the marker is two literal comment lines, and
# H-6's forgery was a hand-written file that opened with the first and closed
# with the second, with arbitrary superuser SQL in between. `age` proves this
# decrypts under the mounted key; anyone holding the PUBLIC half can make that
# true. Nothing in this decrypt establishes authorship. The signature at the
# top of this script is the check that does, and it is why that one refuses
# rather than notes.
#
# Both markers are kept because they are still the right shape for the failure
# they were written for — an incomplete or wrong-file restore — and because a
# check being useless against an adversary is not a reason to drop it, only a
# reason to stop describing it as one.
echo "Verifying the archive decrypts and is a complete dump (nothing changed yet)..."
if ! age --decrypt -i /identity/key.txt "$ARCHIVE" | awk '
    /^-- PostgreSQL database dump$/          { header = 1 }
    /^-- PostgreSQL database dump complete$/ { complete = 1 }
    END { exit (header && complete) ? 0 : 1 }
  '; then
  fail "this archive did not decrypt to a complete database dump, so nothing
  was changed — '$TARGET' is exactly as it was.

  If age reported 'no identity matched', the archive was encrypted to
  recipients that do not include the mounted key; recipients cannot be added
  to an archive after it is written (§4.9).

  If age reported a failure to authenticate a payload chunk, the file is
  truncated or altered — fetch another copy.

  If age said nothing, the archive decrypted but is not a pg_dump, or is a
  dump that was cut short before pg_dump finished writing it."
fi
echo "Verified: decrypts with the mounted key, and the dump is complete."

# ===========================================================================
# RESTORE. Into a database of its own, under a name nothing is using. Still
# nothing destructive: if any of this fails, the staging database is dropped
# and '$TARGET' has not been touched.
# ===========================================================================

# --- The one drop this script issues, and the guard it was missing ----------
#
# Finding H-9 (task 10.43). The pre-flight banner above asserts that this
# script "either reads, or creates something new under a name nobody is using",
# and the staging database was the one place that was not enforced: '$TARGET'
# gets a pg_database lookup and a TRITRACK_RESTORE_REPLACE gate, '$STAGING' got
# neither, while the EXIT trap dropped it with output suppressed. Reaching that
# needs a name collision to the second — two concurrent restores of the same
# target, or a clock stepped back over a leftover — so it is unlikely rather
# than unreachable, and "unlikely" is not what :79-82 claims.
#
# One SELECT makes the claim true. Note the ORDER of the three statements
# below: check, then create, then arm the trap. Arming it before the CREATE
# (as it was) means a CREATE that fails because the name is taken runs a trap
# that drops the database it collided with — the failure path deleting the
# thing it tripped over.
if psql_admin -tAc "SELECT 1 FROM pg_database WHERE datname = '$STAGING'" | grep 1 >/dev/null; then
  fail "the staging name '$STAGING' is already taken, so this restore would be
  building on top of a database it did not create. Nothing has been changed,
  and nothing has been dropped.

  That name is '<target>_restore_<UTC second>', so this means either another
  restore of '$TARGET' is running right now, or a previous one was
  interrupted and left it behind. Check which, then either wait or drop it
  by hand:  DROP DATABASE \"$STAGING\";"
fi

echo "Restoring into '$STAGING'..."
psql_admin -c "CREATE DATABASE \"$STAGING\""

# Armed only now, once this run is the thing that created '$STAGING'.
#
# INT and TERM are trapped too (H-9). Only EXIT was, so a Ctrl-C left a staging
# database behind under a name a later run would then refuse — and the drop
# below is safe precisely because of the check above, which is what makes
# trapping the interactive signals the right call rather than a risk.
drop_staging() {
  psql_admin -c "DROP DATABASE IF EXISTS \"$STAGING\"" >/dev/null 2>&1 || true
}
trap drop_staging EXIT
trap 'drop_staging; exit 130' INT
trap 'drop_staging; exit 143' TERM

# --- A restricted role for the one connection that runs the archive's own SQL
# (task 10.59, finding I-10) --------------------------------------------------
#
# Everything above this point runs SQL this script wrote. From here down, the
# next statement executed is the CONTENTS OF THE ARCHIVE — and until now that
# ran as $POSTGRES_USER, which the official postgres image makes a superuser.
# 10.43's origin check means an unattributable archive can only ever land in a
# fresh, disposable '$STAGING' rather than replacing '$TARGET' — real
# containment — but it does not bound what the archive's SQL may DO on the way
# in. A superuser connection can `COPY ... FROM PROGRAM`, which is arbitrary
# command execution on this container, reachable by anyone who can get an
# operator to accept an archive via TRITRACK_RESTORE_UNSIGNED. Bounded today
# only by that override's loud name; this closes it structurally instead.
#
# `SET ROLE`, not a second login. A separate role with its own password would
# need its own authentication path (a new pg_hba entry, a credential to
# manage) for no benefit: this connection is already authenticated as
# $POSTGRES_USER, and Postgres lets a superuser `SET ROLE` to any role at all,
# no prior GRANT required — only a non-superuser needs to already be a member.
# One statement, prepended to the same stream, demotes every statement after
# it in this same transaction to whatever '$RESTORE_ROLE' can do — which,
# below, is exactly "create objects in this one disposable database and
# nothing else." NOSUPERUSER alone is what actually removes `COPY ... FROM
# PROGRAM`: that capability checks for the superuser attribute (or explicit
# membership in pg_read/write_server_files, granted to nobody here), not for
# any privilege a GRANT could hand back.
#
# NOLOGIN, and created once rather than per-restore: it is a privilege label,
# never a credential, so there is nothing to rotate and nothing gained by a
# fresh one each run. It persists across restores on purpose — the schema
# grant below is per-'$STAGING', so a stale role carries no access into a
# later restore's database.
RESTORE_ROLE=tritrack_restore
# Task 10.78 (finding K-9): this was check-then-create (SELECT from
# pg_roles, then CREATE ROLE if absent) — the same pre-existing instance of
# the race task 10.69 replaced in ensureServerAppRole (postgres_database.dart)
# with an unconditional CREATE ROLE that swallows only "someone else already
# created it." See backup.sh's identical fix for the full reasoning; this
# role is created once and persists across restores, but nothing stops two
# restores (or a restore racing this backup image's own role bootstrap)
# reaching this line at the same time on a fresh database.
if ! CREATE_RESTORE_ROLE_ERR=$(psql_admin -c "CREATE ROLE \"$RESTORE_ROLE\" \
    NOSUPERUSER NOCREATEDB NOCREATEROLE NOLOGIN NOREPLICATION NOBYPASSRLS" 2>&1); then
  case "$CREATE_RESTORE_ROLE_ERR" in
    *"already exists"*|*"duplicate key value violates unique constraint"*) ;;
    *) fail "creating role \"$RESTORE_ROLE\" failed:
$CREATE_RESTORE_ROLE_ERR" ;;
  esac
fi
# CREATE on the public schema, and nothing else — the archive was written by
# `pg_dump --no-owner --no-privileges` (backup.sh), so its DDL never assumes
# ownership of anything and this is the one grant replaying it needs. Scoped
# to '$STAGING' alone: schema-level grants are per-database, so this never
# reaches '$TARGET' or any other database on this server.
psql --host="$POSTGRES_HOST" --port="$PORT" --username="$POSTGRES_USER" \
  --dbname="$STAGING" --quiet --no-psqlrc -v ON_ERROR_STOP=1 \
  -c "GRANT ALL ON SCHEMA public TO \"$RESTORE_ROLE\""

# --single-transaction is the other half of G-3's fix. Without it a decrypt
# that aborts mid-stream leaves every statement before the abort committed —
# a database that exists, answers queries, and is missing rows, which is the
# outcome ON_ERROR_STOP's comment used to claim was prevented. ON_ERROR_STOP
# covers SQL errors; it has nothing to say about the pipe upstream of it
# closing early. With this flag the restore is all or nothing.
#
# `SET ROLE` is transaction-scoped like everything else piped in here, so it
# does not need to be undone — the connection closes at the end of this one
# statement.
#
# stdout goes to /dev/null: a dump replays thousands of statements and their
# result rows bury anything worth reading. Errors are on stderr.
if ! { echo "SET ROLE \"$RESTORE_ROLE\";"; age --decrypt -i /identity/key.txt "$ARCHIVE"; } \
    | psql --host="$POSTGRES_HOST" --port="$PORT" --username="$POSTGRES_USER" \
        --dbname="$STAGING" --quiet --no-psqlrc --single-transaction \
        -v ON_ERROR_STOP=1 >/dev/null; then
  fail "the restore into '$STAGING' failed. '$TARGET' has not been touched.
  The staging database was rolled back and dropped."
fi

TABLES="$(psql --host="$POSTGRES_HOST" --port="$PORT" --username="$POSTGRES_USER" \
  --dbname="$STAGING" --quiet --no-psqlrc -tA -v ON_ERROR_STOP=1 \
  -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'" \
  | tr -d '[:space:]')"
if [ "${TABLES:-0}" -lt 1 ]; then
  fail "the restore produced no tables in '$STAGING', so it is not being
  promoted. '$TARGET' has not been touched."
fi

# A restored database is not the database the devices last synced against,
# and it must not say it is (task 11.58). server_database_identity is how the
# server tells a device which database answered; a device whose bookmark was
# minted against a different one starts its sync over from the beginning
# instead of asking "anything after 4,812?" of a database whose numbering now
# stops lower, and being told "nothing". backup.sh already leaves the row out
# of every archive it writes; this empties it for one taken any other way, so
# the server mints a fresh identifier on its next start. Guarded, because an
# archive written before the table existed does not have it at all.
if ! psql --host="$POSTGRES_HOST" --port="$PORT" --username="$POSTGRES_USER" \
    --dbname="$STAGING" --quiet --no-psqlrc -v ON_ERROR_STOP=1 \
    -c 'DO $$ BEGIN IF to_regclass($q$public.server_database_identity$q$) IS NOT NULL THEN DELETE FROM server_database_identity; END IF; END $$' \
    >/dev/null; then
  fail "could not clear the database identifier in '$STAGING', so it is not
  being promoted. '$TARGET' has not been touched."
fi

# ===========================================================================
# SWAP. The first and only destructive-looking step, and it still destroys
# nothing: the existing database is renamed aside and left on disk for the
# operator to drop once they have confirmed the restore holds what they
# expect. "Verify, then swap" — never swap, then hope.
# ===========================================================================

# DISARMED HERE, not after the swap (finding H-9, task 10.43). '$STAGING' now
# holds a fully decrypted, fully verified restore — at this point it is the
# most valuable database on the server, and from here on every way this script
# can fail is a way an operator needs it to still exist.
#
# The trap used to stay armed across the whole swap. In the worst case — the
# rename-aside succeeds, the promote fails, and the rollback fails too —
# `fail` printed the correct manual instructions naming '$DISPLACED' and then
# the trap silently dropped the verified restore on the way out. Ctrl-C in the
# same window did the same thing. Every message below therefore names both
# databases the operator has left, because after this line nothing cleans up
# and that is the point.
trap - EXIT INT TERM

# Fault injection, drill-only (task 10.43 / finding H-9). The rollback below is
# the code that protects against the paragraph above, and until this existed it
# had NEVER RUN: the drill's four destructive cases were a bad checksum, a
# truncation, a wrong key and a success, and not one of them can make a rename
# fail. Untested recovery code is indistinguishable from absent recovery code,
# which is finding G-3's own lesson one layer down.
#
# This can only make a rename fail. It cannot make this script destroy
# anything, skip a check, or promote something it otherwise would not — and
# anyone able to set it on the restore container is already running the
# restore. scripts/backup_restore_drill.sh is the only caller.
rename_db() { # <from> <to>
  case "${TRITRACK_RESTORE_FAULT:-}" in
    promote|promote_and_rollback)
      if [ "$1" = "$STAGING" ]; then
        echo "FAULT INJECTION: failing the promote of '$STAGING' on purpose." >&2
        return 1
      fi ;;
  esac
  if [ "${TRITRACK_RESTORE_FAULT:-}" = "promote_and_rollback" ] && [ "$1" = "$DISPLACED" ]; then
    echo "FAULT INJECTION: failing the rollback of '$DISPLACED' on purpose." >&2
    return 1
  fi
  psql_admin -c "ALTER DATABASE \"$1\" RENAME TO \"$2\""
}

if [ "$TARGET_EXISTS" = "1" ]; then
  echo "Renaming the existing '$TARGET' aside to '$DISPLACED' (not dropping it)..."
  if ! rename_db "$TARGET" "$DISPLACED"; then
    fail "could not rename '$TARGET' aside, so nothing was swapped and it is
  exactly as it was. The verified restore is kept as '$STAGING' — it is NOT
  dropped, and nothing will drop it for you:
      DROP DATABASE \"$STAGING\";   -- only once you no longer want it"
  fi
  # If promoting the restore now fails, the operator is left with no '$TARGET'
  # at all, which is worse than where they started. Put it back and say so.
  if ! rename_db "$STAGING" "$TARGET"; then
    rename_db "$DISPLACED" "$TARGET" \
      || fail "could not promote '$STAGING', AND could not restore the original
  name. Nothing has been dropped. You have BOTH databases:
      '$DISPLACED' — your original data, intact
      '$STAGING'   — the restore, decrypted and verified
  Rename whichever you want back to '$TARGET' by hand:
      ALTER DATABASE \"$DISPLACED\" RENAME TO \"$TARGET\";"
    fail "could not promote '$STAGING' to '$TARGET'. The original database has
  been renamed back and is unchanged. The verified restore is still here as
  '$STAGING' and was not dropped — retry, or promote it by hand once you know
  why the rename failed."
  fi
else
  if ! rename_db "$STAGING" "$TARGET"; then
    fail "the restore into '$STAGING' succeeded but could not be renamed to
  '$TARGET'. Nothing was dropped: the restore is still here as '$STAGING'."
  fi
fi

echo "Restored into '$TARGET' — ${TABLES} tables."
if [ "$TARGET_EXISTS" = "1" ]; then
  echo
  echo "The previous '$TARGET' was NOT dropped. It is still here as:"
  echo "    $DISPLACED"
  echo "Check the restore holds what you expect — row counts, and the most"
  echo "recent observations you know should be there — and only then drop it:"
  echo "    DROP DATABASE \"$DISPLACED\";"
  echo "Nothing deletes it for you. A disk is cheaper than a season."
  # Retention rule (task 10.40): these are never auto-dropped — an automated
  # prune here is exactly the failure mode 10.37 exists to prevent, since a
  # displaced database may be the only proof a bad restore is recoverable.
  # The only automated behaviour is this loud count, so accumulation is
  # visible at the moment an operator would naturally be looking, rather than
  # discovered later as unexplained disk usage.
  OTHER_DISPLACED="$(psql_admin -tAc \
    "SELECT datname FROM pg_database WHERE datname LIKE '${TARGET}\\_replaced\\_%' AND datname != '$DISPLACED'" \
    | sed '/^[[:space:]]*$/d' || true)"
  if [ -n "$OTHER_DISPLACED" ]; then
    COUNT="$(echo "$OTHER_DISPLACED" | wc -l | tr -d '[:space:]')"
    echo
    echo "NOTE: $COUNT older '${TARGET}_replaced_*' database(s) also exist from"
    echo "previous restores:"
    echo "$OTHER_DISPLACED" | sed 's/^/    /'
    echo "Each is a full copy left on disk on purpose; drop the ones you have"
    echo "already confirmed are no longer needed."
  fi
else
  echo "Now check it holds what you expect before trusting it: row counts, and"
  echo "the most recent observations you know should be there."
fi
