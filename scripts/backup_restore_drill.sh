#!/usr/bin/env bash
# gate-instrument: backup_restore_drill
# Backup/restore drill (task 10.24 / Security Model §4.9).
#
#   scripts/backup_restore_drill.sh
#
# §4.9: "a backup that has never been restored is not a backup." This is the
# restore, performed for real, on a throwaway stack, with negative cases —
# not a paragraph asserting that it would work.
#
# What it proves, in order:
#   1. A real server bootstraps a real schema (the server's own migration
#      code, not a hand-written DDL that could drift from it).
#   2. Seeded rows include coordinates — asset 1 in §2's ranking.
#   3. The backup job refuses to run with no recipients configured.
#   4. The archive is age ciphertext, and the seeded coordinates do not appear
#      in it in the clear.
#   5. A DIFFERENT private key cannot decrypt it.
#   6. The correct key restores into a fresh database, and the restored schema
#      and every row match the original.
#   7. The in-place replace path — the only one that can destroy data — refuses
#      every unreadable archive with the live database still intact, and
#      succeeds on a good one without dropping what it replaced (task 10.37).
#   8. A FORGED archive — genuinely encrypted to the operator's own public
#      recipient by someone who never held the private key — is refused, and
#      is refused whether or not the operator has configured a verifying key
#      (task 10.43, finding H-6).
#   9. The swap's rollback, which had never run, actually runs; and the
#      verified restore survives even the double failure (finding H-9).
#  10. A failing pg_dump leaves no archive behind — no half-dump that looks
#      restorable.
#  11. Retention keeps the newest genuine archives, and refuses to prune
#      ANYTHING — not even the oldest genuine one — when an archive it cannot
#      verify is sitting in the directory (task 10.44, finding H-7).
#
# Step 7 exists because of finding G-3. Until task 10.37 every target this
# drill restored into was a fresh name — `drill_restored`, `drill_legacy`,
# `drill_toofar`, and a `drill_wrongkey` that never existed — so it never typed
# TRITRACK_RESTORE_REPLACE=I_UNDERSTAND at all. Eleven green checks and a
# restore path that dropped a live database before it knew the archive could be
# decrypted coexisted happily, because the drill only ever exercised the path
# that cannot destroy anything. A drill that avoids the dangerous path is not
# a drill.
#
# Steps 7h–7j and 7k–7m exist because of findings H-6 and H-9, and they are the
# same lesson one turn further: every case this drill had was an ACCIDENT — a
# checksum that rotted, a file cut short, the wrong holder's key. None of them
# was an adversary, and the restore path's own comments described accident
# defences in language that claimed authenticity. Three tasks read that file
# and nobody asked what someone who can write a file into the archive directory
# can do. So the forged-archive case below is not a variant of the truncation
# case; it is the case none of them were.
#
# Runs against its own compose project and its own volumes, so it never
# touches the operator's data or their running stack. Everything it creates,
# including the throwaway key, is destroyed on exit.
#
# Cadence: quarterly, and after any change to the schema, the backup image, or
# the pinned age or minisign version. Record the date in server/README.md's
# drill log.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

PROJECT="tritrack-backup-drill"
COMPOSE=(docker compose -p "$PROJECT" -f docker-compose.yml)
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tritrack-drill.XXXXXX")"
chmod 700 "$WORK"

# Task 11.70 — and the reason this block is worth reading before changing a
# `docker compose run` line below.
#
# **This drill runs the shipped backup procedure, including the part that
# decides which user the container is.** It did not always. Task 11.69 made
# every run here pass `--user` explicitly, because on a Linux host the image's
# own `USER postgres` (uid 70) cannot traverse this drill's 0700 working
# directory, read the 0600 signing key mounted out of it, or create a file in
# the backup directory — this drill died at step 5 on the first CI run with
# "pg_dump | age pipeline failed; no archive written".
#
# That fixed the instrument and left the shipped procedure broken, which meant
# **this drill passing was no longer evidence that a real deployment could
# write an archive** — a control measured in a configuration that does not
# ship, the shape task 10.54 exists to prevent.
#
# So the `--user` overrides are gone. `docker-compose.yml`'s `backup` service
# now declares `user:` itself, reading TRITRACK_BACKUP_UID/GID, and
# `scripts/lib/backup_user.sh` — the same file `scripts/backup_db.sh` and
# `scripts/restore_db.sh` source — is what sets them. Every container below is
# therefore configured by exactly the mechanism an operator gets, and a
# regression in that mechanism turns this drill red instead of leaving it
# green over a broken deployment.
#
# On Docker Desktop none of this is visible: its file-sharing layer presents
# bind-mounted host files to whatever user the container runs as. That is the
# difference behind every finding in task 11.69 and this one.
# shellcheck disable=SC1091
. scripts/lib/backup_user.sh
# Task 11.176 — readiness loops keep their last attempt's error. See that file.
# shellcheck disable=SC1091
. scripts/lib/wait_for.sh

# A coordinate pair that appears nowhere else in the repo, so "does this string
# appear in the ciphertext" is a meaningful question.
# The schema major this build is on, read from the one place it is written
# rather than typed here (task 11.242: this drill said "2" for a week after
# major 3 shipped, and passed, because backup.sh had the same stale copy).
# Failing on an empty read is deliberate — a drill that cannot find the number
# must not fall back to one.
EXPECTED_MAJOR="$(sed -n 's/^const int schemaMajorVersion = \([0-9][0-9]*\);.*/\1/p' \
  packages/tritrack_sync/lib/src/schema_constants.dart)"
[ -n "$EXPECTED_MAJOR" ] || { echo "could not read schemaMajorVersion from schema_constants.dart" >&2; exit 1; }
CANARY_LAT="35.1898765"
CANARY_LON="-111.6512345"
CANARY_NOTE="drill-canary-9f3a1c7e"

