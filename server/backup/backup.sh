#!/bin/sh
# Encrypted database backup (task 10.24 / Security Model §4.9).
#
# Runs entirely inside the backup container so that `pg_dump | age` is a single
# in-process pipe and the only bytes that ever reach a filesystem are
# ciphertext. §4.9: "plaintext never lands on disk, not even in a temp
# directory" — that is why this is a script in the image rather than a host
# pipeline with a container on each end.
#
# Reads from the environment (see .env.example):
#   POSTGRES_HOST/PORT/USER/PASSWORD/DB   what to dump
#   TRITRACK_BACKUP_RECIPIENTS            age recipients, comma/space separated
#   TRITRACK_BACKUP_KEEP                  how many archives to retain (default 30)
#
# Reads from the filesystem:
#   /signing/key.sec   minisign secret key, mounted read-only (task 10.43)
#
# Writes /backups/tritrack-<UTC timestamp>.age, a .sha256 beside it, a
# .schema sidecar (task 10.36) recording schema_major/schema_version in the
# clear, and a .minisig (task 10.43) — an Ed25519 signature over the archive
# whose signed trusted comment carries the checksum and the schema marker, so
# that all three of the things restore.sh checks are bound to a key an
# attacker does not have. See §4.9.2 and the header of restore.sh.
set -eu
set -o pipefail

fail() {
  echo "BACKUP FAILED — $1" >&2
  exit 1
}

: "${POSTGRES_HOST:?POSTGRES_HOST is not set}"
: "${POSTGRES_DB:?POSTGRES_DB is not set}"
: "${POSTGRES_USER:?POSTGRES_USER is not set}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is not set}"
PORT="${POSTGRES_PORT:-5432}"
KEEP="${TRITRACK_BACKUP_KEEP:-30}"

# --- Can this container actually write an archive? (task 11.70) -------------
#
# Asked here, before a database connection is opened, because the answer used
# to arrive as `pg_dump | age pipeline failed; no archive written` — the shell
# failing to create `> "$PART"` inside a directory this user cannot write,
# reported as a database error. An operator on a Linux server following
# server/README.md hit that on their first backup and had every reason to read
# it as transient. **The harm is not the failed backup; it is believing you
# have encrypted backups when no archive was ever written.**
#
# A probe write rather than an inspection of the mode bits: whether this
# process can create a file in this directory is the property, and a mode bit
# is only a description of it (the same reasoning task 11.71 used for the
# escape-target search).
. /usr/local/lib/tritrack-permissions.sh
WRITE_PROBE="/backups/.tritrack-write-probe.$$"
if ! (umask 077; : > "$WRITE_PROBE") 2>/dev/null; then
  fail "cannot create a file in /backups, so no archive can be written.$(tritrack_ownership_note /backups)"
fi
rm -f "$WRITE_PROBE"

# The signing key, checked in the same breath and for the same reason. It is
# mode 600 and owned by the operator — server/README.md says to create it that
# way and §4.9.2 says why — so on Linux a container running as anyone else
# finds the file and cannot open it.
#
# Mounted-but-unreadable is its own case and must not fall through to either
# branch of the SIGN check further down. Treating it as "no signing key" would
# write a silently UNSIGNED archive while .env plainly configures one, and the
# operator would only learn that at the restore that refuses it. Treating it as
# "signing failed" would report it only after a complete archive had been
# written and then deleted. Asked here, before the database connection, so
# every permission refusal in this script happens before anything is touched.
if [ -e /signing/key.sec ] && [ ! -r /signing/key.sec ]; then
  fail "a signing key is mounted at /signing/key.sec but this container cannot read it.
  Refusing to write an archive that would be silently UNSIGNED while .env
  configures a key — an unsigned archive can never be restored in place over
  an existing database (§4.9.2).$(tritrack_ownership_note /signing/key.sec)"
fi

