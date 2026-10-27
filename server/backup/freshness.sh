#!/bin/sh
# How old is the newest backup? (task 11.78 / Security Model §4.9)
#
# ## Why this exists
#
# Task 11.70 made a backup *work* when it runs. Nothing ran it: `server/README.md`
# said to add a daily cron, which is a documented step a human performs and
# nothing checks — the exact class 11.70's own decision rejected when it put a
# `user:` line in docker-compose.yml instead of a `chown` in the instructions.
# **11.70 turned a backup that fails loudly into a backup that is never taken**,
# and nothing anywhere would have said so.
#
# The floor 11.70 named and 11.78 adopted: **something visible names the age of
# the newest archive.** A person who can read "newest backup: 34 days old"
# cannot hold the false belief that they have backups. That sentence is the
# deliverable; the scheduler beside this file is only how it becomes true.
#
# ## What it measures, and why that and not the schedule
#
# **The archive, never the timer.** A cron entry that stopped firing, a
# scheduler container that wedged, a `.env` that lost its recipients and a
# backup job failing every night — all of those are invisible to "is a
# scheduler running?" and all of them are the same fact to a person: the newest
# archive is old. So this looks at `/backups` and answers one question, and
# `tritrack-backup-schedule` is measured by it like everything else.
#
# ## Three outcomes, and they must stay distinguishable
#
#   fresh    the newest archive is within TRITRACK_BACKUP_MAX_AGE_HOURS
#   stale    an archive exists and it is older than that
#   absent   no archive has ever been written
#
# **Stale and absent are different situations and must never share a sentence.**
# Stale means the schedule broke at a knowable moment and there is still a
# restorable copy of something. Absent means every observation since the server
# was set up exists only on the phones that recorded it. Both exit non-zero —
# Docker's healthcheck has one failing value and the message is what carries
# the difference.
#
# ## Whose archives count (tasks 10.44 / 10.53, findings H-7 / I-2)
#
# The staleness alarm is a thing an attacker would want to silence, and
# `/backups` is a directory §4.9 assumes may be written by others: H-7 was
# exactly a planted filename steering retention. A file named
# `tritrack-29991231T235959Z.age` would otherwise turn this check green forever.
#
# So the age comes from the archive's **filename timestamp**, and a filename is
# only believed when `minisign` verifies the archive against
# TRITRACK_BACKUP_VERIFY_KEY *and* the signed `archive=` field equals that
# filename — retention's predicate, for the same reason and against the same
# attacker. Without the verify key configured no filename can be believed at
# all; the reading is still given, marked plainly as unverified, because an
# unverified age is far better than no age and the operator is told which one
# they have.
#
# The mtime is deliberately not used: whoever can write the directory can
# `touch` a genuine archive, and then an eighteen-month-old backup reads as
# this morning's.
#
# ## Its last line is its finding (CLAUDE.md, established by task 11.69)
#
# Docker keeps only the tail of a healthcheck's output, and continuous
# integration keeps only the last few lines of a check. So the last thing this
# prints is always what it found — an age or an absence — never its own name.
#
# Usage:
#   tritrack-backup-freshness                 human report, exit 0 fresh / 1 not
#   tritrack-backup-freshness --age-seconds   age in seconds on stdout, or
#                                             nothing and exit 1 if absent.
#                                             Used by tritrack-backup-schedule.
set -eu

BACKUP_DIR=/backups
MAX_AGE_HOURS="${TRITRACK_BACKUP_MAX_AGE_HOURS:-48}"

MODE=report
if [ "${1:-}" = "--age-seconds" ]; then
  MODE=age
