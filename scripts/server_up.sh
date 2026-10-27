#!/usr/bin/env bash
# gate-instrument: none - starts a deployment stack; the gate brings up its own, scoped to the tritrack-gate compose project.
# Start the server stack (task 11.78).
#
#   scripts/server_up.sh          # detached, the usual case
#   scripts/server_up.sh --build  # anything after the name goes to compose
#   scripts/server_up.sh -f docker-compose.yml -f docker-compose.dev-lan.yml --build
#                                 # a multi-file stack: -f and -p are hoisted
#                                 # to where compose needs them
#
# ## Why this is not just `docker compose up`
#
# The stack now includes `backup-scheduler`, which writes archives into your
# `backups/` directory and reads your mode-600 signing key. On Linux a bind
# mount passes host ownership straight through, so that container has to run as
# the user who owns those — the same fact task 11.70 established for manual
# backups, now applying to a container nobody invokes by hand.
#
# `scripts/backup_db.sh` and `scripts/restore_db.sh` source
# `scripts/lib/backup_user.sh` for exactly this. Compose has no way to spell
# "the user who typed this", so a raw `docker compose up` gets the image's uid
# 70 and, on a Linux server, a scheduler that fails every cycle.
#
# It fails *visibly* — `backup.sh` names the ownership mismatch before touching
# the database, and the service's healthcheck goes red — so a raw
# `docker compose up` is wrong rather than dangerous. This script is how it is
# right without anybody having to know any of the above.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

. scripts/lib/load_env.sh
# shellcheck disable=SC1091
. scripts/lib/backup_user.sh
# **Found by `test/documentation/dev_stack_host_prerequisites_test.dart`, red
# on `main` since task 11.125, fixed here by task 11.128.** 11.125 taught this
# script to accept `-f` — which is what made it able to bring up
# `docker-compose.dev-lan.yml`, the overlay that turns the file-based
# magic-link sender on. That overlay reads `TRITRACK_DEV_UID`/`GID` and falls
# back to `0:0`, so without this line the development server runs as root on a
# Linux host and every sign-in link it writes is `root:root 0600` — unreadable
# by the person who asked for it, while `/auth/magic-link` still answers `202`
# (§4.5). Same shape as the ownership fault 11.125 was written to stop, one
# directory over.
# shellcheck disable=SC1091
. scripts/lib/host_user.sh

# ## Why it takes `-f` and `-p` rather than only passing everything through
#
# **Task 11.125, and it is task 11.80's class: a remedy that does not fit the
# only deployment there is.** Until 2026-09-02 this ran a bare
# `docker compose up "$@"`, with everything after the script's name appended
# *after* `up` — and `-f` and `-p` are compose's own options, which must come
# *before* it. So the script could not express a multi-file stack at all, and
# the one person running this server starts it with
#
#   docker compose -f docker-compose.yml -f docker-compose.dev-lan.yml up --build -d
#
# — the overlay that turns the file-based magic-link sender on, which is what
# makes the two-device walkthrough possible. Running `server_up.sh` instead
# would have silently dropped it. The header above explains at length why a raw
# `docker compose up` is wrong, and then handed back something he could not
# use, so he used the raw line, and the scheduler ran as uid 70 against a
# `backups/` directory owned by somebody else. **That is not hypothetical: it
# is what happened on the beta host, where every backup cycle failed from
# 2026-08-31 until 2026-09-02.**
#
# So `-f`/`--file` and `-p`/`--project-name` are recognised anywhere on the
# command line and hoisted in front of `up`; everything else still goes after
# it, unchanged.
PRE=()
POST=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -f|--file|-p|--project-name)
      [ "$#" -ge 2 ] || { echo "$1 needs a value" >&2; exit 64; }
      PRE+=("$1" "$2"); shift 2 ;;
    -f=*|--file=*|-p=*|--project-name=*)
      PRE+=("$1"); shift ;;
    *)
      POST+=("$1"); shift ;;
  esac
done

if [ "${#POST[@]}" -eq 0 ]; then
  POST=(-d)
fi