# --- A read-only role for the connection that actually touches the database
# (task 10.63 / Security Model §12.5, finding J-3's sibling) -----------------
#
# `$POSTGRES_USER` is a superuser on the official `postgres` image — J-3
# demonstrated `COPY ... FROM PROGRAM` on the always-on server connection that
# authenticates the same way. This script's own connection is the same
# credential doing a narrower job: `pg_dump` and one `SELECT`, never a write.
# Bootstrapped here rather than assumed to exist, because — unlike the server
# connection, which always finds `tritrack_app` already created by
# `PostgresMigrations.run` — `docker compose run backup` has no `depends_on`
# relationship to the `server` service and can run against a database the
# server has never started against.
#
# `SELECT`-only, not `tritrack_app`'s read/write grant: this connection never
# needs to write, so it does not get privileges the server's connection needs
# for its own job. `NOSUPERUSER`/`NOLOGIN` for the same reason as
# `tritrack_app` and `tritrack_restore` (see postgres_database.dart and
# restore.sh): the attribute check is what removes `COPY ... FROM PROGRAM`,
# and `SET ROLE` on the already-authenticated admin connection needs no second
# credential to provision or rotate.
BACKUP_ROLE=tritrack_backup
psql_admin() {
  PGPASSWORD="$POSTGRES_PASSWORD" psql --host="$POSTGRES_HOST" --port="$PORT" \
    --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" --quiet --no-psqlrc \
    -v ON_ERROR_STOP=1 "$@"
}
# Task 10.78 (finding K-9): this was check-then-create (SELECT from
# pg_roles, then CREATE ROLE if absent) — the exact shape task 10.69 replaced
# in ensureServerAppRole (postgres_database.dart) with an unconditional
# CREATE ROLE that swallows only "someone else already created it", after
# reproducing the race 30/30 at 8-way concurrency. Narrowing the check does
# not close a check-then-act race; only removing the gap between the check
# and the act does. Two backups on one host, or a cron run overlapping a
# manual one, both open this connection concurrently, so this is not
# hypothetical the way it might look in a script normally run alone.
if ! CREATE_BACKUP_ROLE_ERR=$(psql_admin -c "CREATE ROLE \"$BACKUP_ROLE\" \
    NOSUPERUSER NOCREATEDB NOCREATEROLE NOLOGIN NOREPLICATION NOBYPASSRLS" 2>&1); then
  case "$CREATE_BACKUP_ROLE_ERR" in
    # 42710 (duplicate_object, the common case) or 23505 (unique_violation on
    # pg_authid's index, seen only when two connections both pass the
    # nonexistent-role check before either creates it) — the same two
    # SQLSTATEs ensureServerAppRole's comment names, both meaning "the role
    # exists now," never a reason to fail this backup.
    *"already exists"*|*"duplicate key value violates unique constraint"*) ;;
    *) fail "creating role \"$BACKUP_ROLE\" failed:
$CREATE_BACKUP_ROLE_ERR" ;;
  esac
fi
psql_admin -c "GRANT \"$BACKUP_ROLE\" TO CURRENT_USER"
# Re-granted every run, unconditionally: a table added by a migration since
# the last backup must be dumpable on this run, not one release behind it —
# same reasoning as `ensureServerAppRole` in postgres_database.dart.
psql_admin -c "GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"$BACKUP_ROLE\""
# `auth_audit_log`/`sync_traffic_log` are `BIGSERIAL`, i.e. backed by a real
# sequence; pg_dump reads a sequence's current value as part of dumping it,
# which needs USAGE the same way an INSERT does. Same fix
# `ensureServerAppRole` needed after task 10.66's own rule caught it missing.
psql_admin -c "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO \"$BACKUP_ROLE\""

# --- Recipients ------------------------------------------------------------
#
# No default and no fallback. §4.9 says backups are *always* public-key
# encrypted; the failure mode this guards is a cron job that quietly starts
# writing plaintext because a variable went missing, which is worse than a
# cron job that starts failing loudly.
RECIPIENTS="${TRITRACK_BACKUP_RECIPIENTS:-}"
if [ -z "$(printf '%s' "$RECIPIENTS" | tr -d '[:space:],')" ]; then
  fail "TRITRACK_BACKUP_RECIPIENTS is empty.
  Every archive is encrypted to at least one age recipient and there is no
  unencrypted path — see TriTrack_Security_Model.md §4.9 and its custody
  arrangement. Generate an identity with:

      age-keygen -o backup-identity.txt

  keep that file OFF the server, and put its 'Public key: age1...' line in
  .env as TRITRACK_BACKUP_RECIPIENTS."
