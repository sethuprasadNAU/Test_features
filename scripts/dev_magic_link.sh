#!/usr/bin/env bash
# gate-instrument: none - a development convenience that prints a sign-in link; it checks nothing.
# Print the current development sign-in link for one email address.
#
#   scripts/dev_magic_link.sh sam@example.com
#   scripts/dev_magic_link.sh sam@example.com --url-only
#
# **Why this exists (task 11.37, item 5).** The two-device walkthrough used to
# say: run `sudo cat .dev_magic_links/<address>.link`, then "copy the URL (the
# third line)". That is the defect class this task is about — a documented
# command whose output a person reads and retypes, described by *position*.
# Nothing can check prose, and prose goes stale: task 11.37 itself added an
# `Issued:` line to that file, which moved the URL to the fourth line. The
# instruction would have been wrong from the moment it was written, and the
# only symptom would have been a sign-in that did not work.
#
# So the extraction moved into a command. It matches the URL by its `http`
# prefix, the same way `test/e2e/support/magic_link_reader.dart` does, and
# `server/test/auth/email_sender_test.dart` asserts the file keeps that shape.
#
# **What this does NOT do, deliberately: it does not paste the link into the
# app.** The destination is a text field on a phone, and the device that
# completes the exchange is the device that gets signed in — that is the
# design, not a limitation of this script. What it removes is the step of
# picking the right line out of a file, and it tells you how old the link is.
#
# **The file is a live credential.** It is written mode 600 by the container's
# root user, which is why `sudo` appears below. This prints it to your
# terminal, exactly as `cat` did; it does not log it anywhere.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

EMAIL="${1:-}"
URL_ONLY=0
[ "${2:-}" = "--url-only" ] && URL_ONLY=1

if [ -z "$EMAIL" ]; then
  echo "usage: scripts/dev_magic_link.sh <email-address> [--url-only]" >&2
  exit 2
fi

# Must match FileEmailSender's sanitisation exactly, or this simply never finds
# the file. Kept beside the reference to it rather than hidden in a variable.
SAFE_NAME="$(printf '%s' "$EMAIL" | sed 's/[^a-zA-Z0-9._@-]/_/g')"
DIR="${TRITRACK_DEV_MAGIC_LINK_DIR:-.dev_magic_links}"
FILE="$DIR/$SAFE_NAME.link"

READ_CMD=(cat "$FILE")
if [ ! -r "$FILE" ]; then
  # Unreadable is the normal case: mode 600, owned by root. Escalate rather
  # than reporting "no such file", which sends people looking for the wrong
  # problem.
  READ_CMD=(sudo cat "$FILE")
fi

CONTENT="$("${READ_CMD[@]}" 2>/dev/null)"
if [ -z "$CONTENT" ]; then
  cat >&2 <<EOF
No sign-in link found at $FILE

Three things this means, in the order they are worth checking:

  1. **The per-address rate limit refused the request, silently.** Three
     sign-in requests per address per fifteen minutes. When it trips the
     server returns the identical "accepted" response and writes no file —
     that silence is deliberate (README.md §4). Wait, use a different
     address, or restart the server to clear it:
       docker compose -f docker-compose.yml -f docker-compose.dev-lan.yml restart server
  2. **The stack is not running the development mail sender.** It needs
     docker-compose.dev-lan.yml (or docker-compose.e2e.yml) layered on.
  3. **You are not on the machine running the server.** This file is written
     inside the container, onto that host. Reading it from your laptop when
     the server is on a VM will never work.
EOF
  exit 1
fi

# The `-z` below is not a pass — it is the *reported failure* branch: it
# prints the file's contents and exits 1. And the input is a shell variable
# already checked non-empty above, piped into a `grep` with a constant
# pattern, so "the command broke" and "no line matched" are not two outcomes
# here; there is only the second.
# swallow-reviewed: see the five lines above (task 11.49, 2026-08-29).
URL="$(grep -m1 '^http' <<<"$CONTENT" || true)"
if [ -z "$URL" ]; then
  echo "Found $FILE but no http line in it. Contents:" >&2
  printf '%s\n' "$CONTENT" >&2
  exit 1
fi

if [ "$URL_ONLY" = "1" ]; then
  printf '%s\n' "$URL"
  exit 0
fi

ISSUED="$(sed -n 's/^Issued: //p' <<<"$CONTENT" | sed -n 1p)"
EXPIRES="$(sed -n 's/^Expires: //p' <<<"$CONTENT" | sed -n 1p)"

printf '\n\033[1mSign-in link for %s\033[0m\n\n' "$EMAIL"
printf '%s\n\n' "$URL"

# The age of the link is the thing a person cannot work out for themselves, and
# it is what separates "the code is spent" from "my request was refused and I
# am looking at the previous link". Reported in whole minutes because that is
# the resolution the answer is wanted at.
if [ -n "$ISSUED" ]; then
  ISSUED_EPOCH="$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "${ISSUED%%.*}" '+%s' 2>/dev/null \
    || date -u -d "$ISSUED" '+%s' 2>/dev/null || true)"
  if [ -n "$ISSUED_EPOCH" ]; then
    AGE_MIN=$(( ( $(date -u '+%s') - ISSUED_EPOCH ) / 60 ))
    printf 'Issued:  %s  (%s minutes ago)\n' "$ISSUED" "$AGE_MIN"
    if [ "$AGE_MIN" -ge 2 ]; then
      printf '\n\033[33mThis link is %s minutes old.\033[0m If you just asked for one, this\n' "$AGE_MIN"
      printf 'is the PREVIOUS link and your request was refused by the per-address rate\n'
      printf 'limit — three per address per fifteen minutes, answered identically to a\n'
      printf 'success. Redeeming this one will fail as already used. See README.md §4.\n'
    fi
  else
    printf 'Issued:  %s\n' "$ISSUED"
  fi
else
  printf '\033[33mThis file has no "Issued:" line\033[0m — it was written by a server build\n'
  printf 'from before task 11.37, so there is no way to tell whether it is the link you\n'
  printf 'just asked for or an older one. Restart the server to get a current build.\n'
fi
[ -n "$EXPIRES" ] && printf 'Expires: %s\n' "$EXPIRES"
printf '\n'
