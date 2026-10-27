#!/usr/bin/env bash
# gate-instrument: verify_h6_archive_forgery
# Security Gate C, third re-run (task 10.25, 2026-08-14) — finding H-6.
# Kept as a regression test by task 10.43, which closed it.
#
# Does the restore path authenticate the ORIGIN of an archive, or only its
# integrity relative to whatever key it was encrypted to?
#
# §4.9 chose public-key backups precisely so the box taking the backup, and the
# off-site destination holding it, cannot read the contents. The public
# recipient strings are explicitly not secrets — §4.9 says they may appear "in
# documentation, tickets, or a commit". That decision is about *reading*.
# Nothing in §4.9, `backup.sh` or `restore.sh` says anything about who may
# *write* an archive that the restore path will trust.
#
# `restore.sh` gates a restore on three things, and this script asks whether an
# entity with write access to the archive directory — the off-site copy, the
# sync target, the incident-time "fetch another copy" — can satisfy all three:
#
#   1. `<archive>.sha256`  — a plain checksum file, sitting beside the archive
#   2. `<archive>.schema`  — a cleartext marker, no cryptographic binding
#   3. `age --decrypt | awk`— requires two literal pg_dump comment lines
#
# If it can, the forged plaintext is piped into `psql` as POSTGRES_USER, which
# the postgres image creates as a SUPERUSER, and is then renamed into the live
# database name while the real database is renamed aside.
#
# Run: bash scripts/verify_h6_archive_forgery.sh
# Everything runs under its own Compose project name and its own volumes, and
# is torn down on exit. It never touches the developer's stack (F15).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

PROJECT="tritrack-h6-forgery"
COMPOSE=(docker compose -p "$PROJECT" -f docker-compose.yml)
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tritrack-h6.XXXXXX")"
chmod 700 "$WORK"

# Task 11.70. Every container below runs as whatever `docker-compose.yml`'s
# `backup` service says, which is the same mechanism a real deployment gets —
# see the long note at the top of `scripts/backup_restore_drill.sh`.
#
# Briefly: task 11.69 made these scripts pass `--user` so they would run on a
# Linux host at all, where the image's own uid 70 cannot traverse this
# script's 0700 working directory or write into the backup directory. That
# fixed the instrument and left the shipped procedure broken, so this check
# passing stopped being evidence about a real deployment. The override is now
# gone and `scripts/lib/backup_user.sh` sets TRITRACK_BACKUP_UID/GID, exactly
# as `scripts/backup_db.sh` does.
# shellcheck disable=SC1091
. scripts/lib/backup_user.sh
# Task 11.176 — readiness loops keep their last attempt's error. See that file.
# shellcheck disable=SC1091
. scripts/lib/wait_for.sh