# Counted, so the total this prints is the total, rather than a number in
# server/README.md that someone has to remember to update (task 10.37 — the
# recorded count and the real one had already drifted twice).
CHECKS=0
pass() { CHECKS=$((CHECKS + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1" >&2; exit 1; }
# Task 11.69, second pass. `CURRENT_STEP` exists so that a failure names the
# step it happened in. Most of the ways this drill can fail are a
# `docker compose run` exiting non-zero under `set -e`, which prints whatever
# the container said and nothing about where we were. In CI that matters more
# than it looks: `gate_smoke_test.sh` keeps each instrument's full log in a
# `mktemp` directory that dies with the runner, and what survives into the
# workflow log is the last five lines. On the 2026-08-30 run those five lines
# were "BACKUP FAILED — pg_dump | age pipeline failed; no archive written" and
# the teardown — true, and not enough to tell step 4's backup from step 7's.
CURRENT_STEP="(before the first step)"
step() { CURRENT_STEP="$1"; printf '\n\033[1m%s\033[0m\n' "$1"; }

cleanup() {
  local rc=$?
  if [ "$rc" != "0" ]; then
    # Printed before the teardown, so it is inside the last few lines of
    # output whatever else happens — that is the only part of an instrument's
    # log CI keeps.
    printf '\n\033[31mDRILL FAILED during: %s\033[0m (exit %s)\n' \
      "$CURRENT_STEP" "$rc" >&2
  fi
  step "Tearing down"
  "${COMPOSE[@]}" --profile backup down -v --remove-orphans >/dev/null 2>&1 || true
  # The throwaway identity is a real private key for the duration of this run.
  rm -rf "$WORK"
  echo "  removed throwaway key and drill volumes"
}
trap cleanup EXIT

# `.env` is loaded in exactly one place — see that file for why (task
# 11.40 / 11.52). This used to be an eight-line block copied into seven
# scripts.
. scripts/lib/load_env.sh

# Drill-local overrides. Exported values beat .env in compose, so the operator's
# real settings (including TRITRACK_ENV=production, which would make the server
# refuse to start without TLS) do not leak into the drill.
export POSTGRES_USER="${POSTGRES_USER:-tritrack}"
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-drill-only-not-a-real-secret}"
export POSTGRES_DB="${POSTGRES_DB:-tritrack}"
export TRITRACK_ENV=""
export TRITRACK_TLS_CERT_PATH=""
export TRITRACK_TLS_KEY_PATH=""
export TRITRACK_DIAGNOSTICS_ENABLED="false"
export SERVER_PUBLISH_ADDRESS="127.0.0.1"
export SERVER_PORT="${TRITRACK_DRILL_PORT:-8099}"
export TRITRACK_BACKUP_DIR="${WORK}/backups"
export TRITRACK_BACKUP_KEEP="30"
export TRITRACK_RESTORE_IDENTITY="/dev/null"
mkdir -p "$TRITRACK_BACKUP_DIR"

psql_drill() {
  local db="$1"; shift
  "${COMPOSE[@]}" --profile backup run --rm --no-deps -T \
    -e PGPASSWORD="$POSTGRES_PASSWORD" backup \
    psql --host=postgres --username="$POSTGRES_USER" --dbname="$db" \
      --quiet --no-psqlrc -tA -v ON_ERROR_STOP=1 "$@"
}

# Step 7's question, and the only one that matters after a failed restore: is
# the live data still there? Deliberately tolerant — if the database has been
# dropped, psql exits non-zero and `set -o pipefail` would kill the drill at
# exactly the moment it has something to report. "" means "could not even ask",
# which is itself the failure.
live_canary() {
  local out
  out="$(psql_drill "$POSTGRES_DB" -c \
    "SELECT count(*) FROM \"Observations\" WHERE observation_id = 'drill-observation'" \
    2>/dev/null || true)"
  printf '%s' "$out" | tr -d '[:space:]'
}

# Runs restore.sh with the given archive/target/identity, capturing everything.
# Sets RESTORE_STATUS and leaves the output in $WORK/restore.log.
#
# Argument 7 is the verifying key, and it is `${7-...}` rather than `${7:-...}`
# on purpose: passing an explicit empty string must mean "this operator has
# configured no verifying key at all", which is one of the two configurations
# H-6's forgery has to be refused in.
try_restore() { # <archive> <target-db> <identity> [replace] [unsigned] [fault] [verify-key]
  set +e
  TRITRACK_RESTORE_ARCHIVE="$1" \
  TRITRACK_RESTORE_TARGET_DB="$2" \
  TRITRACK_RESTORE_IDENTITY="$3" \
  TRITRACK_RESTORE_REPLACE="${4:-}" \
  TRITRACK_RESTORE_UNSIGNED="${5:-}" \
  TRITRACK_RESTORE_FAULT="${6:-}" \
  TRITRACK_BACKUP_VERIFY_KEY="${7-${TRITRACK_BACKUP_VERIFY_KEY:-}}" \
    "${COMPOSE[@]}" --profile backup run --rm --no-deps backup tritrack-restore \
      >"${WORK}/restore.log" 2>&1
  RESTORE_STATUS=$?
  set -e
}

# Generates a minisign key pair inside the backup image and copies both halves
# out on stdout. Done this way rather than with a writable bind mount because
# the container runs as `postgres` and $WORK is the host user's 0700 directory.
gen_minisign() { # <secret-out> <public-out>
  "${COMPOSE[@]}" --profile backup run --rm --no-deps -T --entrypoint sh backup -c \
    'minisign -G -W -p /tmp/p.pub -s /tmp/s.sec >/dev/null 2>&1 \
       && cat /tmp/s.sec && echo "%%SPLIT%%" && cat /tmp/p.pub' \
    > "${WORK}/minisign.combined"
  sed '/%%SPLIT%%/,$d' "${WORK}/minisign.combined" > "$1"
  sed -n '/%%SPLIT%%/,$p' "${WORK}/minisign.combined" | tail -n +2 > "$2"
  rm -f "${WORK}/minisign.combined"
  chmod 600 "$1"
  [ -s "$1" ] && [ -s "$2" ] || fail "could not generate a minisign key pair"
}

# The `RW...` line of a minisign public key file, which is what
# TRITRACK_BACKUP_VERIFY_KEY takes.
pubkey_line() { grep -v '^untrusted comment' "$1" | sed -n 1p; }

# Signs a file already sitting in the backup directory, as the backup job
# would have. Used to hand the DAMAGED archives below a valid signature, so
# that they still exercise the checksum and decrypt gates further down instead
# of all stopping at the new origin gate and leaving those untested.
#
# **The major defaults to EXPECTED_MAJOR — this build's `schemaMajorVersion` —
# and must never default to a literal again (task 11.310).** It said `2` from
# task 10.43 onward. That was harmless while `backup.sh` also wrote a stale 2
# into every sidecar; task 11.242 made `backup.sh` read the constant, so from
# then on a damaged copy of the real archive carried a sidecar saying 5 and a
# signature saying 2, and restore.sh refused it at the sidecar-versus-signature
# check. **7e then failed with "refused, but not at the decrypt verification"
# — the drill's own warning about cases that short-circuit at a newer check —
# and G-3 (a truncated archive must be stopped before the live database is
# dropped) went untested.** A damaged archive has to differ from a real one in
# the damage and nothing else, or it tests whichever check notices the other
# difference first.
sign_archive() { # <basename under /backups> [schema-major] [secret-key-in-container]
  local major="${2:-$EXPECTED_MAJOR}"
  [ -n "$major" ] || fail "sign_archive was given no schema major for $1"
  local key="${3:-/signing/key.sec}"
  "${COMPOSE[@]}" --profile backup run --rm --no-deps -T \
    -e DRILL_FILE="$1" -e DRILL_KEY="$key" -e DRILL_MAJOR="$major" \
    -v "${WORK}:/forge:ro" --entrypoint sh backup -c '
      f="/backups/$DRILL_FILE"
      s="$(sha256sum "$f" | sed "s/ .*//")"
      minisign -S -H -s "$DRILL_KEY" -m "$f" -x "$f.minisig" \
        -c "drill" \
        -t "tritrack-backup v1 archive=$DRILL_FILE sha256=$s schema_major=$DRILL_MAJOR schema_version=6"
    ' >/dev/null 2>&1 || fail "could not sign $1 with $key"
}

# --- 1. A real stack, with the real schema ---------------------------------
step "0. The shipped compose file decides who the backup container is"
# Task 11.70, and the reason the rest of this drill is evidence about a real
# deployment rather than only about itself.
#
# **This check is what makes the removal of `--user` safe.** If somebody
# deletes the `user:` line from docker-compose.yml, every container in this
# drill silently becomes uid 70 again; on a Linux host the drill then fails at
# step 4 with a message about pg_dump, and on a Mac it passes and says nothing.
# Asking here, by name, is the difference between those two.
#
# Measured by asking a container who it is, rather than by rendering the
# configuration and reading a line: "which user does this container run as" is
# the property, and a `user:` key is a description of it. Asking the container
# also makes this check host-independent — on a Mac, Docker Desktop's
# ownership remapping hides a wrong uid from every other check in this file,
# and `id -u` still reports it.
#
# Task 11.88: build the image FIRST, on its own, with its own build log going
# to /dev/null. A fresh checkout has no cached `backup` image, and
# `docker compose run` builds one implicitly when it is missing — that build's
# own progress text lands on the same stdout this command substitution reads,
# ahead of the printf's actual output, and gets captured as part of
# $DRILL_COMPOSE_USER. That made this check FAIL on a real Linux runner even
# though the reported uid:gid was, byte for byte, the value that was expected
# — an instrument false negative, not the uid:gid mismatch it looked like.
"${COMPOSE[@]}" --profile backup build backup >/dev/null
DRILL_COMPOSE_USER="$(
  "${COMPOSE[@]}" --profile backup run --rm --no-deps -T --entrypoint sh backup \
    -c 'printf "%s:%s" "$(id -u)" "$(id -g)"'
)"
if [ "$DRILL_COMPOSE_USER" != "${TRITRACK_BACKUP_UID}:${TRITRACK_BACKUP_GID}" ]; then
  fail "the backup container runs as '$DRILL_COMPOSE_USER', but this drill runs
  as ${TRITRACK_BACKUP_UID}:${TRITRACK_BACKUP_GID} and owns every directory it
  mounts. The likely cause is that docker-compose.yml's backup service has
  lost its \`user:\` line, leaving the container as the image's own uid 70 —
  which on a Linux host can neither create a file in the operator's backups/
  directory nor read the mode-600 signing key, and which backup.sh used to
  report as a pg_dump failure. This drill deliberately does NOT pass --user,
  so that it measures the shipped mechanism rather than one of its own."
fi
pass "the shipped compose file runs the backup container as $DRILL_COMPOSE_USER, the invoking user"

step "1. Bringing up a throwaway stack and letting the server build the schema"
"${COMPOSE[@]}" up -d --build postgres server >/dev/null
# The probe is the subject: this asks the server, over the network, on the port
# it is supposed to answer on. What it did not do until task 11.176 was say
# what the last attempt got — and "connection refused" and "500 from a server
# that is up" are different problems with different next steps.
if ! wait_for 60 1 -- curl -fsS "http://127.0.0.1:${SERVER_PORT}/health"; then
  "${COMPOSE[@]}" logs --tail 40 server || true
  fail "server never became healthy on http://127.0.0.1:${SERVER_PORT}/health.
  Its last 40 log lines are above. $(wait_for_evidence)"
fi
# Built already, above, before step 0's check needed the image to exist.
TABLES_BEFORE="$(psql_drill "$POSTGRES_DB" \
  -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'" | tr -d '[:space:]')"
[ "${TABLES_BEFORE:-0}" -gt 10 ] || fail "schema looks empty (${TABLES_BEFORE} tables)"
pass "server bootstrapped ${TABLES_BEFORE} tables"

# --- 2. Seed rows that matter ----------------------------------------------
step "2. Seeding a project, a user and an observation with real coordinates"
psql_drill "$POSTGRES_DB" -c "
  INSERT INTO \"Users\" (user_id, first_name, last_name, email,
      created_at, updated_at, revision)
    VALUES ('drill-user', 'Drill', 'Canary', 'drill@example.invalid',
      '2026-08-09T00:00:00Z', '2026-08-09T00:00:00Z', 1);
  INSERT INTO \"Projects\" (project_id, project_name, owner_user_id,
      creation_date, datum, coordinate_format, triangulation_window_minutes,
      created_at, updated_at, revision)
    VALUES ('drill-project', 'Drill Project', 'drill-user',
      '2026-08-09', 'WGS84', 'decimal_degrees', 30,
      '2026-08-09T00:00:00Z', '2026-08-09T00:00:00Z', 1);
  INSERT INTO \"Observations\" (observation_id, project_id, user_id,
      timestamp_local, timestamp_utc, timezone_offset,
      latitude, longitude, position_source, elevation, altitude_agl,
      observation_type, signal_type, signal_strength, notes,
      created_at, updated_at, revision)
    VALUES ('drill-observation', 'drill-project', 'drill-user',
      '2026-08-09T10:00:00', '2026-08-09T17:00:00Z', '-07:00',
      ${CANARY_LAT}, ${CANARY_LON}, 'gps', 2100.0, 1.5,
      'bearing', 'pulse', 'strong', '${CANARY_NOTE}',
      '2026-08-09T00:00:00Z', '2026-08-09T00:00:00Z', 1);
" >/dev/null
pass "seeded ${CANARY_LAT}, ${CANARY_LON}"

# --- 3. Refuses with no recipients -----------------------------------------
step "3. Backup with no recipients configured must refuse"
if TRITRACK_BACKUP_RECIPIENTS="" "${COMPOSE[@]}" --profile backup run --rm \
    backup tritrack-backup >"${WORK}/norecip.log" 2>&1; then
  fail "backup succeeded with TRITRACK_BACKUP_RECIPIENTS empty — §4.9 says there is no unencrypted path"
fi
grep -q "TRITRACK_BACKUP_RECIPIENTS is empty" "${WORK}/norecip.log" \
  || fail "refused, but not for the stated reason: $(cat "${WORK}/norecip.log")"
[ -z "$(ls -A "$TRITRACK_BACKUP_DIR")" ] || fail "refused but still left files in the backup directory"
pass "refused, wrote nothing"

# --- 4. Take a backup -------------------------------------------------------
step "4. Generating a throwaway key pair and taking an encrypted backup"
"${COMPOSE[@]}" --profile backup run --rm --no-deps -T --entrypoint age-keygen backup \
  2>/dev/null > "${WORK}/identity.txt"
chmod 600 "${WORK}/identity.txt"
RECIPIENT="$(grep 'public key:' "${WORK}/identity.txt" | sed 's/.*: //')"
[ -n "$RECIPIENT" ] || fail "could not derive a recipient from the generated identity"

# A second, unrelated key — the "wrong key" in step 6.
"${COMPOSE[@]}" --profile backup run --rm --no-deps -T --entrypoint age-keygen backup \
  2>/dev/null > "${WORK}/other-identity.txt"
chmod 600 "${WORK}/other-identity.txt"
OTHER_RECIPIENT="$(grep 'public key:' "${WORK}/other-identity.txt" | sed 's/.*: //')"
[ -n "$OTHER_RECIPIENT" ] || fail "could not derive a recipient from the second identity"

# --- 4b. The signing key pair (task 10.43 / §4.9.2) ------------------------
#
# Two pairs, and the second is the whole point. The trusted one stands in for
# the operator's backup box; the UNTRUSTED one stands in for anybody else who
# can produce a well-formed signature — because "carries a signature" and
# "carries a signature by a key this operator trusts" are different claims,
# and a check that accepts any signature at all is worth nothing.
gen_minisign "${WORK}/sign.sec" "${WORK}/verify.pub"
gen_minisign "${WORK}/untrusted-sign.sec" "${WORK}/untrusted-verify.pub"
export TRITRACK_BACKUP_SIGNING_KEY="${WORK}/sign.sec"
export TRITRACK_BACKUP_VERIFY_KEY="$(pubkey_line "${WORK}/verify.pub")"
UNTRUSTED_KEY_LINE="$(pubkey_line "${WORK}/untrusted-verify.pub")"
[ -n "$TRITRACK_BACKUP_VERIFY_KEY" ] || fail "could not read the verifying key line"
[ "$TRITRACK_BACKUP_VERIFY_KEY" != "$UNTRUSTED_KEY_LINE" ] \
  || fail "both generated signing keys are identical — the untrusted case would be vacuous"
pass "generated a trusted and an untrusted minisign key pair"

export TRITRACK_BACKUP_RECIPIENTS="$RECIPIENT"
"${COMPOSE[@]}" --profile backup run --rm --no-deps backup tritrack-backup
ARCHIVE="$(ls -1 "$TRITRACK_BACKUP_DIR"/tritrack-*.age | sed -n 1p)"
[ -f "$ARCHIVE" ] || fail "no archive produced"
pass "wrote $(basename "$ARCHIVE")"

# --- 5. It is ciphertext ----------------------------------------------------
step "5. Checking the archive is ciphertext and leaks nothing"
head -c 21 "$ARCHIVE" | grep 'age-encryption.org' >/dev/null || fail "archive has no age header"
pass "carries an age header"
for needle in "$CANARY_LAT" "$CANARY_LON" "$CANARY_NOTE" "drill@example.invalid" "Drill Project"; do
  if LC_ALL=C grep -a -q -- "$needle" "$ARCHIVE"; then
    fail "'${needle}' appears in the archive in the clear"
  fi
done
pass "no seeded coordinate, email, name or note appears in the clear"
[ -f "${ARCHIVE}.sha256" ] || fail "no checksum written beside the archive"
(cd "$TRITRACK_BACKUP_DIR" && shasum -a 256 -c "$(basename "$ARCHIVE").sha256" >/dev/null) \
  || fail "recorded checksum does not match the archive"
pass "checksum recorded and verifies"

# --- 5b. The schema marker is readable without the key (task 10.36) --------
step "5b. Checking the schema-version marker is readable without the key"
[ -f "${ARCHIVE}.schema" ] || fail "no .schema sidecar written beside the archive"
grep -q "^schema_major=${EXPECTED_MAJOR}\$" "${ARCHIVE}.schema" \
  || fail "sidecar does not record the current build's schema major (${EXPECTED_MAJOR}): $(cat "${ARCHIVE}.schema")"
pass "sidecar readable in the clear and names schema major ${EXPECTED_MAJOR}"

# --- 5c. The archive is signed, and by the right key (task 10.43) ----------
step "5c. Checking the archive carries a signature from the trusted signing key"
[ -f "${ARCHIVE}.minisig" ] || fail "no .minisig written beside the archive — H-6's fix is not running"
verify_with() { # <public-key-line> <archive-path>
  "${COMPOSE[@]}" --profile backup run --rm --no-deps -T -e DRILL_PUB="$1" \
    -e DRILL_FILE="$(basename "$2")" --entrypoint sh backup -c \
    'minisign -V -Q -P "$DRILL_PUB" -m "/backups/$DRILL_FILE" \
       -x "/backups/$DRILL_FILE.minisig"' 2>/dev/null
}
SIGNED_COMMENT="$(verify_with "$TRITRACK_BACKUP_VERIFY_KEY" "$ARCHIVE" || true)"
[ -n "$SIGNED_COMMENT" ] || fail "the archive's signature does not verify against the signing key that wrote it"
# The trusted comment is what binds the checksum and the schema marker to the
# signature, so the sidecars stop being independently forgeable. If it were
# empty or missing a field, restore.sh would silently fall back to the
# attacker-writable sidecars, which is H-6 with an extra step.
grep -qE "schema_major=${EXPECTED_MAJOR}( |\$)" <<<"$SIGNED_COMMENT" \
  || fail "the signed trusted comment does not carry the schema major (${EXPECTED_MAJOR}): $SIGNED_COMMENT"
ARCHIVE_SHA="$(shasum -a 256 "$ARCHIVE" | sed 's/ .*//')"
grep -q "sha256=${ARCHIVE_SHA}" <<<"$SIGNED_COMMENT" \
  || fail "the signed trusted comment does not carry this archive's checksum: $SIGNED_COMMENT"
pass "signature verifies and its signed comment binds the checksum and schema major"
if verify_with "$UNTRUSTED_KEY_LINE" "$ARCHIVE" >/dev/null 2>&1; then
  fail "an unrelated minisign public key verified the archive's signature"
fi
pass "an unrelated signing key does not verify it"

# --- 6. The wrong key cannot read it ---------------------------------------
step "6. A different private key must not decrypt it"
try_restore "$(basename "$ARCHIVE")" "drill_wrongkey" "${WORK}/other-identity.txt"
[ "$RESTORE_STATUS" != "0" ] || fail "an unrelated key decrypted the archive"
# Insist on the *reason*. This used to accept any non-zero exit, which a
# missing archive or an unmountable key would also produce — a check that can
# pass without the control it names ever running (task 10.37).
grep -qi "no identity matched" "${WORK}/restore.log" \
  || fail "refused, but not because the key did not match: $(cat "${WORK}/restore.log")"
pass "refused: age reports no identity matched any of the recipients"

# --- 7. The right key restores, and the data matches ------------------------
step "7. Restoring with the correct key into a fresh database"
TRITRACK_RESTORE_ARCHIVE="$(basename "$ARCHIVE")" \
TRITRACK_RESTORE_TARGET_DB="drill_restored" \
TRITRACK_RESTORE_IDENTITY="${WORK}/identity.txt" \
  "${COMPOSE[@]}" --profile backup run --rm --no-deps backup tritrack-restore

TABLES_AFTER="$(psql_drill drill_restored \
  -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'" | tr -d '[:space:]')"
[ "$TABLES_AFTER" = "$TABLES_BEFORE" ] \
  || fail "restored database has ${TABLES_AFTER} tables, original had ${TABLES_BEFORE}"
pass "table count matches (${TABLES_AFTER})"

# Compare every table's shape and every row's contents, not just the canary.
# A restore that brings back three known rows and silently drops a column is
# the failure this is looking for.
COLUMNS_SQL="SELECT table_name||'.'||column_name||':'||data_type
  FROM information_schema.columns WHERE table_schema='public' ORDER BY 1"
psql_drill "$POSTGRES_DB" -c "$COLUMNS_SQL" > "${WORK}/columns.before"
psql_drill drill_restored -c "$COLUMNS_SQL" > "${WORK}/columns.after"
diff -u "${WORK}/columns.before" "${WORK}/columns.after" \
  || fail "column definitions differ between the original and the restore"
pass "every column of every table matches, by name and type"

ROW_SQL="SELECT observation_id, latitude, longitude, notes FROM \"Observations\" ORDER BY 1"
psql_drill "$POSTGRES_DB" -c "$ROW_SQL" > "${WORK}/rows.before"
psql_drill drill_restored -c "$ROW_SQL" > "${WORK}/rows.after"
diff -u "${WORK}/rows.before" "${WORK}/rows.after" \
  || fail "observation rows differ between the original and the restore"
grep -q "$CANARY_LAT" "${WORK}/rows.after" || fail "the seeded coordinate did not come back"
pass "the seeded observation came back byte-identical, coordinates included"

# Task 11.58. The one table a restore must NOT bring back as it was: the
# identifier that tells every device which database answered. The original
# holds exactly one (the server minted it at step 1); the restore must hold
# none, so the server mints a new one on its next start and every device
# that synced against the original starts its sync over instead of asking a
# restored database for "anything after" a number it has never reached.
# Checked as an outcome: backup.sh leaves the row out of the archive and
# restore.sh empties the table, and this passes if the pair works, which is
# the claim. server/lib/src/sync/database_identity.dart is the reasoning.
IDENTITY_SQL="SELECT count(*) FROM server_database_identity"
[ "$(psql_drill "$POSTGRES_DB" -c "$IDENTITY_SQL" | tr -d '[:space:]')" = "1" ] \
  || fail "the original database holds no database identifier — the server did not mint one at step 1"
[ "$(psql_drill drill_restored -c "$IDENTITY_SQL" | tr -d '[:space:]')" = "0" ] \
  || fail "the restored database kept the original's database identifier, so devices could not tell it was restored"
pass "the restore did not inherit the original's database identifier"

# --- 7b. A pre-marker (legacy) archive still restores (tasks 10.36, 10.43) --
#
# A copy with neither sidecar nor signature — which is what every archive
# written before task 10.43 looks like. Two things have to be true at once:
# it must NOT restore by default (that is H-6), and it must still be
# recoverable once an operator says so (that is not stranding six months of
# history because a control arrived late).
step "7b. An archive with no .schema sidecar must still restore (task 10.36)"
LEGACY="${TRITRACK_BACKUP_DIR}/$(basename "$ARCHIVE" .age)-legacy.age"
cp "$ARCHIVE" "$LEGACY"
try_restore "$(basename "$LEGACY")" "drill_legacy_refused" "${WORK}/identity.txt"
[ "$RESTORE_STATUS" != "0" ] || fail "an unsigned archive restored with no acknowledgement — H-6's gate is not running"
grep -q "origin cannot be verified" "${WORK}/restore.log" \
  || fail "refused, but not for the missing signature: $(cat "${WORK}/restore.log")"
pass "an unsigned archive is refused by default, naming the origin"

try_restore "$(basename "$LEGACY")" "drill_legacy" "${WORK}/identity.txt" "" \
  I_ACCEPT_UNVERIFIED_ORIGIN
[ "$RESTORE_STATUS" = "0" ] \
  || fail "a missing sidecar was treated as unreadable rather than schema major 1: $(cat "${WORK}/restore.log")"
grep -q "treating archive as schema major 1" "${WORK}/restore.log" \
  || fail "no missing-marker note logged: $(cat "${WORK}/restore.log")"
grep -q "UNVERIFIED origin" "${WORK}/restore.log" \
  || fail "restored an unverified archive without saying so: $(cat "${WORK}/restore.log")"
pass "a marker-less archive is treated as schema major 1 and still restores, loudly"

# --- 7c. A major this build cannot read must refuse (tasks 10.36, 10.43) ---
#
# Signed with major 99 in the trusted comment rather than only in the sidecar,
# because after 10.43 the signed value is the one restore.sh decides on — the
# sidecar is what H-6's attacker wrote.
step "7c. A schema major outside this build's supported range must refuse (task 10.36)"
TOOFAR="${TRITRACK_BACKUP_DIR}/$(basename "$ARCHIVE" .age)-toofar.age"
cp "$ARCHIVE" "$TOOFAR"
printf 'schema_major=99\nschema_version=99\n' > "${TOOFAR}.schema"
sign_archive "$(basename "$TOOFAR")" 99
try_restore "$(basename "$TOOFAR")" "drill_toofar" "${WORK}/identity.txt"
[ "$RESTORE_STATUS" != "0" ] || fail "restore succeeded for a schema major this build does not support"
grep -q "schema major 99" "${WORK}/restore.log" || fail "refusal did not name the archive's major: $(cat "${WORK}/restore.log")"
grep -q "supports major 1 through ${EXPECTED_MAJOR}" "${WORK}/restore.log" || fail "refusal did not name the supported range: $(cat "${WORK}/restore.log")"
pass "refused, naming both the archive's major and the build's supported range"

# --- 7c2. A rewritten sidecar is caught by the signature (task 10.43) ------
#
# The signature says one major, the cleartext sidecar says another. Before
# 10.43 the sidecar was the only opinion in the room and it was writable by
# anyone with access to the directory.
step "7c2. A .schema sidecar that disagrees with the signature must refuse"
printf 'schema_major=2\nschema_version=6\n' > "${TOOFAR}.schema"
try_restore "$(basename "$TOOFAR")" "drill_sidecar" "${WORK}/identity.txt"
[ "$RESTORE_STATUS" != "0" ] || fail "a rewritten .schema sidecar was accepted over the signed value"
grep -q "sidecar has been rewritten" "${WORK}/restore.log" \
  || fail "refused, but not because the sidecar contradicts the signature: $(cat "${WORK}/restore.log")"
pass "a sidecar contradicting the signature is refused, and named as rewritten"
rm -f "$LEGACY" "$TOOFAR" "${TOOFAR}.schema" "${TOOFAR}.minisig"

# --- 7d-7g. The replace path, the only one that can destroy data -----------
#
# Finding G-3, task 10.37. Everything above restores into a name nobody was
# using, which is the safe half of §4.9 and the only half this drill used to
# cover. These four cases type TRITRACK_RESTORE_REPLACE=I_UNDERSTAND against
# the LIVE database, holding the only copy of the seeded observation, and ask
# the one question an operator cares about mid-incident: after a restore that
# went wrong, is the data still there?
#
# The server is stopped first, which is what an operator recovering in place
# does and is also the strictly harder test: leaving it running makes Postgres
# refuse the rename because sessions are attached, which looks like a control
# and is not one.
step "7d-7g. The in-place replace path must never destroy live data (task 10.37)"
"${COMPOSE[@]}" stop server >/dev/null 2>&1
echo "  stopped the server (an operator restoring in place does this first)"
[ "$(live_canary)" = "1" ] || fail "the live canary was already gone before the replace cases ran"

# Three archives, three ways a restore goes wrong in the field.
#
# Named outside the tritrack-*.age pattern on purpose: step 9 counts archives
# and their checksums to prove retention prunes the oldest, and a stray file
# matching that glob would make it assert the wrong thing.
BADSUM="${TRITRACK_BACKUP_DIR}/badsum.age"      # damaged, and the .sha256 says so
TRUNCATED="${TRITRACK_BACKUP_DIR}/truncated.age" # damaged, with no .sha256 to catch it
WRONGKEY="${TRITRACK_BACKUP_DIR}/wrongkey.age"   # intact, but not ours to read

FULL_BYTES="$(wc -c <"$ARCHIVE" | tr -d '[:space:]')"
head -c "$(( FULL_BYTES / 3 ))" "$ARCHIVE" > "$TRUNCATED"
cp "${ARCHIVE}.schema" "${TRUNCATED}.schema"
cp "$TRUNCATED" "$BADSUM"
cp "${ARCHIVE}.schema" "${BADSUM}.schema"
# The checksum the good archive was written with, pointed at the damaged copy —
# exactly what an archive that rotted in transit looks like on arrival.
sed "s#$(basename "$ARCHIVE")#$(basename "$BADSUM")#" "${ARCHIVE}.sha256" > "${BADSUM}.sha256"
# Each damaged copy gets a VALID signature over its own damaged bytes (task
# 10.43). Not because that is what damage looks like in the field, but because
# without it all three cases below would stop at the new origin gate and the
# gates they were written for — the recorded checksum, and G-3's decrypt-to-the
# -end check — would go untested behind a control that happens to fire first.
# A drill whose cases all short-circuit at the newest check is a drill that
# only tests the newest check.
sign_archive "$(basename "$TRUNCATED")"
sign_archive "$(basename "$BADSUM")"

# An archive encrypted to a key we do not hold: §4.9.1's "wrong holder's
# identity" case, which is a real incident scenario and not a corruption one.
sleep 1  # archive names are second-resolution; a collision refuses by design
# This was the one call site task 11.69's first pass missed its `--user` on,
# and it is why this drill was still red on the second CI run after the other
# nine were fixed. Nothing is special about it now: the user comes from the
# compose file for every run in this script, which is the point of task 11.70.
TRITRACK_BACKUP_RECIPIENTS="$OTHER_RECIPIENT" "${COMPOSE[@]}" --profile backup \
  run --rm --no-deps backup tritrack-backup >/dev/null
FOREIGN="$(ls -1 "$TRITRACK_BACKUP_DIR"/tritrack-*.age | grep -v "$(basename "$ARCHIVE")" | sed -n 1p)"
[ -n "$FOREIGN" ] || fail "could not produce an archive encrypted to the other key"
mv "$FOREIGN" "$WRONGKEY"
mv "${FOREIGN}.schema" "${WRONGKEY}.schema"
mv "${FOREIGN}.minisig" "${WRONGKEY}.minisig"
rm -f "${FOREIGN}.sha256"

# 7d. Caught by the recorded checksum, before the key is even touched.
try_restore "$(basename "$BADSUM")" "$POSTGRES_DB" "${WORK}/identity.txt" I_UNDERSTAND
[ "$RESTORE_STATUS" != "0" ] || fail "a restore from a checksum-mismatched archive reported success"
grep -q "checksum mismatch" "${WORK}/restore.log" \
  || fail "refused, but not for the checksum: $(cat "${WORK}/restore.log")"
[ "$(live_canary)" = "1" ] || fail "DATA LOST — the live canary is gone after a checksum-mismatched restore"
pass "a damaged archive is caught by its checksum; live data untouched"

# 7e. No checksum to catch it, so this one has to reach the decrypt and be
# stopped there — the case that reproduced as G-3.
try_restore "$(basename "$TRUNCATED")" "$POSTGRES_DB" "${WORK}/identity.txt" I_UNDERSTAND
[ "$RESTORE_STATUS" != "0" ] || fail "a restore from a truncated archive reported success"
grep -q "did not decrypt to a complete database dump" "${WORK}/restore.log" \
  || fail "refused, but not at the decrypt verification: $(cat "${WORK}/restore.log")"
if grep -q "Dropping existing database" "${WORK}/restore.log"; then
  fail "the restore dropped the live database — G-3 has regressed"
fi
[ "$(live_canary)" = "1" ] || fail "DATA LOST — the live canary is gone after a truncated restore (G-3 has regressed)"
pass "a truncated archive is stopped at the decrypt; live data untouched"

# 7f. The archive is perfectly intact. We simply cannot read it, and that has
# to be discovered before anything is renamed.
try_restore "$(basename "$WRONGKEY")" "$POSTGRES_DB" "${WORK}/identity.txt" I_UNDERSTAND
[ "$RESTORE_STATUS" != "0" ] || fail "the wrong key restored over the live database"
grep -q "no identity matched" "${WORK}/restore.log" \
  || fail "refused, but age did not report an identity mismatch: $(cat "${WORK}/restore.log")"
[ "$(live_canary)" = "1" ] || fail "DATA LOST — the live canary is gone after a wrong-key restore"
pass "the wrong holder's key is refused before the swap; live data untouched"

# 7g. And the path has to actually work, or the two cases above are satisfied
# by a script that refuses everything.
try_restore "$(basename "$ARCHIVE")" "$POSTGRES_DB" "${WORK}/identity.txt" I_UNDERSTAND
[ "$RESTORE_STATUS" = "0" ] \
  || fail "the in-place replace failed with a good archive: $(cat "${WORK}/restore.log")"
[ "$(live_canary)" = "1" ] || fail "the in-place replace succeeded but the observation did not come back"
DISPLACED="$(psql_drill postgres -c \
  "SELECT datname FROM pg_database WHERE datname LIKE '${POSTGRES_DB}\_replaced\_%'" | tr -d '[:space:]')"
[ -n "$DISPLACED" ] \
  || fail "the replaced database was dropped rather than renamed aside — the whole point of 10.37"
[ "$(psql_drill "$DISPLACED" -c \
  "SELECT count(*) FROM \"Observations\" WHERE observation_id = 'drill-observation'" \
  | tr -d '[:space:]')" = "1" ] \
  || fail "the displaced database '$DISPLACED' does not hold the data it replaced"
LEFTOVER="$(psql_drill postgres -c \
  "SELECT count(*) FROM pg_database WHERE datname LIKE '${POSTGRES_DB}\_restore\_%'" | tr -d '[:space:]')"
[ "$LEFTOVER" = "0" ] || fail "${LEFTOVER} staging database(s) were left behind"
pass "a good archive replaces in place, and the database it replaced is kept as '$DISPLACED'"

rm -f "$BADSUM" "${BADSUM}.schema" "${BADSUM}.sha256" "${BADSUM}.minisig" \
      "$TRUNCATED" "${TRUNCATED}.schema" "${TRUNCATED}.minisig" \
      "$WRONGKEY" "${WRONGKEY}.schema" "${WRONGKEY}.minisig"

# --- 7h-7j. A FORGED archive (task 10.43, finding H-6) ---------------------
#
# The case none of 7d-7g was. Every one of those is an accident: a file that
# rotted, a file cut short, the wrong holder's key. This one is a genuine,
# valid, complete archive that the operator's own private key decrypts
# perfectly — authored by someone who has never held that key and never will.
#
# The attacker's entire position is the PUBLIC recipient string, which §4.9.1
# says out loud may appear "in documentation, tickets, or a commit", plus the
# ability to create a file in the archive directory — which is the off-site
# copy, the sync target, and the incident-time "fetch another copy". §4.9
# decided who may READ an archive. Until 10.43 nothing anywhere decided who
# may WRITE one that the restore path will trust.
step "7h-7j. A forged archive must never be promoted over the live database (H-6)"
[ "$(live_canary)" = "1" ] || fail "the live canary was gone before the forgery cases ran"

cat > "${WORK}/forged.sql" <<'SQL'
-- PostgreSQL database dump
SET client_encoding = 'UTF8';
CREATE TABLE "Observations" (observation_id TEXT PRIMARY KEY, latitude NUMERIC,
  longitude NUMERIC, notes TEXT);
INSERT INTO "Observations" VALUES
  ('drill-FORGED-observation', 0.0, 0.0, 'planted by an entity that cannot read a backup');
CREATE TABLE forged_marker (note TEXT);
INSERT INTO forged_marker VALUES ('this SQL ran as the postgres superuser');
-- PostgreSQL database dump complete
SQL
FORGED="forged.age"
# Encrypted with the PUBLIC recipient. No private key is used, held or needed.
"${COMPOSE[@]}" --profile backup run --rm --no-deps -T -v "${WORK}:/forge:ro" \
  -e DRILL_RECIPIENT="$RECIPIENT" -e DRILL_OUT="$FORGED" --entrypoint sh backup -c \
  'age -r "$DRILL_RECIPIENT" -o "/backups/$DRILL_OUT" /forge/forged.sql' >/dev/null
[ -f "${TRITRACK_BACKUP_DIR}/${FORGED}" ] || fail "could not write the forged archive"
# Both cleartext sidecars, both authored by the attacker, both satisfying the
# checks that existed before this task.
(cd "$TRITRACK_BACKUP_DIR" && shasum -a 256 "$FORGED" > "${FORGED}.sha256")
# The current major, as a real archive's sidecar would say (task 11.310): a
# forgery that differs from a genuine archive only in its origin is the one
# worth refusing. These cases stop at the origin check, before restore.sh
# reads any major, so the old literal 2 was not failing them — it was one more
# copy of the number waiting for SCHEMA_MIN to pass it.
printf 'schema_major=%s\nschema_version=6\n' "$EXPECTED_MAJOR" > "${TRITRACK_BACKUP_DIR}/${FORGED}.schema"

# 7h. The operator HAS configured a verifying key. The forgery carries no
#     signature at all, which is the honest attacker position: they cannot
#     make one.
try_restore "$FORGED" "$POSTGRES_DB" "${WORK}/identity.txt" I_UNDERSTAND
[ "$RESTORE_STATUS" != "0" ] || fail "H-6 REPRODUCES — a forged archive was restored over the live database"
grep -q "unverified origin OVER an existing" "${WORK}/restore.log" \
  || fail "refused, but not because the origin was unverified: $(cat "${WORK}/restore.log")"
[ "$(live_canary)" = "1" ] || fail "DATA LOST — the live canary is gone after a forged restore"
pass "a forged archive is refused before anything is renamed; live data untouched"

# 7i. The operator has NOT configured a verifying key — the state every
#     existing deployment starts in, and the one an attacker would rather find.
#     The refusal has to hold here too, or the control is opt-in against an
#     adversary who is not opting in.
try_restore "$FORGED" "$POSTGRES_DB" "${WORK}/identity.txt" I_UNDERSTAND "" "" ""
[ "$RESTORE_STATUS" != "0" ] || fail "H-6 REPRODUCES with no verifying key configured"
[ "$(live_canary)" = "1" ] || fail "DATA LOST — the live canary is gone after a forged restore"
pass "still refused with no verifying key configured at all"

# 7j. And the unsigned escape hatch does not open this door either: it permits
#     a NEW name, never a replace. If these two flags together could promote an
#     unattributable archive, H-6 would be closed by a sentence in a README.
try_restore "$FORGED" "$POSTGRES_DB" "${WORK}/identity.txt" I_UNDERSTAND \
  I_ACCEPT_UNVERIFIED_ORIGIN
[ "$RESTORE_STATUS" != "0" ] || fail "TRITRACK_RESTORE_UNSIGNED re-opened the in-place path for a forgery"
[ "$(live_canary)" = "1" ] || fail "DATA LOST — the live canary is gone after a forged restore"
pass "TRITRACK_RESTORE_UNSIGNED does not re-open the in-place path"

# 7j2. A signature from a key the operator does not trust is worse than none,
#      and is refused unconditionally — there is no flag for it, because
#      "signed by somebody" is not a property anyone asked for.
sign_archive "$FORGED" "$EXPECTED_MAJOR" /forge/untrusted-sign.sec
try_restore "$FORGED" "drill_untrusted" "${WORK}/identity.txt" "" I_ACCEPT_UNVERIFIED_ORIGIN
[ "$RESTORE_STATUS" != "0" ] || fail "an archive signed by an untrusted key was accepted"
grep -q "does NOT verify against any key" "${WORK}/restore.log" \
  || fail "refused, but not because the signature is untrusted: $(cat "${WORK}/restore.log")"
pass "a signature from an untrusted key is refused, and the unsigned flag cannot override it"

# 7j3. Substitution: keep the genuine archive's signature, swap the bytes
#      underneath it. This is what an attacker who has watched a real backup
#      land in the directory would try.
cp "${ARCHIVE}.minisig" "${TRITRACK_BACKUP_DIR}/${FORGED}.minisig"
try_restore "$FORGED" "drill_substituted" "${WORK}/identity.txt" "" I_ACCEPT_UNVERIFIED_ORIGIN
[ "$RESTORE_STATUS" != "0" ] || fail "a genuine signature was accepted over substituted archive bytes"
pass "a genuine signature does not carry over to different bytes"
rm -f "${TRITRACK_BACKUP_DIR}/${FORGED}" "${TRITRACK_BACKUP_DIR}/${FORGED}.sha256" \
      "${TRITRACK_BACKUP_DIR}/${FORGED}.schema" "${TRITRACK_BACKUP_DIR}/${FORGED}.minisig"

# --- 7k-7l. The rollback, which had never run (task 10.43, finding H-9) ----
#
# `restore.sh`'s swap renames the live database aside, promotes the restore,
# and rolls the rename back if the promote fails. That rollback is the code
# protecting an operator from ending up with no target database at all — and
# until this task it had never executed once, because nothing in the drill can
# make a rename fail. Untested recovery code is indistinguishable from absent
# recovery code, which is G-3's own lesson one layer down. TRITRACK_RESTORE_FAULT
# is the seam that makes it reachable; it can only make a rename fail.
step "7k-7l. The swap's rollback must actually run, and must keep both copies (H-9)"
BEFORE_REPLACED="$(psql_drill postgres -c \
  "SELECT count(*) FROM pg_database WHERE datname LIKE '${POSTGRES_DB}\_replaced\_%'" | tr -d '[:space:]')"

# 7k. The promote fails; the rollback succeeds. The operator must end up
#     exactly where they started, with the live database back under its own
#     name and holding its data.
try_restore "$(basename "$ARCHIVE")" "$POSTGRES_DB" "${WORK}/identity.txt" I_UNDERSTAND "" promote
[ "$RESTORE_STATUS" != "0" ] || fail "the injected promote failure did not fail the restore"
grep -q "renamed back and is unchanged" "${WORK}/restore.log" \
  || fail "the rollback path did not report rolling back: $(cat "${WORK}/restore.log")"
[ "$(live_canary)" = "1" ] \
  || fail "DATA LOST — the rollback did not put '$POSTGRES_DB' back after a failed promote"
AFTER_REPLACED="$(psql_drill postgres -c \
  "SELECT count(*) FROM pg_database WHERE datname LIKE '${POSTGRES_DB}\_replaced\_%'" | tr -d '[:space:]')"
[ "$AFTER_REPLACED" = "$BEFORE_REPLACED" ] \
  || fail "a rolled-back restore left a _replaced_ database behind (${BEFORE_REPLACED} -> ${AFTER_REPLACED})"
# And the restore it could not promote is still on disk. Losing it here is
# harmless (the live database came back) but it is the same trap firing, and a
# check that only looks at the happy outcome would not see it.
ROLLED_STAGING="$(psql_drill postgres -c \
  "SELECT datname FROM pg_database WHERE datname LIKE '${POSTGRES_DB}\_restore\_%' ORDER BY datname DESC LIMIT 1" \
  | tr -d '[:space:]')"
[ -n "$ROLLED_STAGING" ] \
  || fail "the verified restore was dropped by the EXIT trap after the promote failed"
grep -q "$ROLLED_STAGING" "${WORK}/restore.log" \
  || fail "the failure message does not name the staging database it kept"
pass "a failed promote rolls back: the live database is back, and the restore is kept and named"
psql_drill postgres -c "DROP DATABASE \"$ROLLED_STAGING\"" >/dev/null

# 7l. The worst case, and the one the EXIT trap used to lose silently: the
#     promote fails AND the rollback fails. `fail` prints manual instructions
#     naming the displaced database — and the trap, armed across the swap,
#     then dropped the fully verified restore on the way out without a word.
#     Both copies must survive, because at this point they are the only two
#     that exist.
try_restore "$(basename "$ARCHIVE")" "$POSTGRES_DB" "${WORK}/identity.txt" I_UNDERSTAND "" promote_and_rollback
[ "$RESTORE_STATUS" != "0" ] || fail "the injected double failure did not fail the restore"
grep -q "could not promote" "${WORK}/restore.log" \
  || fail "the double-failure path did not report it: $(cat "${WORK}/restore.log")"
STRANDED_DISPLACED="$(psql_drill postgres -c \
  "SELECT datname FROM pg_database WHERE datname LIKE '${POSTGRES_DB}\_replaced\_%' ORDER BY datname DESC LIMIT 1" \
  | tr -d '[:space:]')"
[ -n "$STRANDED_DISPLACED" ] || fail "the original database was not left as a _replaced_ copy"
[ "$(psql_drill "$STRANDED_DISPLACED" -c \
  "SELECT count(*) FROM \"Observations\" WHERE observation_id = 'drill-observation'" \
  | tr -d '[:space:]')" = "1" ] \
  || fail "'$STRANDED_DISPLACED' does not hold the data it was renamed aside from"
STRANDED_STAGING="$(psql_drill postgres -c \
  "SELECT datname FROM pg_database WHERE datname LIKE '${POSTGRES_DB}\_restore\_%' ORDER BY datname DESC LIMIT 1" \
  | tr -d '[:space:]')"
[ -n "$STRANDED_STAGING" ] \
  || fail "H-9 REPRODUCES — the EXIT trap dropped the verified restore after the swap failed"
[ "$(psql_drill "$STRANDED_STAGING" -c \
  "SELECT count(*) FROM \"Observations\" WHERE observation_id = 'drill-observation'" \
  | tr -d '[:space:]')" = "1" ] \
  || fail "the surviving staging database '$STRANDED_STAGING' is not the verified restore"
grep -q "$STRANDED_STAGING" "${WORK}/restore.log" \
  || fail "the failure message does not name the staging database it left behind"
pass "a double swap failure keeps BOTH copies and names them; nothing is dropped silently"

# Put the drill back where 7g left it: the original name, holding the canary.
psql_drill postgres -c "ALTER DATABASE \"$STRANDED_DISPLACED\" RENAME TO \"$POSTGRES_DB\"" >/dev/null
psql_drill postgres -c "DROP DATABASE \"$STRANDED_STAGING\"" >/dev/null
[ "$(live_canary)" = "1" ] || fail "could not restore the drill's own state after 7l"

# --- 7m. The staging drop is guarded (task 10.43, finding H-9) -------------
#
# `restore.sh` refused to touch '$TARGET' without an explicit flag, and had no
# equivalent check at all for the '<target>_restore_<stamp>' database it
# creates — while an EXIT trap dropped that name with output suppressed. The
# name is derived from the current UTC second, so colliding with it needs
# either two concurrent restores of the same target or a leftover from an
# interrupted one. Both are real, and neither is what a script gets to assume
# away in a comment.
#
# Forced deterministically by computing the staging names for this second and
# the next two INSIDE the container that then runs the restore, so the
# collision does not depend on how long `docker compose run` takes to start.
step "7m. A staging-name collision must refuse, and drop nothing (H-9)"
GUARD_TARGET="drill_guard"
set +e
TRITRACK_RESTORE_ARCHIVE="$(basename "$ARCHIVE")" \
TRITRACK_RESTORE_TARGET_DB="$GUARD_TARGET" \
TRITRACK_RESTORE_IDENTITY="${WORK}/identity.txt" \
  "${COMPOSE[@]}" --profile backup run --rm --no-deps -T \
    -e PGPASSWORD="$POSTGRES_PASSWORD" -e DRILL_TARGET="$GUARD_TARGET" \
    --entrypoint sh backup -c '
      n=$(date -u +%s)
      for i in 0 1 2 3 4; do
        s=$(date -u -d "@$((n + i))" +%Y%m%dT%H%M%SZ)
        psql --host=postgres --username="$POSTGRES_USER" --dbname=postgres \
          --quiet --no-psqlrc -v ON_ERROR_STOP=1 \
          -c "CREATE DATABASE \"${DRILL_TARGET}_restore_${s}\"" >/dev/null
      done
      exec tritrack-restore
    ' >"${WORK}/guard.log" 2>&1
GUARD_STATUS=$?
set -e
[ "$GUARD_STATUS" != "0" ] \
  || fail "a restore built on top of a staging database it did not create: $(cat "${WORK}/guard.log")"
grep -q "is already taken" "${WORK}/guard.log" \
  || fail "refused, but not because the staging name was taken: $(cat "${WORK}/guard.log")"
PLANTED="$(psql_drill postgres -c \
  "SELECT count(*) FROM pg_database WHERE datname LIKE '${GUARD_TARGET}\_restore\_%'" | tr -d '[:space:]')"
[ "$PLANTED" = "5" ] \
  || fail "the refused restore dropped a staging database it did not create (5 -> ${PLANTED})"
pass "a taken staging name refuses, and none of the 5 planted databases was dropped"
GUARD_LEFTOVERS="$(psql_drill postgres -c \
  "SELECT datname FROM pg_database WHERE datname LIKE '${GUARD_TARGET}\_restore\_%'")"
for db in $GUARD_LEFTOVERS; do
  psql_drill postgres -c "DROP DATABASE \"$db\"" >/dev/null
done

# --- 8. A failing dump leaves nothing --------------------------------------
step "8. A failing pg_dump must leave no archive behind"
BEFORE_COUNT="$(ls -1 "$TRITRACK_BACKUP_DIR"/tritrack-*.age | wc -l | tr -d ' ')"
if POSTGRES_DB="database_that_does_not_exist" \
   "${COMPOSE[@]}" --profile backup run --rm --no-deps backup tritrack-backup \
     >"${WORK}/baddump.log" 2>&1; then
  fail "backup reported success against a nonexistent database"
fi
AFTER_COUNT="$(ls -1 "$TRITRACK_BACKUP_DIR"/tritrack-*.age | wc -l | tr -d ' ')"
[ "$AFTER_COUNT" = "$BEFORE_COUNT" ] \
  || fail "a failed dump left an archive behind (${BEFORE_COUNT} -> ${AFTER_COUNT})"
# L-4 / task 10.95 (L-13): `ls -A .../*.part 2>/dev/null || true` reads
# "I could not look" (a missing directory, or a shell glob that fails to
# match) the same as "confirmed clear" -- reproduced with a control: pointed
# at a nonexistent directory, the old form of this check passed. Assert the
# directory is actually there before trusting an empty result, and use
# `find` rather than an unquoted glob so a no-match is a real empty list
# rather than a literal `*.part` string `ls -A` would otherwise report.
[ -d "$TRITRACK_BACKUP_DIR" ] \
  || fail "TRITRACK_BACKUP_DIR ($TRITRACK_BACKUP_DIR) does not exist -- could not check whether a .part file survived"
SURVIVING_PARTS="$(find "$TRITRACK_BACKUP_DIR" -maxdepth 1 -name '*.part')"
[ -z "$SURVIVING_PARTS" ] \
  || fail "a .part file survived a failed run: $SURVIVING_PARTS"
pass "failed loudly, wrote nothing"

# --- 8b. The shipped default: no verifying key means retention never runs --
step "8b. With TRITRACK_BACKUP_VERIFY_KEY unset, backup succeeds and retention stays inert (task 10.59, I-11)"
# I-11: this is the configuration `docker-compose.yml`/`.env.example` actually
# ship — TRITRACK_BACKUP_VERIFY_KEY is empty by default — and every earlier
# step in this drill deliberately overrides it (4b, above) because the rest of
# the drill needs a signature to check things AGAINST. Nothing else here ever
# exercises the shipped default, which is how a real deployment can run for
# months believing retention is active when it has never once pruned
# anything. One archive in, none pruned, and the backup itself must still
# succeed — retention being unprovable is not a reason to fail the backup.
BEFORE_UNSET_COUNT="$(ls -1 "$TRITRACK_BACKUP_DIR"/tritrack-*.age | wc -l | tr -d ' ')"
if ! TRITRACK_BACKUP_VERIFY_KEY= TRITRACK_BACKUP_KEEP=1 "${COMPOSE[@]}" --profile backup run --rm --no-deps \
    backup tritrack-backup >"${WORK}/no_verify_key.log" 2>&1; then
  fail "backup refused to run at all with no verifying key set: $(cat "${WORK}/no_verify_key.log")"
fi
grep -q "TRITRACK_BACKUP_VERIFY_KEY is not set" "${WORK}/no_verify_key.log" \
  || fail "no NOTE about the missing verifying key: $(cat "${WORK}/no_verify_key.log")"
grep -q "will print again on every scheduled run" "${WORK}/no_verify_key.log" \
  || fail "the NOTE does not say this recurs on every run: $(cat "${WORK}/no_verify_key.log")"
AFTER_UNSET_COUNT="$(ls -1 "$TRITRACK_BACKUP_DIR"/tritrack-*.age | wc -l | tr -d ' ')"
[ "$AFTER_UNSET_COUNT" = "$((BEFORE_UNSET_COUNT + 1))" ] \
  || fail "expected exactly one new archive and no pruning (had $BEFORE_UNSET_COUNT, now $AFTER_UNSET_COUNT)"
pass "backup succeeded, archive count only grew, and the recurring-NOTE warning fired"

# --- 9. Retention keeps the newest, not the oldest --------------------------
step "9. Retention must delete the OLDEST archives and keep the newest"
# The bug this is looking for is an off-by-one or a reversed sort that prunes
# the copy you would actually restore from. It is silent, and it is only
# discovered during a recovery.
for _ in 1 2; do
  sleep 1  # archive names are second-resolution; a collision refuses by design
  TRITRACK_BACKUP_KEEP=2 "${COMPOSE[@]}" --profile backup run --rm --no-deps \
    backup tritrack-backup >/dev/null
done
REMAINING="$(ls -1 "$TRITRACK_BACKUP_DIR"/tritrack-*.age | wc -l | tr -d ' ')"
[ "$REMAINING" = "2" ] || fail "TRITRACK_BACKUP_KEEP=2 left ${REMAINING} archives"
NEWEST="$(ls -1 "$TRITRACK_BACKUP_DIR"/tritrack-*.age | sort | tail -1)"
[ "$(basename "$NEWEST")" != "$(basename "$ARCHIVE")" ] \
  || fail "retention kept the oldest archive and pruned the newest"
[ "$(ls -1 "$TRITRACK_BACKUP_DIR"/*.sha256 | wc -l | tr -d ' ')" = "2" ] \
  || fail "checksum files were not pruned alongside their archives"
[ "$(ls -1 "$TRITRACK_BACKUP_DIR"/*.minisig | wc -l | tr -d ' ')" = "2" ] \
  || fail "signature files were not pruned alongside their archives"
pass "kept the 2 newest archives with their checksums and signatures, pruned the rest"

# --- 10. Retention refuses to prune when it cannot account for a file ------
step "10. Retention refuses to prune ANYTHING when an unverifiable archive is planted (task 10.44, H-7)"
# The reproduction: a write-only attacker (no key, no read access) drops a
# future-dated, unsigned file into the archive directory. The old rule kept
# the KEEP lexically-highest names and deleted the rest — a lexically-highest
# 2999-dated plant would have deleted every genuine archive. Retention must
# now refuse the whole prune instead.
BEFORE_GENUINE="$(ls -1 "$TRITRACK_BACKUP_DIR"/tritrack-*.age | sort)"
[ -n "$BEFORE_GENUINE" ] || fail "no genuine archives on hand before the plant — earlier step left none"
PLANTED="tritrack-29991231T235959Z.age"
printf 'age-encryption.org/v1\nplanted by an entity with write-only access, no key, no read access\n' \
  > "${TRITRACK_BACKUP_DIR}/${PLANTED}"
# Deliberately no .minisig: this is exactly what write-only access can produce
# — it cannot forge a signature over the key that never leaves the backup box.

sleep 1  # archive names are second-resolution; a collision refuses by design
TRITRACK_BACKUP_KEEP=2 "${COMPOSE[@]}" --profile backup run --rm --no-deps \
  backup tritrack-backup >"${WORK}/retention_refuse.log" 2>&1 || true
grep -q "RETENTION REFUSED" "${WORK}/retention_refuse.log" \
  || fail "planting an unverifiable archive did not trigger a loud retention refusal: $(cat "${WORK}/retention_refuse.log")"
grep -q "$PLANTED" "${WORK}/retention_refuse.log" \
  || fail "the refusal did not name the unaccountable file"

for f in $BEFORE_GENUINE; do
  [ -e "$f" ] || fail "retention deleted a genuine archive ($f) instead of refusing to prune"
done
pass "an unverifiable planted archive caused a loud refusal; no genuine archive was pruned"

rm -f "${TRITRACK_BACKUP_DIR}/${PLANTED}"

step "10b. Retention prunes again once the unaccountable file is gone"
sleep 1  # archive names are second-resolution; a collision refuses by design
TRITRACK_BACKUP_KEEP=2 "${COMPOSE[@]}" --profile backup run --rm --no-deps \
  backup tritrack-backup >"${WORK}/retention_resume.log" 2>&1
if grep -q "RETENTION REFUSED" "${WORK}/retention_resume.log"; then
  fail "retention kept refusing after the unaccountable file was removed"
fi
AFTER_PRUNE_COUNT="$(ls -1 "$TRITRACK_BACKUP_DIR"/tritrack-*.age | wc -l | tr -d ' ')"
[ "$AFTER_PRUNE_COUNT" = "2" ] || fail "TRITRACK_BACKUP_KEEP=2 left ${AFTER_PRUNE_COUNT} archives after resuming"
pass "ordinary retention resumed, pruning oldest-first, once nothing was unaccountable"

# --- 10c. Retention refuses a renamed copy of a genuine signed archive -----
step "10c. Retention refuses ANYTHING when a renamed copy of a genuine archive is planted (task 10.53, I-2)"
# A minisign signature covers the archive's BYTES, not the name beside it: copy
# a genuine (archive, .minisig) pair to any other name and the copy verifies
# exactly as well as the original. Step 10 above only ever plants an UNSIGNED
# file, so it cannot exercise this: task 10.44's predicate treated "verifies"
# as "genuine", which means thirty renamed copies of ONE real pair all counted
# as genuine archives to KEEP, and the archives this backup job actually wrote
# — now merely the oldest two names among thirty-two — are exactly what
# oldest-first retention then pruned. This reproduces H-7 through the signed
# path 10.44's own fix was supposed to close.
BEFORE_GENUINE2="$(ls -1 "$TRITRACK_BACKUP_DIR"/tritrack-*.age | sort)"
[ -n "$BEFORE_GENUINE2" ] || fail "no genuine archives on hand before the renamed-copy plant"
SOURCE_ARCHIVE="$(sed -n 1p <<<"$BEFORE_GENUINE2")"
[ -f "${SOURCE_ARCHIVE}.minisig" ] || fail "source archive for the renamed-copy plant has no .minisig"
RENAMED="tritrack-29991231T235959Z.age"
cp "$SOURCE_ARCHIVE" "${TRITRACK_BACKUP_DIR}/${RENAMED}"
cp "${SOURCE_ARCHIVE}.minisig" "${TRITRACK_BACKUP_DIR}/${RENAMED}.minisig"
# Deliberately no .sha256/.schema alongside it: retention never reads those,
# only the .minisig, and the point is that the signature alone verifies under
# the new name. The unsigned-plant, sidecars-and-all case is step 10 above.

sleep 1  # archive names are second-resolution; a collision refuses by design
TRITRACK_BACKUP_KEEP=2 "${COMPOSE[@]}" --profile backup run --rm --no-deps \
  backup tritrack-backup >"${WORK}/retention_refuse_renamed.log" 2>&1 || true
grep -q "RETENTION REFUSED" "${WORK}/retention_refuse_renamed.log" \
  || fail "a signed-but-renamed copy of a genuine archive did not trigger a loud retention refusal: $(cat "${WORK}/retention_refuse_renamed.log")"
grep -q "$RENAMED" "${WORK}/retention_refuse_renamed.log" \
  || fail "the refusal did not name the renamed copy"

for f in $BEFORE_GENUINE2; do
  [ -e "$f" ] || fail "retention deleted a genuine archive ($f) instead of refusing to prune"
done
pass "a renamed-but-genuinely-signed copy caused a loud refusal; no genuine archive was pruned"

rm -f "${TRITRACK_BACKUP_DIR}/${RENAMED}" "${TRITRACK_BACKUP_DIR}/${RENAMED}.minisig"

step "10d. Retention prunes again once the renamed copy is gone"
sleep 1  # archive names are second-resolution; a collision refuses by design
TRITRACK_BACKUP_KEEP=2 "${COMPOSE[@]}" --profile backup run --rm --no-deps \
  backup tritrack-backup >"${WORK}/retention_resume_renamed.log" 2>&1
if grep -q "RETENTION REFUSED" "${WORK}/retention_resume_renamed.log"; then
  fail "retention kept refusing after the renamed copy was removed"
fi
AFTER_RENAMED_COUNT="$(ls -1 "$TRITRACK_BACKUP_DIR"/tritrack-*.age | wc -l | tr -d ' ')"
[ "$AFTER_RENAMED_COUNT" = "2" ] || fail "TRITRACK_BACKUP_KEEP=2 left ${AFTER_RENAMED_COUNT} archives after resuming"
pass "ordinary retention resumed once nothing was unaccountable"

# --- 11. The freshness check believes a filename only when it is signed -----
step "11. The backup-freshness check must not believe a planted filename (task 11.125)"
# **`_is_genuine` in server/backup/freshness.sh had never executed** — task
# 11.119's survey, item 3. It is the defence that stops a file *named* like
# tomorrow's archive from reporting the deployment as backed up, and until now
# the property was asserted by `backup_schedule_test.dart` reading the script's
# text. No automated path set a verify key when freshness ran, so every run
# took the unverified branch, and a control asserted by reading its own source
# is what the whole survey is about.
#
# Three runs, differing only in what they are told and what is on disk. The
# third is what makes the first two evidence: with the key removed the plant IS
# believed, so the refusal above it is the signature arm doing the work rather
# than something else in the script happening to agree.
freshness() { # <verify-key>  -> output in $WORK/freshness.log, status in $FRESH_STATUS
  set +e
  TRITRACK_BACKUP_VERIFY_KEY="$1" \
    "${COMPOSE[@]}" --profile backup run --rm --no-deps -T \
      --entrypoint tritrack-backup-freshness backup \
      >"${WORK}/freshness.log" 2>&1
  FRESH_STATUS=$?
  set -e
}

GENUINE_NEWEST="$(ls -1 "$TRITRACK_BACKUP_DIR"/tritrack-*.age | sort | tail -1)"
GENUINE_NEWEST="$(basename "$GENUINE_NEWEST")"

freshness "$TRITRACK_BACKUP_VERIFY_KEY"
[ "$FRESH_STATUS" = "0" ] \
  || fail "freshness reported a fault against the archives this drill just wrote (exit $FRESH_STATUS): $(cat "${WORK}/freshness.log")"
grep -q "Provenance:     signature-verified" "${WORK}/freshness.log" \
  || fail "freshness did not take the verified branch even with a key set: $(cat "${WORK}/freshness.log")"
grep -q "Newest archive: ${GENUINE_NEWEST}" "${WORK}/freshness.log" \
  || fail "freshness named something other than the newest genuine archive: $(cat "${WORK}/freshness.log")"
pass "with a verifying key, freshness reports the newest signed archive and says the age is verified"

# The H-7 plant again, aimed at the age report rather than at retention: a
# write-only attacker names a file for the year 2999 and no other change is
# needed to make "backups are being taken" true forever.
FRESH_PLANT="tritrack-29991231T235959Z.age"
printf 'age-encryption.org/v1\nplanted by an entity with write-only access\n' \
  > "${TRITRACK_BACKUP_DIR}/${FRESH_PLANT}"

freshness "$TRITRACK_BACKUP_VERIFY_KEY"
grep -q "Newest archive: ${FRESH_PLANT}" "${WORK}/freshness.log" \
  && fail "a planted future-dated filename was reported as the newest backup: $(cat "${WORK}/freshness.log")"
grep -q "Newest archive: ${GENUINE_NEWEST}" "${WORK}/freshness.log" \
  || fail "with a plant present freshness stopped naming the genuine newest archive: $(cat "${WORK}/freshness.log")"
pass "an unsigned, future-dated plant is ignored: the age still comes from the newest signed archive"

# **The discriminator.** Same directory, same plant, no verifying key: the
# script says plainly that the age is unverified AND believes the plant. If
# this run also refused it, the refusal above would be evidence of nothing.
freshness ""
grep -q "Newest archive: ${FRESH_PLANT}" "${WORK}/freshness.log" \
  || fail "without a verifying key the plant was still not believed — so the run above proves nothing about the signature check: $(cat "${WORK}/freshness.log")"
grep -q "Provenance:     UNVERIFIED" "${WORK}/freshness.log" \
  || fail "with no verifying key freshness did not mark the age unverified: $(cat "${WORK}/freshness.log")"
pass "with no verifying key the same plant IS believed, and is labelled UNVERIFIED — so the refusal above is the signature check"

rm -f "${TRITRACK_BACKUP_DIR}/${FRESH_PLANT}"

step "DRILL PASSED — ${CHECKS} checks"
# Task 11.80's non-negotiable: the drill exercises the off-machine copy, or it
# says it does not. It does not, and saying so here rather than only in a
# document is the point — this is the output somebody reads when they want to
# know whether their backups work, and "a copy nobody has restored from is a
# belief, not a backup" applies to a copy that does not exist even more
# plainly than to one that does.
echo
echo "WHAT THIS DRILL DID NOT TEST: restoring from an off-machine copy."
echo "  Every archive above was written to, and restored from, a folder on this"
echo "  same host. There is no second location, so no restore has ever been"
echo "  performed from one. That is a gap, not a passing check — see task 11.80"
echo "  and server/README.md, 'Where the archive is not'."
echo
echo "Record today's date and this count in server/README.md's restore-drill log."