fi

# Build the `-r` argument list. Positional parameters rather than an array,
# because this is POSIX sh.
set --
count=0
for r in $(printf '%s' "$RECIPIENTS" | tr ',' ' '); do
  case "$r" in
    age1*) ;;
    ssh-ed25519|ssh-rsa) fail "recipient '$r' looks like a truncated SSH key" ;;
    ssh-*) ;;
    *) fail "recipient '$r' is not an age recipient (expected age1... or an SSH public key)" ;;
  esac
  set -- "$@" -r "$r"
  count=$((count + 1))
done

if [ "$count" -lt 2 ]; then
  # Not fatal: §4.9's custody arrangement permits a single recipient whose
  # redundancy is an offline paper copy. It is called out on every run because
  # the difference between "one recipient, offline copy exists" and "one
  # recipient, no copy anywhere" is invisible from here and is the difference
  # between a backup and a time bomb.
  echo "NOTE: encrypting to a single recipient. Confirm the offline copy of" >&2
  echo "      that private key actually exists (Security Model §4.9 custody)." >&2
fi

# --- Signing key (task 10.43 / finding H-6) ---------------------------------
#
# Encryption is not authentication. §4.9 chose public-key backups so that the
# machine taking them, and the off-site destination holding them, cannot READ
# one — and §4.9.1 says plainly that the recipient strings are not secret and
# may appear in a commit. H-6 turned that around: anyone holding the public
# recipient can WRITE an archive that decrypts perfectly with the operator's
# own key, and restore.sh had nothing to distinguish it from a real backup.
#
# So each archive is signed here, on the machine that produced it, with a key
# the archive directory never sees. §4.9.2 is the custody arrangement for it,
# and the two halves live in opposite places on purpose: the age private keys
# are deliberately NOT on this machine, and the signing private key must be,
# because an unattended cron job has to sign without a human.
#
# A missing signing key WARNS rather than refusing — the opposite of the
# recipients check above, deliberately. An unencrypted archive is a disclosure
# that cannot be undone; an unsigned archive is a complete, encrypted,
# perfectly restorable backup that merely cannot prove where it came from.
# Refusing to take one would trade a real data-loss risk for a paper control.
# The enforcement lives on the restore side, where the trust decision actually
# is: restore.sh refuses to promote an unsigned archive over an existing
# database at all (§4.9.2).
SIGNING_KEY=/signing/key.sec
SIGN=0
if [ -f "$SIGNING_KEY" ]; then
  SIGN=1
else
  echo "NOTE: no signing key at $SIGNING_KEY — this archive will be UNSIGNED." >&2
  echo "      An unsigned archive can be restored into a new database but can" >&2
  echo "      never be restored in place over an existing one (§4.9.2, H-6)." >&2
  echo "      Generate one with:  minisign -G -W -p backup-verify.pub -s backup-sign.sec" >&2
  echo "      point TRITRACK_BACKUP_SIGNING_KEY at the .sec, and put the .pub's" >&2
  echo "      key line in TRITRACK_BACKUP_VERIFY_KEY wherever restores are run." >&2
fi

# --- Dump ------------------------------------------------------------------
umask 077
mkdir -p /backups
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="/backups/tritrack-${STAMP}.age"
PART="${OUT}.part"
SCHEMA_FILE="${OUT}.schema"

[ -e "$OUT" ] && fail "$OUT already exists — refusing to overwrite an archive"