CHECKS=0
pass() { CHECKS=$((CHECKS + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAILED\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mHARNESS ERROR\033[0m  %s\n' "$1" >&2; exit 2; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

cleanup() {
  step "Tearing down"
  "${COMPOSE[@]}" --profile backup down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$WORK"
  echo "  removed throwaway key, forged archive and volumes"
}
trap cleanup EXIT

[ -f .env ] || fail "missing .env"
set -a
# shellcheck disable=SC1091
source .env
set +a

export POSTGRES_USER="${POSTGRES_USER:-tritrack}"
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-h6-only-not-a-real-secret}"
export POSTGRES_DB="${POSTGRES_DB:-tritrack}"
export TRITRACK_ENV=""
export TRITRACK_TLS_CERT_PATH=""
export TRITRACK_TLS_KEY_PATH=""
export TRITRACK_DIAGNOSTICS_ENABLED="false"
export SERVER_PUBLISH_ADDRESS="127.0.0.1"
export SERVER_PORT="${TRITRACK_H6_PORT:-8097}"
export TRITRACK_BACKUP_DIR="${WORK}/backups"
export TRITRACK_BACKUP_KEEP="30"
export TRITRACK_RESTORE_IDENTITY="/dev/null"
mkdir -p "$TRITRACK_BACKUP_DIR"

psql_h6() {
  local db="$1"; shift
  "${COMPOSE[@]}" --profile backup run --rm --no-deps -T \
    -e PGPASSWORD="$POSTGRES_PASSWORD" backup \
    psql --host=postgres --username="$POSTGRES_USER" --dbname="$db" \
      --quiet --no-psqlrc -tA -v ON_ERROR_STOP=1 "$@"
}

# Task 11.176. This asks *Postgres* whether Postgres is up, from inside the
# Postgres container, and touches nothing else. It used to ask through
# `psql_h6`, which runs psql inside the *backup* container — so its success
# needed the backup image to build, the compose network to work, and the
# database to be listening, and its failure named only the last of the three.
# On 2026-09-06 the backup image would not build, and this script reported
# `postgres never came up` about a database that was healthy throughout.
postgres_is_up() {
  "${COMPOSE[@]}" exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" postgres \
    psql --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" \
      --quiet --no-psqlrc -tA -v ON_ERROR_STOP=1 -c "SELECT 1"
}

step "1. A live database with one row that exists nowhere else"
"${COMPOSE[@]}" up -d postgres >/dev/null
wait_for 60 1 -- postgres_is_up \
  || fail "postgres never came up. $(wait_for_evidence)"

# Built explicitly, and before anything needs it, so that a build failure is
# reported as a build failure. `compose run` would build it implicitly at the
# first `psql_h6` below, where the error would arrive attached to whatever
# database step happened to be running.
"${COMPOSE[@]}" --profile backup build backup >"${WORK}/backup-build.log" 2>&1 \
  || { sed 's/^/    /' "${WORK}/backup-build.log" >&2
       fail "the backup image would not build — see the build output above.
  Every step below this one talks to the database through this image, so
  nothing further can run. This is not a fault in the database or the
  network."; }
psql_h6 "$POSTGRES_DB" -c \
  "CREATE TABLE IF NOT EXISTS \"Observations\" (observation_id TEXT PRIMARY KEY,
     latitude NUMERIC, longitude NUMERIC, notes TEXT);
   INSERT INTO \"Observations\" VALUES
     ('h6-real-observation', 35.1898765, -111.6512345, 'the only copy')
   ON CONFLICT DO NOTHING;" >/dev/null
REAL_ROWS="$(psql_h6 "$POSTGRES_DB" -c \
  "SELECT count(*) FROM \"Observations\" WHERE observation_id = 'h6-real-observation'" \
  | tr -d '[:space:]')"
[ "$REAL_ROWS" = "1" ] || fail "could not seed the live row"
pass "seeded the live database with 'h6-real-observation'"

step "2. The attacker's position: the PUBLIC recipient string, and nothing else"
"${COMPOSE[@]}" --profile backup run --rm --no-deps -T --entrypoint age-keygen \
  backup > "$WORK/operator_key.txt" 2>/dev/null
chmod 600 "$WORK/operator_key.txt"
RECIPIENT="$(grep 'public key:' "$WORK/operator_key.txt" | sed 's/.*: //')"
[ -n "$RECIPIENT" ] || fail "could not derive the public recipient"
# This is the whole of the attacker's key material. It is not a secret: §4.9
# says so, .env holds it in the clear, and it is safe to publish — for reading.
pass "attacker holds only the public recipient ($RECIPIENT)"

step "3. Forging an archive that satisfies every check restore.sh makes"
# pg_dump's own first and last lines, which are the entirety of the content
# test at restore.sh:204-208, wrapped around arbitrary SQL of the attacker's
# choosing. This one drops the real table and substitutes its own.
cat > "$WORK/forged.sql" <<'SQL'
-- PostgreSQL database dump
SET client_encoding = 'UTF8';
CREATE TABLE "Observations" (observation_id TEXT PRIMARY KEY, latitude NUMERIC,
  longitude NUMERIC, notes TEXT);
INSERT INTO "Observations" VALUES
  ('h6-FORGED-observation', 0.0, 0.0, 'planted by an entity that cannot read a backup');
CREATE TABLE forged_marker (note TEXT);
INSERT INTO forged_marker VALUES ('this SQL ran as the postgres superuser');
-- PostgreSQL database dump complete
SQL
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
FORGED="tritrack-${STAMP}.age"
# Encrypting with the PUBLIC key. No private key is used or needed.
"${COMPOSE[@]}" --profile backup run --rm --no-deps -T \
  -v "$WORK:/forge" --entrypoint sh backup -c \
  "age -r '$RECIPIENT' -o '/backups/$FORGED' /forge/forged.sql" >/dev/null
[ -f "$TRITRACK_BACKUP_DIR/$FORGED" ] || fail "could not write the forged archive"
# The two sidecars, both authored by the attacker. restore.sh trusts the
# checksum it finds beside the archive; there is nothing else for it to compare
# against.
(cd "$TRITRACK_BACKUP_DIR" && shasum -a 256 "$FORGED" > "${FORGED}.sha256")
printf 'schema_major=2\n' > "$TRITRACK_BACKUP_DIR/${FORGED}.schema"
pass "wrote $FORGED plus a .sha256 and a .schema, all attacker-authored"

# Two configurations, because a control that only holds in the configuration
# its author was testing is not a control (task 10.43). The forged archive has
# to be refused whether or not this operator has got as far as configuring a
# verifying key — the second case is the state every existing deployment is in
# on the day the fix lands, and the one an attacker would rather find.
attempt_restore() { # <verify-key-or-empty> <logfile>
  set +e
  TRITRACK_RESTORE_ARCHIVE="$FORGED" \
  TRITRACK_RESTORE_TARGET_DB="$POSTGRES_DB" \
  TRITRACK_RESTORE_IDENTITY="$WORK/operator_key.txt" \
  TRITRACK_RESTORE_REPLACE="I_UNDERSTAND" \
  TRITRACK_BACKUP_VERIFY_KEY="$1" \
    "${COMPOSE[@]}" --profile backup run --rm --no-deps backup tritrack-restore \
    > "$2" 2>&1
  RESTORE_STATUS=$?
  set -e
}

step "4a. The operator restores in place with NO verifying key configured"
attempt_restore "" "$WORK/restore-nokey.log"
NOKEY_STATUS=$RESTORE_STATUS
sed 's/^/  | /' "$WORK/restore-nokey.log" | tail -12
if [ "$NOKEY_STATUS" != "0" ]; then
  pass "refused with no verifying key configured (exit $NOKEY_STATUS)"
else
  bad "accepted with no verifying key configured"
fi

step "4b. And again with a verifying key configured, following server/README.md"
"${COMPOSE[@]}" --profile backup run --rm --no-deps -T --entrypoint sh backup -c \
  'minisign -G -W -p /tmp/p.pub -s /tmp/s.sec >/dev/null 2>&1 && cat /tmp/p.pub' \
  > "$WORK/verify.pub"
VERIFY_KEY="$(grep -v '^untrusted comment' "$WORK/verify.pub" | sed -n 1p)"
[ -n "$VERIFY_KEY" ] || fail "could not generate a verifying key"
attempt_restore "$VERIFY_KEY" "$WORK/restore.log"
sed 's/^/  | /' "$WORK/restore.log" | tail -12

step "4c. A THIRD forgery: signed, but with the attacker's own key"
# Task 10.54 / Security Model §11.5. 4a and 4b both plant an UNSIGNED archive,
# so both fall out of restore.sh with SIGNED=0 and die at the identical
# no-signature refusal — minisign -V is never called in either arm, and the
# present-but-invalid-signature branch, the one with no override at all
# (§4.9.2), is exercised by no instrument at all. The public age recipient is
# not the attacker's only public value here: minisign itself is free, so an
# attacker with write access can generate their OWN key pair and sign what
# they forge — the question is whether a signature from a key nobody trusts
# is worth anything more than no signature. It is not, and restore.sh must
# refuse it unconditionally, never merely note it.
"${COMPOSE[@]}" --profile backup run --rm --no-deps -T --entrypoint sh backup -c \
  'minisign -G -W -p /tmp/a.pub -s /tmp/a.sec >/dev/null 2>&1 && cat /tmp/a.sec' \
  > "$WORK/attacker-sign.sec"
[ -s "$WORK/attacker-sign.sec" ] || fail "could not generate the attacker's own signing key"
STAMP2="$(date -u +%Y%m%dT%H%M%SZ)"
FORGED2="tritrack-${STAMP2}-selfsigned.age"
cat > "$WORK/forged2.sql" <<'SQL'
-- PostgreSQL database dump
SET client_encoding = 'UTF8';
CREATE TABLE "Observations" (observation_id TEXT PRIMARY KEY, latitude NUMERIC,
  longitude NUMERIC, notes TEXT);
INSERT INTO "Observations" VALUES
  ('h6-SELFSIGNED-observation', 0.0, 0.0, 'planted by an entity that signed with its own key');
SQL
echo '-- PostgreSQL database dump complete' >> "$WORK/forged2.sql"
"${COMPOSE[@]}" --profile backup run --rm --no-deps -T \
  -e DRILL_RECIPIENT="$RECIPIENT" -e DRILL_FILE="$FORGED2" \
  -v "$WORK:/forge:ro" --entrypoint sh backup -c '
    set -e
    age -r "$DRILL_RECIPIENT" -o "/backups/$DRILL_FILE" /forge/forged2.sql
    s="$(sha256sum "/backups/$DRILL_FILE" | sed "s/ .*//")"
    minisign -S -H -s /forge/attacker-sign.sec -m "/backups/$DRILL_FILE" \
      -x "/backups/$DRILL_FILE.minisig" -c drill \
      -t "tritrack-backup v1 archive=$DRILL_FILE sha256=$s schema_major=2 schema_version=6"
  ' >/dev/null
[ -f "$TRITRACK_BACKUP_DIR/$FORGED2" ] || fail "could not write the self-signed forged archive"
[ -f "$TRITRACK_BACKUP_DIR/${FORGED2}.minisig" ] || fail "could not sign it with the attacker's own key"
(cd "$TRITRACK_BACKUP_DIR" && shasum -a 256 "$FORGED2" > "${FORGED2}.sha256")
printf 'schema_major=2\n' > "$TRITRACK_BACKUP_DIR/${FORGED2}.schema"
pass "wrote $FORGED2, signed with the attacker's OWN key — not the operator's"

set +e
TRITRACK_RESTORE_ARCHIVE="$FORGED2" \
TRITRACK_RESTORE_TARGET_DB="$POSTGRES_DB" \
TRITRACK_RESTORE_IDENTITY="$WORK/operator_key.txt" \
TRITRACK_RESTORE_REPLACE="I_UNDERSTAND" \
TRITRACK_BACKUP_VERIFY_KEY="$VERIFY_KEY" \
  "${COMPOSE[@]}" --profile backup run --rm --no-deps backup tritrack-restore \
  > "$WORK/restore-selfsigned.log" 2>&1
SELFSIGNED_STATUS=$?
set -e
sed 's/^/  | /' "$WORK/restore-selfsigned.log" | tail -12
if [ "$SELFSIGNED_STATUS" = "0" ]; then
  bad "H-6 REPRODUCED (present-but-invalid signature) — an archive signed by a key nobody trusts was accepted for an in-place restore"
elif grep -q "does NOT verify against any key" "$WORK/restore-selfsigned.log"; then
  pass "refused for the right reason — the signature is present and does NOT verify, so minisign -V was actually exercised and failed it"
else
  bad "refused (exit $SELFSIGNED_STATUS), but not for the reason this arm exists to prove: $(tail -3 "$WORK/restore-selfsigned.log")"
fi

step "5. What is in the live database now?"
FORGED_ROWS="$(psql_h6 "$POSTGRES_DB" -c \
  "SELECT count(*) FROM \"Observations\" WHERE observation_id = 'h6-FORGED-observation'" \
  2>/dev/null | tr -d '[:space:]' || true)"
SURVIVING="$(psql_h6 "$POSTGRES_DB" -c \
  "SELECT count(*) FROM \"Observations\" WHERE observation_id = 'h6-real-observation'" \
  2>/dev/null | tr -d '[:space:]' || true)"
