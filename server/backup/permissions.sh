#!/bin/sh
# Ownership diagnosis shared by backup.sh and restore.sh (task 11.70).
#
# ## Why this file exists
#
# On a Linux server the backup container could not create a file in the
# operator's `backups/` directory, and `backup.sh` reported
# `pg_dump | age pipeline failed; no archive written` — which sent the
# operator to look at their database. The harm was not the failure; it was
# that the failure read like a transient database error, so a person who
# followed `server/README.md` exactly could believe they had encrypted backups
# when no archive had ever been written.
#
# `docker-compose.yml`'s `user:` line on the `backup` and `backup-scheduler`
# services is the fix. This file is what happens when that line has not been applied — a raw
# `docker compose run backup`, or a host where the paths really do belong to
# somebody else. It turns a permission problem into a sentence about
# permissions.
#
# ## The second defect, found on Michael's own server on 2026-08-31 (task 11.80)
#
# This message named the right cause and then prescribed a remedy that does not
# fix the commonest case. His first backup failed with `cannot create a file in
# /backups`; the explanation of the uid/gid mismatch was correct, and the one
# remedy offered was **"use scripts/server_up.sh instead of a raw compose line."
# He had used scripts/server_up.sh.** The directory was owned by root, left that
# way by a bare `docker compose up` taken **before task 11.70 landed** — and
# 11.70's chosen shape fixes new installations while leaving existing ones
# stranded with no instruction at all.
#
# **That is worse than a message naming the wrong cause**, which is what 11.70
# fixed: the reader follows this one exactly, fails again, and now doubts the
# diagnosis as well as the remedy.
#
# So when the path belongs to somebody else, the `chown` goes FIRST and is
# stated as the thing that always fixes it — with the real numbers read out of
# the running container, not a template to fill in. The scripts are named after
# it, for the raw-compose case they do fix. **A remedy that works for the reader
# who already followed the other one must come first**, because the reader who
# needs it is by definition the reader the first remedy failed.
#
# It lives in the image and is sourced by backup.sh, restore.sh and
# freshness.sh rather than being written three times, because all three fail on
# the same fact for the same reason and one of them would drift.

# Echo a multi-line explanation of why $1 is not accessible to this container's
# user. Never fails, and never guesses: every number in it is read from the
# running container.
tritrack_ownership_note() {
  _tt_path="$1"
  _tt_me="$(id -u):$(id -g)"
  # GNU/busybox `stat -c` first, BSD `stat -f` second. The container this runs
  # in is busybox, so the first form is the one that matters in production —
  # the fallback is what lets `backup_ownership_message_test.dart` exercise
  # both branches of this function on a developer's Mac. A reading that is
  # only available on the CI host is a reading nobody checks before pushing.
  _tt_owner="$(stat -c '%u:%g' "$_tt_path" 2>/dev/null \
    || stat -f '%u:%g' "$_tt_path" 2>/dev/null || echo 'unknown')"
  _tt_mode="$(stat -c '%a' "$_tt_path" 2>/dev/null \
    || stat -f '%Lp' "$_tt_path" 2>/dev/null || echo 'unknown')"
  # Two different causes wear the same symptom, and naming the wrong one is
  # the defect this whole file exists to fix. If the path already belongs to
  # this user, ownership is NOT the answer and saying so would send the
  # operator to chown something that is already theirs.
  if [ "$_tt_owner" = "$_tt_me" ]; then
    _tt_cause="  ${_tt_path} is ALREADY owned by this user (${_tt_owner}, mode
  ${_tt_mode}), so ownership is not the problem here. The usual causes are a
  mount declared read-only, a full or read-only filesystem, or a directory
  mode that denies its own owner."
  else
    _tt_cause="  This container is running as uid:gid ${_tt_me}. ${_tt_path} is owned by
  ${_tt_owner}, mode ${_tt_mode}. On Linux a bind mount passes the host's
  ownership straight through, so the user this container runs as has to be the
  user that owns the backup directory and the keys on the host. (On macOS with
  Docker Desktop it does not, which is why this can work on a laptop and fail
  on a server.)"
  fi
  # The remedy branch, and it is deliberately not the same shape as the cause
  # branch above. When the path is already ours the scripts are the whole
  # answer; when it is not, no script can change who owns a directory on the
  # host, and offering one first is what stranded an operator who had already
  # run it.
  if [ "$_tt_owner" = "$_tt_me" ]; then
    _tt_remedy="  The scripts below set the container's user to whoever invokes them, which
  is the arrangement 'server/README.md' describes:

      scripts/server_up.sh              # start the stack (task 11.78 —
                                        # includes the backup scheduler)
      scripts/backup_db.sh              # take a backup now
      scripts/restore_db.sh ...         # restore one
      scripts/backup_status.sh          # how old is the newest archive?"
  else
    _tt_remedy="  FIX IT LIKE THIS, on the host, not in the container. Nothing you can run
  from this repository changes who owns a directory. If you already used
  scripts/server_up.sh or scripts/backup_db.sh and got here anyway,
  THAT IS EXPECTED, and it is not a mistake you made: those scripts set who
  the container runs as, and the problem is who owns the path.

      sudo chown -R ${_tt_me} ${_tt_path}

  The commonest reason a server lands here: the directory was created by a
  bare 'docker compose up' run as root BEFORE task 11.70 added the 'user:'
  line, and it kept root's ownership afterwards. 11.70 fixed new
  installations; this is the one line that fixes an older one. You only ever
  do it once.

  If instead you ran a raw 'docker compose' line by hand just now, use these,
  which set the container's user for you:

      scripts/server_up.sh              # start the stack (task 11.78 —
                                        # includes the backup scheduler)
      scripts/backup_db.sh              # take a backup now
      scripts/restore_db.sh ...         # restore one
      scripts/backup_status.sh          # how old is the newest archive?"
  fi
  cat <<NOTE

  This is NOT a database problem, and nothing has been written.

${_tt_cause}

${_tt_remedy}

  To use the raw compose line anyway, export TRITRACK_BACKUP_UID=\$(id -u) and
  TRITRACK_BACKUP_GID=\$(id -g) first. See server/README.md, "Database backups".
NOTE
  unset _tt_path _tt_me _tt_owner _tt_mode _tt_cause _tt_remedy
}