# --- Schema-version marker (task 10.36) -------------------------------------
#
# Written in cleartext, next to the archive, so an operator can tell which
# schema major/version a backup holds without the decryption key — choosing
# between archives shouldn't require unlocking them first.
#
# The mapping below is a copy of `schemaMajorFirstMinor` in
# packages/tritrack_sync/lib/src/schema_constants.dart — one `-ge` test per
# major, highest first. **It is checked**: `server/test/security/
# shipped_defaults_test.dart` parses these lines and fails if they disagree
# with the Dart map, because until task 11.242 this chain was hand-typed and
# stopped at 2 — so every backup of a v14 or v15 server was labelled with the
# wrong major, in the sidecar and in the signed comment, for a week, and
# nothing read the constant to notice. When a major is bumped, add its line
# here; the test says so.
SCHEMA_VERSION="$(psql_admin -tAc \
  "SET ROLE \"$BACKUP_ROLE\"; SELECT COALESCE(MAX(version), 0) FROM schema_migrations")"
if [ "$SCHEMA_VERSION" -ge 19 ] 2>/dev/null; then
  SCHEMA_MAJOR=6   # task 11.323, an estimate's ellipse columns lost NOT NULL
elif [ "$SCHEMA_VERSION" -ge 17 ] 2>/dev/null; then
  SCHEMA_MAJOR=5   # task 11.243, Tags lost four columns and Deployments arrived
elif [ "$SCHEMA_VERSION" -ge 16 ] 2>/dev/null; then
  SCHEMA_MAJOR=4   # task 11.242, for 11.240's Tags.color_hex losing NOT NULL
elif [ "$SCHEMA_VERSION" -ge 14 ] 2>/dev/null; then
  SCHEMA_MAJOR=3   # task 11.219, tags became project-scoped
elif [ "$SCHEMA_VERSION" -ge 6 ] 2>/dev/null; then
  SCHEMA_MAJOR=2   # task 10.35, primary keys became (<id>, project_id)
else
  SCHEMA_MAJOR=1
fi

cleanup_part() { rm -f "$PART"; }
trap cleanup_part EXIT

echo "Dumping ${POSTGRES_DB} from ${POSTGRES_HOST}:${PORT} to ${count} recipient(s)..."

# `set -o pipefail` above is what makes this correct. Without it a pg_dump that
# dies halfway still leaves `age` exiting 0, and the result is a well-formed
# archive of a truncated dump — a backup that restores silently missing rows.
# The archive is built under a .part name and only renamed once the whole
# pipeline succeeds, so an interrupted run leaves nothing that looks restorable.
# --exclude-table-data=server_database_identity (task 11.58): the table's
# definition is dumped and its one row is not, so a database restored from
# this archive has no identifier and the server mints a NEW one on its next
# start. That is the whole point of the identifier — it tells every device
# "the records you synced against are not the ones here any more", and a
# restore that carried the old one across would say the opposite. See
# server/lib/src/sync/database_identity.dart. restore.sh also empties it.
# PGOPTIONS sets the role for the whole session at connection time — the
# equivalent of the `SET ROLE` above, for a tool (`pg_dump`) that has no flag
# for it and no SQL prompt to send one to.
if ! PGPASSWORD="$POSTGRES_PASSWORD" PGOPTIONS="-c role=$BACKUP_ROLE" pg_dump \
      --host="$POSTGRES_HOST" \
      --port="$PORT" \
      --username="$POSTGRES_USER" \
      --dbname="$POSTGRES_DB" \
      --no-owner \
      --no-privileges \
      --exclude-table-data=server_database_identity \
    | age "$@" > "$PART"; then
  # Three things can fail here and the message must not pick one: pg_dump,
  # age, or the redirection into /backups. The last of those is checked at the
  # top of this script now (task 11.70), so if it is still what happened, the
  # directory changed underneath a running backup.
  fail "the dump pipeline failed and no archive was written. The three things
  that can fail here are pg_dump reading the database, age encrypting the
  stream, and the write into /backups; whichever it was, its own error is
  above this line.$([ -w /backups ] || tritrack_ownership_note /backups)"
fi

# Cheap proof that we wrote ciphertext and not a dump. If `age` were ever
# replaced by something that passes bytes through, this is what catches it
# before the archive reaches a cloud drive.
if ! head -c 21 "$PART" | grep 'age-encryption.org' >/dev/null; then
  fail "output does not carry an age header — refusing to keep it"
fi