elif [ $# -gt 0 ]; then
  echo "usage: tritrack-backup-freshness [--age-seconds]" >&2
  exit 64
fi

say() { [ "$MODE" = report ] && echo "$@" || :; }

# --- Turning tritrack-YYYYMMDDTHHMMSSZ.age into an epoch second ------------
#
# Arithmetic rather than `date -d`: this image is busybox and its `date` parses
# a different set of formats from GNU's, so a working expression here would be
# a coincidence of the base image rather than a property of the script. The
# civil-to-days conversion below is the standard one (Howard Hinnant's), exact
# for every date this will ever see and dependent on nothing but shell integer
# maths.
_days_from_civil() {
  _y=$1; _m=$2; _d=$3
  [ "$_m" -le 2 ] && _y=$((_y - 1))
  _era=$((_y / 400))
  _yoe=$((_y - _era * 400))
  if [ "$_m" -gt 2 ]; then _mp=$((_m - 3)); else _mp=$((_m + 9)); fi
  _doy=$(( (153 * _mp + 2) / 5 + _d - 1 ))
  _doe=$(( _yoe * 365 + _yoe / 4 - _yoe / 100 + _doy ))
  echo $(( _era * 146097 + _doe - 719468 ))
}

# Epoch seconds for the timestamp embedded in an archive's basename, or nothing
# if the name is not the shape this project writes.
_stamp_epoch() {
  _name="$1"
  _ts="$(printf '%s' "$_name" | sed -n 's/^tritrack-\([0-9]\{8\}T[0-9]\{6\}Z\)\.age$/\1/p')"
  [ -n "$_ts" ] || return 1
  _yy=$(printf '%s' "$_ts" | cut -c1-4)
  _mm=$(printf '%s' "$_ts" | cut -c5-6)
  _dd=$(printf '%s' "$_ts" | cut -c7-8)
  _hh=$(printf '%s' "$_ts" | cut -c10-11)
  _mi=$(printf '%s' "$_ts" | cut -c12-13)
  _ss=$(printf '%s' "$_ts" | cut -c14-15)
  # 10#-prefixing is a bashism; strip leading zeros instead so `08` is eight
  # and not an invalid octal literal.
  _mm=$(printf '%s' "$_mm" | sed 's/^0//'); _dd=$(printf '%s' "$_dd" | sed 's/^0//')
  _hh=$(printf '%s' "$_hh" | sed 's/^0//'); _mi=$(printf '%s' "$_mi" | sed 's/^0//')
  _ss=$(printf '%s' "$_ss" | sed 's/^0//')
  _days=$(_days_from_civil "$_yy" "${_mm:-0}" "${_dd:-0}")
  echo $(( _days * 86400 + ${_hh:-0} * 3600 + ${_mi:-0} * 60 + ${_ss:-0} ))
}

# Retention's predicate, unchanged in meaning: a signature that verifies AND was
# signed over this exact basename. See backup.sh's retention section for why
# both halves are needed — a renamed copy of a genuine pair still verifies.
VERIFY_KEYS="$(printf '%s' "${TRITRACK_BACKUP_VERIFY_KEY:-}" | tr ',' ' ')"
HAVE_VERIFY_KEY=0
[ -n "$(printf '%s' "$VERIFY_KEYS" | tr -d '[:space:]')" ] && HAVE_VERIFY_KEY=1

_is_genuine() {
  _f="$1"
  [ -f "${_f}.minisig" ] || return 1
  for _k in $VERIFY_KEYS; do
    if _tc="$(minisign -V -Q -P "$_k" -m "$_f" -x "${_f}.minisig" 2>/dev/null)"; then
      _signed="$(printf '%s' "$_tc" | sed -n 's/.*[[:space:]]archive=\([^[:space:]]*\).*/\1/p')"
      [ "$_signed" = "$(basename "$_f")" ] && return 0
    fi
  done
  return 1
}

if [ ! -d "$BACKUP_DIR" ] || [ ! -r "$BACKUP_DIR" ]; then
  # Task 11.70's message, reused rather than reinvented. "I cannot read the
  # directory" and "there are no backups" are different facts and this check
  # exists because naming the wrong one is what cost an operator their
  # backups the first time. On Linux a bind mount passes host ownership
  # through, so a container running as the wrong user lands here.
  if [ "$MODE" = report ]; then
    . /usr/local/lib/tritrack-permissions.sh 2>/dev/null \
      && tritrack_ownership_note "$BACKUP_DIR" 2>/dev/null || :
  fi
  say "BACKUP FRESHNESS UNKNOWN — this container cannot read $BACKUP_DIR, so the age of the newest archive cannot be measured. This is NOT the same as having no backups; nothing here says whether any exist."
  exit 1
fi

NOW="$(date -u +%s)"
NEWEST=""
NEWEST_EPOCH=""
UNVERIFIED_PRESENT=0

for f in "$BACKUP_DIR"/tritrack-*.age; do
  [ -e "$f" ] || continue
  e="$(_stamp_epoch "$(basename "$f")" 2>/dev/null)" || continue
  if [ "$HAVE_VERIFY_KEY" = 1 ] && ! _is_genuine "$f"; then
    UNVERIFIED_PRESENT=1
    continue
  fi
  if [ -z "$NEWEST_EPOCH" ] || [ "$e" -gt "$NEWEST_EPOCH" ]; then
    NEWEST_EPOCH="$e"
    NEWEST="$(basename "$f")"
  fi
done

if [ -z "$NEWEST_EPOCH" ]; then
  if [ "$MODE" = age ]; then exit 1; fi
  if [ "$UNVERIFIED_PRESENT" = 1 ]; then
    echo "  $BACKUP_DIR holds files named like archives, but not one of them"
    echo "  verifies against TRITRACK_BACKUP_VERIFY_KEY under its own name. That"
    echo "  is what a planted filename looks like (§10.5.2, finding H-7);"
    echo "  investigate before deleting anything."
  fi
  if [ -z "$(printf '%s' "${TRITRACK_BACKUP_RECIPIENTS:-}" | tr -d '[:space:],')" ]; then
    echo "  TRITRACK_BACKUP_RECIPIENTS is empty, which is why: the backup job"
    echo "  refuses to run at all without an age recipient to encrypt to, and"
    echo "  there is no unencrypted path (§4.9). Backups are not configured on"
    echo "  this deployment; they are not merely failing."
  else
    echo "  Recipients are configured, so this is a backup that is failing"
    echo "  rather than one that was never set up. The scheduler's own log"
    echo "  ('docker compose logs backup-scheduler') carries the reason."
  fi
  echo "NO BACKUP HAS EVER BEEN TAKEN — there is no archive in $BACKUP_DIR. Every observation on this server exists only here and on the devices that recorded it."
  exit 1
fi

AGE=$((NOW - NEWEST_EPOCH))
[ "$AGE" -lt 0 ] && AGE=0
AGE_HOURS=$((AGE / 3600))
AGE_DAYS=$((AGE / 86400))

if [ "$MODE" = age ]; then
  echo "$AGE"
  exit 0
fi

if [ "$HAVE_VERIFY_KEY" = 1 ]; then
  PROVENANCE="signature-verified"
else
  PROVENANCE="UNVERIFIED (TRITRACK_BACKUP_VERIFY_KEY is not set, so this age is taken from a filename nothing has authenticated)"
fi

echo "Newest archive: $NEWEST"
echo "Provenance:     $PROVENANCE"
echo "Limit:          ${MAX_AGE_HOURS}h (TRITRACK_BACKUP_MAX_AGE_HOURS)"
# Task 11.80. Stated every time, because the thing this check measures is one
# folder on the same disk as the database it protects. It covers a corrupted
# database, a bad migration, a botched restore. It does not cover losing the
# machine — and nothing in this repository carries an archive anywhere else.
# Printed rather than left implied for exactly the reason task 11.78 exists: a
# person who can read the sentence cannot hold the false belief, and "I have
# backups" and "I have backups somewhere else" are the belief and the fact.
#
# It does NOT affect the exit code. The destination is Michael's decision and
# is not made yet; a red healthcheck for an undecided question would train
# somebody to ignore the one signal that says backups have stopped.
echo "Where:          $BACKUP_DIR, on this machine only. NOTHING COPIES AN ARCHIVE OFF THIS HOST, so losing the machine loses every account, session and sync bookmark on it (task 11.80: a destination has not been chosen)."

if [ "$AGE" -gt $((MAX_AGE_HOURS * 3600)) ]; then
  if [ "$AGE_DAYS" -ge 1 ]; then HOW_OLD="${AGE_DAYS} DAYS OLD (${AGE_HOURS}h)"; else HOW_OLD="${AGE_HOURS} HOURS OLD"; fi
  echo "NEWEST BACKUP IS ${HOW_OLD}, past the ${MAX_AGE_HOURS}h limit — backups have stopped being taken. Anything recorded since $NEWEST exists only on the devices that recorded it."
  exit 1
fi

echo "newest backup: ${AGE_HOURS}h old, within the ${MAX_AGE_HOURS}h limit — backups are being taken."