MARKER="$(psql_h6 "$POSTGRES_DB" -c \
  "SELECT count(*) FROM forged_marker" 2>/dev/null | tr -d '[:space:]' || true)"
SELFSIGNED_ROWS="$(psql_h6 "$POSTGRES_DB" -c \
  "SELECT count(*) FROM \"Observations\" WHERE observation_id = 'h6-SELFSIGNED-observation'" \
  2>/dev/null | tr -d '[:space:]' || true)"

echo
echo "  restore exit (no key)      : $NOKEY_STATUS"
echo "  restore exit (with key)    : $RESTORE_STATUS"
echo "  restore exit (self-signed) : $SELFSIGNED_STATUS"
echo "  forged row now live        : ${FORGED_ROWS:-<none>}"
echo "  self-signed row now live   : ${SELFSIGNED_ROWS:-<none>}"
echo "  real row still live        : ${SURVIVING:-<gone>}"
echo "  attacker's table created   : ${MARKER:-<none>}"

step "Verdict"
if [ "$NOKEY_STATUS" = "0" ] || [ "$SELFSIGNED_STATUS" = "0" ] \
   || { [ "$RESTORE_STATUS" = "0" ] && [ "${FORGED_ROWS:-0}" = "1" ]; } \
   || { [ "$SELFSIGNED_STATUS" = "0" ] && [ "${SELFSIGNED_ROWS:-0}" = "1" ]; }; then
  bad "H-6 REPRODUCED — an archive forged with only the public recipient (or"
  bad "signed with a key nobody trusts) was accepted, its SQL executed as the"
  bad "postgres superuser, and it was promoted into the live database name."
  bad "The real database was renamed aside (recoverable), but the running"
  bad "server now serves attacker content."
  echo
  echo "  The three gates all passed because the attacker authored all three"
  echo "  inputs: the checksum file, the schema marker, and an archive that is"
  echo "  genuinely encrypted to the operator's public key. age proves the"
  echo "  bytes were not altered after encryption. It cannot prove who"
  echo "  encrypted them, and nothing else in the path tries to."
  exit 1