mv "$PART" "$OUT"
trap - EXIT
sha256sum "$OUT" | sed 's#/backups/##' > "${OUT}.sha256"
printf 'schema_major=%s\nschema_version=%s\n' "$SCHEMA_MAJOR" "$SCHEMA_VERSION" > "$SCHEMA_FILE"

# --- Sign it (task 10.43 / finding H-6) -------------------------------------
#
# Signed over the ARCHIVE ITSELF, not over the sidecars, with the sidecars'
# contents carried in minisign's *trusted* comment — which is covered by a
# second signature and so cannot be edited either. One signature therefore
# binds all three of the things restore.sh checks: the ciphertext, the
# recorded checksum, and the schema marker. H-6's attacker authored all three
# and passed all three.
#
# -H is prehashed mode: minisign's legacy mode reads the whole file into
# memory to sign it, which is not a property to rely on for a database dump.
# Verification detects the mode from the signature, so restore.sh needs no
# matching flag.
if [ "$SIGN" = "1" ]; then
  ARCHIVE_SHA="$(sed 's/ .*//' "${OUT}.sha256")"
  if ! minisign -S -H -s "$SIGNING_KEY" -m "$OUT" -x "${OUT}.minisig" \
        -c "TriTrack encrypted database backup (Security Model §4.9)" \
        -t "tritrack-backup v1 archive=$(basename "$OUT") sha256=${ARCHIVE_SHA} schema_major=${SCHEMA_MAJOR} schema_version=${SCHEMA_VERSION}" \
        >/dev/null; then
    # The archive is kept. It is a complete, correct, encrypted backup; a
    # signing failure makes it unverifiable, not wrong, and deleting a good
    # backup because a signature failed is the larger of the two harms. The
    # run still fails loudly, and restore.sh will refuse to promote it in
    # place, so the degraded state is enforced rather than merely announced.
    rm -f "${OUT}.minisig"
    fail "the archive was written and is intact, but signing it FAILED.
  $OUT is unsigned: restorable into a new database, never in place (§4.9.2).
  Check the key mounted at $SIGNING_KEY is a minisign secret key with no
  password (generated with -W), then re-run to produce a signed archive."
  fi
  echo "Signed ${OUT}.minisig"
fi

echo "Wrote ${OUT} ($(wc -c < "$OUT") bytes) — schema major ${SCHEMA_MAJOR} (v${SCHEMA_VERSION})"