# Task 11.308. What commit `up --build` is about to build, computed here
# rather than left to Docker: a build context has no notion of "the working
# tree", only the files COPY'd into it, so the image itself cannot know which
# commit it came from unless something outside the build tells it. `-dirty`
# names the case this script cannot otherwise report honestly — a build from
# uncommitted changes has no commit that describes what actually got built.
GIT_COMMIT="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
if [ "$GIT_COMMIT" != unknown ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  GIT_COMMIT="${GIT_COMMIT}-dirty"
fi
export GIT_COMMIT

commit_serving() {
  # Asks the running container what it was built from — never the working
  # tree — so this is still correct after a failed rebuild, when the working
  # tree has moved on but the container has not.
  local cid
  cid="$(docker compose ${PRE[@]+"${PRE[@]}"} ps -q server 2>/dev/null)" || return 1
  [ -n "$cid" ] || return 1
  docker inspect \
    --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' \
    "$cid" 2>/dev/null
}

PREV_COMMIT="$(commit_serving || echo '(no server container was running)')"

# Task 11.308. This is the noise a healthy start produces, not a broken one —
# named here, immediately before the lines that print it, because the two
# ERRORs below are Postgres's own server-side log output and this script
# cannot silence them without also silencing a genuine one at the same
# severity (that would be quieting a real error to remove noise, which is the
# worse defect). Read past them:
#   - 'role "tritrack_app" already exists' — postgres_database.dart's
#     ensureServerAppRole() creates this role unconditionally on every start
#     and only catches the "someone already made it" error (task 10.69); the
#     CREATE ROLE still reaches Postgres and Postgres still logs its own
#     ERROR before the client's catch ever runs.
#   - 'tuple concurrently updated' — the same function's catalog GRANTs racing
#     another connection doing the same thing (task 10.89); caught and
#     retried by _retryOnConcurrentCatalogUpdate, logged by Postgres before
#     the retry does.
# Both are swallowed in application code and are not evidence of a broken
# start on their own. A start that is actually broken says so below, in the
# lines this script prints after the build.
echo "Bringing up the stack. If 'role \"tritrack_app\" already exists' or"
echo "'tuple concurrently updated' appear below from postgres, both are"
echo "expected on every start (see this script's comment) — not a sign this"
echo "start failed. The commit report after this command is the thing to read"
echo "for that."
echo

if docker compose ${PRE[@]+"${PRE[@]}"} up "${POST[@]}"; then
  STATUS=0
else
  STATUS=$?
fi

if [ "$STATUS" -ne 0 ]; then
  echo >&2
  echo "server_up.sh: 'docker compose up' exited $STATUS — the build or start" >&2
  echo "did NOT succeed. Scroll up, past the 'Building' spinner if there was" >&2
  echo "one, for docker compose's own error; it is above this message, not" >&2
  echo "below it." >&2
  echo "Still serving: $PREV_COMMIT" >&2
  echo "(unchanged — a failed build leaves whatever was running before it" >&2
  echo "untouched. It does not stop, and the state after this failure is not" >&2
  echo "'nothing is running' — it is 'the previous version is still" >&2
  echo "answering', which is the fact that misled everybody the first time.)" >&2
  exit "$STATUS"
fi

NEW_COMMIT="$(commit_serving || echo unknown)"
echo
echo "Now serving commit: $NEW_COMMIT"
if [ "$PREV_COMMIT" = "(no server container was running)" ]; then
  echo "(no server container was running before this start)"
elif [ "$NEW_COMMIT" = "$PREV_COMMIT" ]; then
  # Task 11.308's second derived question. A successful --build that changes
  # nothing looks identical here to one that reused every cached layer and one
  # that recompiled everything and produced a byte-identical label — Docker
  # gives this script an exit code and an image, not a "did I actually
  # recompile" flag, and parsing --build's own progress output for "CACHED"
  # would be coupled to output Docker does not promise to keep stable. So:
  # this script CAN tell you the commit did not change (the fact that
  # matters), and cannot tell you whether that is because nothing needed
  # rebuilding or because the rebuild reproduced what was already there.
  echo "(unchanged from before this command — same commit was already serving;"
  echo "this script cannot tell whether --build found nothing to rebuild or"
  echo "rebuilt and reproduced the same result)"
else
  echo "(previously serving: $PREV_COMMIT)"
fi

echo
echo "Backup freshness (the newest archive's age — the thing that tells you"
echo "backups are actually happening). Compare it with the backup-scheduler"
echo "service's health in 'docker compose ps': the two read the same"
echo "directory but not from the same side of the bind mount, and on"
echo "2026-09-02 they disagreed — see scripts/backup_status.sh."
scripts/backup_status.sh || true

# The uid the scheduler actually came up as, printed rather than assumed. It is
# the property this whole script exists for, and the flags above are only how
# it is reached — so this asks the container instead of trusting that the
# environment reached it.
echo
if scheduler="$(docker compose ${PRE[@]+"${PRE[@]}"} ps -q backup-scheduler 2>/dev/null)" \
   && [ -n "$scheduler" ]; then
  echo "backup-scheduler is running as uid:gid $(docker inspect --format '{{.Config.User}}' "$scheduler" || echo unknown), and your backups/ directory is owned by $(ls -ldn backups 2>/dev/null | awk '{print $3":"$4}' || echo unknown). These two must match on Linux, or every cycle fails the way the beta host's did between 2026-08-31 and 2026-09-02."
else
  echo "backup-scheduler is not running in this stack — nothing is taking backups."
fi