elif [ "$RESTORE_STATUS" != "0" ] && [ "$SELFSIGNED_STATUS" != "0" ] \
     && [ "${SURVIVING:-0}" = "1" ] && [ "${FORGED_ROWS:-0}" = "0" ] \
     && [ "${SELFSIGNED_ROWS:-0}" = "0" ] && [ "${MARKER:-<none>}" = "<none>" ]; then
  pass "the forged archives were refused and the live row survived"
  echo
  echo "  $CHECKS checks passed — H-6 does not reproduce on this build."
  echo
  echo "  Closed by task 10.43: the archive is now signed on the machine that"
  echo "  produced it, with a key the archive directory never sees, and the"
  echo "  verifying key is configured with the restore procedure rather than"
  echo "  found beside the archive. An archive whose origin cannot be"
  echo "  established is never promoted over an existing database — see"
  echo "  Security Model §4.9.2. Task 10.54 added 4c above, which is what"
  echo "  proves that last sentence rather than merely repeating it: a"
  echo "  PRESENT signature that does not verify is refused unconditionally,"
  echo "  with no override, distinct from the no-signature-at-all case."
  exit 0
else
  bad "inconclusive: nokey=$NOKEY_STATUS exit=$RESTORE_STATUS selfsigned=$SELFSIGNED_STATUS forged=${FORGED_ROWS:-?} selfsigned_row=${SELFSIGNED_ROWS:-?} real=${SURVIVING:-?} marker=${MARKER:-?}"
  exit 2
fi