# --- Retention -------------------------------------------------------------
#
# §4.9: "retention is bounded and old backups are deleted on schedule. Every
# retained backup is another full copy of asset 1."
#
# Keep the newest KEEP archives rather than deleting by age. Age-based deletion
# has a failure mode this does not: if backups stop running for a month, an
# `-mtime +30` rule deletes every surviving copy exactly when they are the only
# ones left.
#
# Task 10.44 / finding H-7. The old rule kept the KEEP lexically-highest
# `tritrack-*.age` names on the comment "timestamps are ISO basic UTC, so
# lexical order is chronological order" — true only for names this script
# wrote. An entity with write-only access to this directory plants
# tritrack-29991231T235959Z.age and 29 siblings, and the next legitimate run
# deleted the entire genuine history, because it trusted every filename that
# matched the glob. `backup.sh:85` above already refuses to overwrite an
# archive it would write; it placed no matching constraint on files it did
# not write. That asymmetry was the finding.
#
# So retention now only prunes archives it can ACCOUNT FOR: a "genuine
# archive" is task 10.43's predicate for it — one whose .minisig verifies
# against TRITRACK_BACKUP_VERIFY_KEY — not a name shape. Anything else in the
# directory is a reason to REFUSE THE ENTIRE PRUNE this run, never an
# instruction to delete something else instead.
#
# Task 10.53 / finding I-2. A signature covers bytes, not the filename beside
# it: copy one genuine (archive, .minisig) pair to any other name and the copy
# verifies exactly as well as the original. 10.43's predicate above treated
# "verifies" as "genuine", so thirty renamed copies of one real pair all
# counted as thirty genuine archives to KEEP — and the two archives actually
# named tritrack-<their real timestamp>.age, now merely the oldest two names
# in a directory of thirty-two, were the ones retention deleted.
#
# The fix is already latent in the data: backup.sh signs the trusted comment
# `tritrack-backup v1 archive=<basename> sha256=... schema_major=...
# schema_version=...` (below), and that comment is itself covered by the
# signature. So "genuine" now requires the signature to verify AND the signed
# archive= field to equal this file's own basename — a renamed copy still
# verifies, but no longer as itself.
if [ "$KEEP" -gt 0 ] 2>/dev/null; then
  RETENTION_VERIFY_KEYS="$(printf '%s' "${TRITRACK_BACKUP_VERIFY_KEY:-}" | tr ',' ' ')"
  if [ -z "$(printf '%s' "$RETENTION_VERIFY_KEYS" | tr -d '[:space:]')" ]; then
    echo "NOTE: TRITRACK_BACKUP_VERIFY_KEY is not set, so retention cannot" >&2
    echo "      prove which archives in /backups are genuine. Refusing to" >&2
    echo "      prune anything this run rather than trust filenames" >&2
    echo "      (Security Model §10.5.2, H-7). This is not a one-time notice:" >&2
    echo "      it will print again on every scheduled run, keeping every" >&2
    echo "      archive TRITRACK_BACKUP_KEEP=$KEEP would otherwise have" >&2
    echo "      pruned, until this is set — disk usage on this machine has" >&2
    echo "      no ceiling until then (task 10.59, finding I-11). Set" >&2
    echo "      TRITRACK_BACKUP_VERIFY_KEY to the public half of the signing" >&2
    echo "      key (§4.9.2) to resume pruning." >&2
  else
    UNACCOUNTABLE=""
    for f in /backups/tritrack-*.age; do
      [ -e "$f" ] || continue
      GENUINE=0
      if [ -f "${f}.minisig" ]; then
        for k in $RETENTION_VERIFY_KEYS; do
          if TRUSTED_COMMENT="$(minisign -V -Q -P "$k" -m "$f" -x "${f}.minisig" 2>/dev/null)"; then
            SIGNED_NAME="$(printf '%s' "$TRUSTED_COMMENT" | sed -n 's/.*[[:space:]]archive=\([^[:space:]]*\).*/\1/p')"
            if [ "$SIGNED_NAME" = "$(basename "$f")" ]; then
              GENUINE=1
              break
            fi
          fi
        done
      fi
      [ "$GENUINE" = "1" ] || UNACCOUNTABLE="${UNACCOUNTABLE:+$UNACCOUNTABLE }$(basename "$f")"
    done

    if [ -n "$UNACCOUNTABLE" ]; then
      echo "RETENTION REFUSED — archive(s) present that this run cannot" >&2
      echo "  account for (no .minisig, a signature that does not verify" >&2
      echo "  against TRITRACK_BACKUP_VERIFY_KEY, or a signature that verifies" >&2
      echo "  but was signed under a DIFFERENT filename — a renamed copy of a" >&2
      echo "  genuine archive, task 10.53/I-2):" >&2
      echo "    $UNACCOUNTABLE" >&2
      echo "  This is consistent with a write-only attacker planting names" >&2
      echo "  in /backups to make retention delete the real history for them" >&2
      echo "  (Security Model §10.5.2, H-7). Refusing to prune ANYTHING this" >&2
      echo "  run — nothing genuine has been deleted. Investigate; do not" >&2
      echo "  just delete the file(s) above without finding out who wrote" >&2
      echo "  them." >&2
    else
      # Timestamps are ISO basic UTC, so lexical order is chronological order
      # among archives that have all just verified as genuine, above.
      ls -1 /backups/tritrack-*.age 2>/dev/null | sort -r | tail -n +$((KEEP + 1)) \
        | while read -r old; do
            echo "Retention: removing $old"
            rm -f "$old" "${old}.sha256" "${old}.schema" "${old}.minisig"
          done
    fi
  fi
else
  echo "NOTE: TRITRACK_BACKUP_KEEP=$KEEP — retention disabled, archives accumulate." >&2
fi
